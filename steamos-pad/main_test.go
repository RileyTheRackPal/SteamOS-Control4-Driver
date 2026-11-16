//go:build linux

package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ThomasT75/uinput"
)

// ---------------------------------------------------------------------------
// fake gamepad: uinput.Gamepad is already an interface, so embedding it (nil)
// and overriding only the methods the daemon uses needs no production change.
// ---------------------------------------------------------------------------

type fakePad struct {
	uinput.Gamepad
	mu     sync.Mutex
	events []string
	failOn string // event string that should return an error (not recorded)
}

var errFake = errors.New("fake pad failure")

func (f *fakePad) rec(ev string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if ev == f.failOn {
		return errFake
	}
	f.events = append(f.events, ev)
	return nil
}

func (f *fakePad) ButtonDown(c int) error { return f.rec(fmt.Sprintf("down:%d", c)) }
func (f *fakePad) ButtonUp(c int) error   { return f.rec(fmt.Sprintf("up:%d", c)) }
func (f *fakePad) HatPress(d uinput.HatDirection) error {
	return f.rec(fmt.Sprintf("hatpress:%v", d))
}
func (f *fakePad) HatRelease(d uinput.HatDirection) error {
	return f.rec(fmt.Sprintf("hatrelease:%v", d))
}
func (f *fakePad) Close() error { return nil }

func (f *fakePad) log() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.events...)
}

func (f *fakePad) reset() {
	f.mu.Lock()
	f.events = nil
	f.mu.Unlock()
}

func down(btn string) string { return fmt.Sprintf("down:%d", buttonCodes[btn]) }
func up(btn string) string   { return fmt.Sprintf("up:%d", buttonCodes[btn]) }
func hatP(h string) string   { return fmt.Sprintf("hatpress:%v", hatDirections[h]) }
func hatR(h string) string   { return fmt.Sprintf("hatrelease:%v", hatDirections[h]) }

func newDaemon() (*daemon, *fakePad) {
	p := &fakePad{}
	return &daemon{
		pad:         p,
		held:        map[string]time.Time{},
		tapDelay:    0,
		holdTimeout: 5 * time.Second,
		sem:         make(chan struct{}, maxConcurrentConns),
	}, p
}

func expectLog(t *testing.T, p *fakePad, want ...string) {
	t.Helper()
	got := p.log()
	if len(got) == 0 && len(want) == 0 {
		return
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("pad events:\n got  %v\n want %v", got, want)
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// roundTrip sends raw bytes through handle() over a net.Pipe and returns the reply.
func roundTrip(t *testing.T, d *daemon, send string) string {
	t.Helper()
	srv, cli := net.Pipe()
	done := make(chan struct{})
	go func() { d.handle(srv); close(done) }()
	defer cli.Close()
	_ = cli.SetDeadline(time.Now().Add(10 * time.Second))
	go func() { _, _ = cli.Write([]byte(send)) }()
	reply, _ := bufio.NewReader(cli).ReadString('\n')
	cli.Close()
	<-done
	return strings.TrimRight(reply, "\n")
}

// ---------------------------------------------------------------------------
// button / hat tables
// ---------------------------------------------------------------------------

func TestButtonCodes(t *testing.T) {
	want := map[string]int{
		"a": 0x130, "b": 0x131, "x": 0x133, "y": 0x134,
		"lb": 0x136, "rb": 0x137, "select": 0x13a, "start": 0x13b,
		"guide": 0x13c, "l3": 0x13d, "r3": 0x13e,
	}
	if len(buttonCodes) != len(want) {
		t.Fatalf("buttonCodes has %d entries, want %d", len(buttonCodes), len(want))
	}
	for name, code := range want {
		if got, ok := buttonCodes[name]; !ok || got != code {
			t.Errorf("buttonCodes[%q] = %#x (present=%v), want %#x", name, got, ok, code)
		}
	}
}

func TestHatTables(t *testing.T) {
	for _, name := range []string{"up", "down", "left", "right"} {
		if _, ok := hatDirections[name]; !ok {
			t.Errorf("hatDirections missing %q", name)
		}
		opp := hatOpposite[name]
		if hatOpposite[opp] != name {
			t.Errorf("hatOpposite not symmetric for %q -> %q", name, opp)
		}
		if _, clash := buttonCodes[name]; clash {
			t.Errorf("%q is both a hat and a button", name)
		}
	}
	seen := map[uinput.HatDirection]string{}
	for n, h := range hatDirections {
		if prev, dup := seen[h]; dup {
			t.Errorf("hat %q and %q share a direction value", n, prev)
		}
		seen[h] = n
	}
}

// ---------------------------------------------------------------------------
// handle(): protocol parsing and dispatch
// ---------------------------------------------------------------------------

func TestHandleProtocol(t *testing.T) {
	cases := []struct {
		name  string
		send  string
		reply string
		want  []string
	}{
		{"ping", "ping\n", "ok pong", nil},
		{"ping uppercase", "PING\n", "ok pong", nil},
		{"ping crlf", "ping\r\n", "ok pong", nil},
		{"ping extra arg is action+button", "ping now\n", `err unknown button "now"`, nil},
		{"empty line", "\n", "err bad command", nil},
		{"unknown verb", "frobnicate\n", "err bad command", nil},
		{"verb only press", "press\n", "err bad command", nil},
		{"three fields", "press a b\n", "err bad command", nil},
		{"press a", "press a\n", "ok", []string{down("a"), up("a")}},
		{"press mixed case", "PrEsS Guide\n", "ok", []string{down("guide"), up("guide")}},
		{"press hat", "press up\n", "ok", []string{hatP("up"), hatR("up")}},
		{"press unknown button", "press z\n", `err unknown button "z"`, nil},
		{"unknown action", "tap a\n", `err unknown action "tap"`, nil},
		{"unknown action unknown button", "tap zz\n", `err unknown button "zz"`, nil},
		{"hold a", "hold a\n", "ok", []string{down("a")}},
		{"release a", "release a\n", "ok", []string{up("a")}},
		{"release hat", "release left\n", "ok", []string{hatR("left")}},
		{"releaseall idle", "releaseall\n", "ok", nil},
		{"releaseall with arg", "releaseall x\n", `err unknown action "releaseall"`, nil},
		{"chord default", "chord guide x\n", "ok", []string{down("guide"), down("x"), up("x"), up("guide")}},
		{"chord explicit hold", "chord 0 a b\n", "ok", []string{down("a"), down("b"), up("b"), up("a")}},
		{"chord no buttons", "chord 10\n", "err no buttons", nil},
		{"chord unknown", "chord a nope\n", `err unknown button "nope"`, nil},
		{"chord alone", "chord\n", "err bad command", nil},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			if strings.HasPrefix(c.send, "chord guide") {
				t.Parallel() // default chord holds 130ms
			}
			d, p := newDaemon()
			if got := roundTrip(t, d, c.send); got != c.reply {
				t.Fatalf("reply = %q, want %q", got, c.reply)
			}
			expectLog(t, p, c.want...)
		})
	}
}

func TestHandleEmptyConnectionNoReply(t *testing.T) {
	d, p := newDaemon()
	srv, cli := net.Pipe()
	done := make(chan struct{})
	go func() { d.handle(srv); close(done) }()
	cli.Close() // EOF with no data
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("handle did not return on empty connection")
	}
	expectLog(t, p)
}

func TestHandleBoundedRead(t *testing.T) {
	// A client that never sends a newline must not make handle() buffer
	// unboundedly: it reads at most maxCmdBytes, then answers.
	d, p := newDaemon()
	junk := strings.Repeat("a", maxCmdBytes*4)
	reply := roundTrip(t, d, junk)
	if !strings.HasPrefix(reply, "err ") {
		t.Fatalf("reply = %q, want an err", reply)
	}
	expectLog(t, p)
}

func TestHandleOnlyFirstLine(t *testing.T) {
	d, p := newDaemon()
	if got := roundTrip(t, d, "release a\npress b\n"); got != "ok" {
		t.Fatalf("reply = %q", got)
	}
	expectLog(t, p, up("a"))
}

func TestHandlePadErrorReported(t *testing.T) {
	d, p := newDaemon()
	p.failOn = down("a")
	if got := roundTrip(t, d, "press a\n"); got != "err "+errFake.Error() {
		t.Fatalf("reply = %q", got)
	}
}

func TestHandleRecoversFromPanic(t *testing.T) {
	d, _ := newDaemon()
	d.pad = nil // any pad call now nil-pointer panics inside handle()
	srv, cli := net.Pipe()
	done := make(chan struct{})
	go func() { d.handle(srv); close(done) }()
	go func() { _, _ = cli.Write([]byte("hold a\n")) }()
	select {
	case <-done: // recovered, did not crash the test binary
	case <-time.After(5 * time.Second):
		t.Fatal("handle hung after panic")
	}
	cli.Close()
}

func TestHandleOverUnixSocket(t *testing.T) {
	d, p := newDaemon()
	dir, err := os.MkdirTemp("", "c4p")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	ln, err := net.Listen("unix", filepath.Join(dir, "c4pad.sock"))
	if err != nil {
		t.Skip("cannot listen on unix socket: ", err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go d.handle(c)
		}
	}()
	c, err := net.Dial("unix", filepath.Join(dir, "c4pad.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	fmt.Fprint(c, "hold b\n")
	reply, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || reply != "ok\n" {
		t.Fatalf("reply = %q err=%v", reply, err)
	}
	expectLog(t, p, down("b"))
}

// ---------------------------------------------------------------------------
// execute()
// ---------------------------------------------------------------------------

func TestExecutePressButtonTiming(t *testing.T) {
	d, p := newDaemon()
	d.tapDelay = 40 * time.Millisecond
	start := time.Now()
	if err := d.execute("press", "a"); err != nil {
		t.Fatal(err)
	}
	if el := time.Since(start); el < 40*time.Millisecond {
		t.Errorf("press returned after %v, want >= tap delay", el)
	}
	expectLog(t, p, down("a"), up("a"))
}

func TestExecutePressClearsHold(t *testing.T) {
	d, _ := newDaemon()
	d.held["a"] = time.Now()
	if err := d.execute("press", "a"); err != nil {
		t.Fatal(err)
	}
	if _, ok := d.held["a"]; ok {
		t.Error("press must end an active hold of the same token")
	}
}

func TestExecutePressHatClearsOppositeHold(t *testing.T) {
	d, p := newDaemon()
	d.held["left"] = time.Now()
	d.held["up"] = time.Now()
	if err := d.execute("press", "right"); err != nil {
		t.Fatal(err)
	}
	if _, ok := d.held["left"]; ok {
		t.Error("tapping right must drop the hold on left (shared axis)")
	}
	if _, ok := d.held["up"]; !ok {
		t.Error("tapping right must not touch holds on the other axis")
	}
	expectLog(t, p, hatP("right"), hatR("right"))
}

func TestExecuteHoldRecordsAndRefreshes(t *testing.T) {
	d, p := newDaemon()
	if err := d.execute("hold", "x"); err != nil {
		t.Fatal(err)
	}
	first, ok := d.held["x"]
	if !ok {
		t.Fatal("hold did not record token")
	}
	time.Sleep(10 * time.Millisecond)
	if err := d.execute("hold", "x"); err != nil {
		t.Fatal(err)
	}
	if !d.held["x"].After(first) {
		t.Error("repeated hold must refresh the timestamp")
	}
	if len(d.held) != 1 {
		t.Errorf("held has %d entries, want 1", len(d.held))
	}
	expectLog(t, p, down("x"), down("x"))
}

func TestExecuteHoldHat(t *testing.T) {
	d, p := newDaemon()
	if err := d.execute("hold", "down"); err != nil {
		t.Fatal(err)
	}
	if _, ok := d.held["down"]; !ok {
		t.Error("hat hold not recorded")
	}
	expectLog(t, p, hatP("down"))
}

func TestExecuteHoldErrorNotRecorded(t *testing.T) {
	d, p := newDaemon()
	p.failOn = down("y")
	if err := d.execute("hold", "y"); !errors.Is(err, errFake) {
		t.Fatalf("err = %v", err)
	}
	if len(d.held) != 0 {
		t.Error("failed hold must not be tracked")
	}
}

func TestExecuteReleaseClearsHold(t *testing.T) {
	d, p := newDaemon()
	d.held["b"] = time.Now()
	d.held["up"] = time.Now()
	if err := d.execute("release", "b"); err != nil {
		t.Fatal(err)
	}
	if err := d.execute("release", "up"); err != nil {
		t.Fatal(err)
	}
	if len(d.held) != 0 {
		t.Errorf("held not cleared: %v", d.held)
	}
	expectLog(t, p, up("b"), hatR("up"))
}

func TestExecuteErrors(t *testing.T) {
	d, p := newDaemon()
	if err := d.execute("press", "nope"); err == nil || !strings.Contains(err.Error(), "unknown button") {
		t.Errorf("err = %v", err)
	}
	if err := d.execute("smash", "a"); err == nil || !strings.Contains(err.Error(), "unknown action") {
		t.Errorf("err = %v", err)
	}
	expectLog(t, p)
}

func TestExecutePressPropagatesErrors(t *testing.T) {
	for _, fail := range []string{down("a"), up("a")} {
		d, p := newDaemon()
		p.failOn = fail
		if err := d.execute("press", "a"); !errors.Is(err, errFake) {
			t.Errorf("failOn %s: err = %v", fail, err)
		}
	}
	for _, fail := range []string{hatP("up"), hatR("up")} {
		d, p := newDaemon()
		p.failOn = fail
		if err := d.execute("press", "up"); !errors.Is(err, errFake) {
			t.Errorf("failOn %s: err = %v", fail, err)
		}
	}
}

// ---------------------------------------------------------------------------
// chord()
// ---------------------------------------------------------------------------

func TestChordOrderAndExplicitHold(t *testing.T) {
	d, p := newDaemon()
	start := time.Now()
	if err := d.chord([]string{"60", "guide", "x", "up"}); err != nil {
		t.Fatal(err)
	}
	if el := time.Since(start); el < 60*time.Millisecond {
		t.Errorf("chord returned after %v, want >= 60ms", el)
	}
	// pressed in order, released in reverse (guide last)
	expectLog(t, p, down("guide"), down("x"), hatP("up"), hatR("up"), up("x"), up("guide"))
}

func TestChordDefaultHold(t *testing.T) {
	d, p := newDaemon()
	start := time.Now()
	if err := d.chord([]string{"guide", "x"}); err != nil {
		t.Fatal(err)
	}
	if el := time.Since(start); el < time.Duration(defaultChordHoldMs)*time.Millisecond {
		t.Errorf("default chord hold = %v, want >= %dms", el, defaultChordHoldMs)
	}
	expectLog(t, p, down("guide"), down("x"), up("x"), up("guide"))
}

func TestChordZeroHoldIsExplicit(t *testing.T) {
	d, _ := newDaemon()
	start := time.Now()
	if err := d.chord([]string{"0", "a"}); err != nil {
		t.Fatal(err)
	}
	if el := time.Since(start); el >= time.Duration(defaultChordHoldMs)*time.Millisecond {
		t.Errorf("explicit 0ms hold took %v (default applied?)", el)
	}
}

func TestChordHoldRange(t *testing.T) {
	for _, arg := range []string{"-1", fmt.Sprint(maxChordHoldMs + 1), "99999999"} {
		d, p := newDaemon()
		err := d.chord([]string{arg, "a"})
		if err == nil || !strings.Contains(err.Error(), "out of range") {
			t.Errorf("hold %s: err = %v", arg, err)
		}
		expectLog(t, p)
	}
}

func TestChordNoButtons(t *testing.T) {
	d, p := newDaemon()
	for _, args := range [][]string{{"100"}, {"0"}} {
		if err := d.chord(args); err == nil || err.Error() != "no buttons" {
			t.Errorf("args %v: err = %v", args, err)
		}
	}
	expectLog(t, p)
}

func TestChordValidatesBeforeTouchingPad(t *testing.T) {
	d, p := newDaemon()
	err := d.chord([]string{"0", "a", "b", "bogus"})
	if err == nil || !strings.Contains(err.Error(), `unknown button "bogus"`) {
		t.Fatalf("err = %v", err)
	}
	expectLog(t, p) // nothing pressed
}

func TestChordUnwindsOnPressFailure(t *testing.T) {
	d, p := newDaemon()
	p.failOn = down("x")
	err := d.chord([]string{"0", "a", "x", "b"})
	if !errors.Is(err, errFake) {
		t.Fatalf("err = %v", err)
	}
	// a was pressed, x failed -> every key released best-effort, b never pressed
	expectLog(t, p, down("a"), up("a"), up("x"), up("b"))
}

// ---------------------------------------------------------------------------
// releaseStale / releaseAll / releaseToken
// ---------------------------------------------------------------------------

func TestReleaseStale(t *testing.T) {
	d, p := newDaemon()
	d.holdTimeout = 5 * time.Second
	d.held["a"] = time.Now().Add(-10 * time.Second) // stale button
	d.held["up"] = time.Now().Add(-6 * time.Second) // stale hat
	d.held["b"] = time.Now().Add(-1 * time.Second)  // fresh
	d.releaseStale()
	if _, ok := d.held["a"]; ok {
		t.Error("stale a not removed")
	}
	if _, ok := d.held["up"]; ok {
		t.Error("stale up not removed")
	}
	if _, ok := d.held["b"]; !ok {
		t.Error("fresh b wrongly removed")
	}
	got := p.log()
	if len(got) != 2 || !contains(got, up("a")) || !contains(got, hatR("up")) {
		t.Errorf("events = %v", got)
	}
}

func TestReleaseStaleRefreshKeepsHeld(t *testing.T) {
	d, p := newDaemon()
	d.holdTimeout = 50 * time.Millisecond
	d.held["a"] = time.Now().Add(-time.Hour)
	// a refresh (repeat hold) just before the janitor runs saves the button
	if err := d.execute("hold", "a"); err != nil {
		t.Fatal(err)
	}
	d.releaseStale()
	if _, ok := d.held["a"]; !ok {
		t.Fatal("refreshed hold was released")
	}
	expectLog(t, p, down("a"))
	// and once it ages past the timeout it is released
	time.Sleep(80 * time.Millisecond)
	d.releaseStale()
	if len(d.held) != 0 {
		t.Fatal("expired hold not released")
	}
	expectLog(t, p, down("a"), up("a"))
}

func TestReleaseStaleEmptyNoop(t *testing.T) {
	d, p := newDaemon()
	d.releaseStale()
	expectLog(t, p)
}

func TestReleaseAll(t *testing.T) {
	d, p := newDaemon()
	d.held["a"] = time.Now()
	d.held["left"] = time.Now()
	d.releaseAll()
	if len(d.held) != 0 {
		t.Errorf("held = %v", d.held)
	}
	got := p.log()
	if len(got) != 2 || !contains(got, up("a")) || !contains(got, hatR("left")) {
		t.Errorf("events = %v", got)
	}
	// via protocol
	d.held["b"] = time.Now()
	p.reset()
	if got := roundTrip(t, d, "releaseall\n"); got != "ok" {
		t.Fatalf("reply = %q", got)
	}
	expectLog(t, p, up("b"))
}

func TestReleaseTokenUnknownIsNoop(t *testing.T) {
	d, p := newDaemon()
	d.releaseToken("bogus")
	expectLog(t, p)
}

func TestLimitsSane(t *testing.T) {
	if maxConcurrentConns < 1 || maxCmdBytes < len("chord 6000 guide x up down\n") {
		t.Fatalf("unreasonable limits: conns=%d cmdBytes=%d", maxConcurrentConns, maxCmdBytes)
	}
}

// ---------------------------------------------------------------------------
// socket path / runtime dir
// ---------------------------------------------------------------------------

func TestSocketPath(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	if got := runtimeDir(); got != dir {
		t.Errorf("runtimeDir = %q", got)
	}
	if got, want := socketPath(), filepath.Join(dir, "c4pad.sock"); got != want {
		t.Errorf("socketPath = %q, want %q", got, want)
	}
}

// ---------------------------------------------------------------------------
// subprocess helpers: functions that call os.Exit / read os.Args
// ---------------------------------------------------------------------------

// TestHelperProcess is not a real test: it is the entry point re-executed by
// runHelper to exercise code paths that call os.Exit.
func TestHelperProcess(t *testing.T) {
	mode := os.Getenv("C4PAD_HELPER")
	if mode == "" {
		t.Skip("helper process only")
	}
	args := strings.Split(os.Getenv("C4PAD_HELPER_ARGS"), "|")
	switch mode {
	case "runtimeDir":
		fmt.Println(runtimeDir())
	case "assert":
		assertOwnerPrivateDir(args[0])
		fmt.Println("passed")
	case "main":
		if args[0] == "" {
			args = nil
		}
		os.Args = append([]string{"c4pad"}, args...)
		main()
	}
	os.Exit(0)
}

type helperResult struct {
	stdout, stderr string
	code           int
}

func runHelper(t *testing.T, mode string, args []string, env ...string) helperResult {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestHelperProcess$")
	cmd.Env = append(os.Environ(), "C4PAD_HELPER="+mode, "C4PAD_HELPER_ARGS="+strings.Join(args, "|"))
	cmd.Env = append(cmd.Env, env...)
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	err := cmd.Run()
	res := helperResult{stdout: so.String(), stderr: se.String()}
	if ee, ok := err.(*exec.ExitError); ok {
		res.code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("helper run: %v", err)
	}
	return res
}

func TestRuntimeDirUnsetExits(t *testing.T) {
	r := runHelper(t, "runtimeDir", nil, "XDG_RUNTIME_DIR=")
	if r.code != 1 || !strings.Contains(r.stderr, "XDG_RUNTIME_DIR is not set") {
		t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
	}
}

func TestRuntimeDirSetSubprocess(t *testing.T) {
	dir := t.TempDir()
	r := runHelper(t, "runtimeDir", nil, "XDG_RUNTIME_DIR="+dir)
	if r.code != 0 || !strings.HasPrefix(r.stdout, dir+"\n") {
		t.Fatalf("code=%d stdout=%q", r.code, r.stdout)
	}
}

func TestAssertOwnerPrivateDir(t *testing.T) {
	base := t.TempDir()
	mk := func(name string, mode os.FileMode) string {
		p := filepath.Join(base, name)
		if err := os.Mkdir(p, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(p, mode); err != nil { // bypass umask
			t.Fatal(err)
		}
		return p
	}

	t.Run("0700 passes", func(t *testing.T) {
		r := runHelper(t, "assert", []string{mk("ok700", 0o700)})
		if r.code != 0 || !strings.Contains(r.stdout, "passed") {
			t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
		}
	})
	t.Run("0500 passes", func(t *testing.T) {
		r := runHelper(t, "assert", []string{mk("ok500", 0o500)})
		if r.code != 0 {
			t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
		}
	})
	for _, m := range []os.FileMode{0o750, 0o705, 0o755, 0o770, 0o777, 0o710} {
		m := m
		t.Run(fmt.Sprintf("%04o refused", m), func(t *testing.T) {
			r := runHelper(t, "assert", []string{mk(fmt.Sprintf("bad%04o", m), m)})
			if r.code != 1 || !strings.Contains(r.stderr, "group/other-accessible") {
				t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
			}
		})
	}
	t.Run("missing", func(t *testing.T) {
		r := runHelper(t, "assert", []string{filepath.Join(base, "nope")})
		if r.code != 1 || !strings.Contains(r.stderr, "cannot stat") {
			t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
		}
	})
	t.Run("regular file", func(t *testing.T) {
		f := filepath.Join(base, "file")
		if err := os.WriteFile(f, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		r := runHelper(t, "assert", []string{f})
		if r.code != 1 || !strings.Contains(r.stderr, "not a real directory") {
			t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
		}
	})
	t.Run("symlink to private dir refused", func(t *testing.T) {
		link := filepath.Join(base, "link")
		if err := os.Symlink(mk("target", 0o700), link); err != nil {
			t.Skip("symlink unsupported: ", err)
		}
		r := runHelper(t, "assert", []string{link})
		if r.code != 1 || !strings.Contains(r.stderr, "not a real directory") {
			t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
		}
	})
	t.Run("foreign owner refused", func(t *testing.T) {
		if os.Getuid() != 0 {
			t.Skip("needs root to chown to another user")
		}
		p := mk("foreign", 0o700)
		if err := os.Chown(p, 12345, 12345); err != nil {
			t.Skip("chown unsupported: ", err)
		}
		r := runHelper(t, "assert", []string{p})
		if r.code != 1 || !strings.Contains(r.stderr, "not owned by the current user") {
			t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
		}
	})
}

// ---------------------------------------------------------------------------
// main() dispatch and client mode (subprocess, real unix socket)
// ---------------------------------------------------------------------------

func TestMainVersion(t *testing.T) {
	r := runHelper(t, "main", []string{"version"})
	if r.code != 0 || strings.TrimSpace(r.stdout) != "c4pad "+version {
		t.Fatalf("code=%d stdout=%q", r.code, r.stdout)
	}
}

func TestMainUsageErrors(t *testing.T) {
	for _, args := range [][]string{
		nil,
		{"bogus"},
		{"press"},
		{"press", "a", "b"},
		{"hold"},
		{"release", "a", "b"},
		{"chord"},
	} {
		r := runHelper(t, "main", args, "XDG_RUNTIME_DIR="+t.TempDir())
		if r.code != 2 || !strings.Contains(r.stderr, "usage:") {
			t.Errorf("args %v: code=%d stderr=%q", args, r.code, r.stderr)
		}
	}
}

// fakeServer accepts connections on dir/c4pad.sock, records the first line,
// and answers with reply (after delay).
type fakeServer struct {
	lines chan string
}

func startFakeServer(t *testing.T, reply string, delay time.Duration) (string, *fakeServer) {
	t.Helper()
	dir, err := os.MkdirTemp("", "c4p")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	ln, err := net.Listen("unix", filepath.Join(dir, "c4pad.sock"))
	if err != nil {
		t.Skip("cannot listen on unix socket: ", err)
	}
	t.Cleanup(func() { ln.Close() })
	fs := &fakeServer{lines: make(chan string, 4)}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				line, _ := bufio.NewReader(c).ReadString('\n')
				fs.lines <- line
				time.Sleep(delay)
				_, _ = c.Write([]byte(reply))
			}()
		}
	}()
	return dir, fs
}

func TestClientSendWireFormat(t *testing.T) {
	cases := []struct {
		args []string
		line string
	}{
		{[]string{"press", "A"}, "press a\n"},
		{[]string{"hold", "Guide"}, "hold guide\n"},
		{[]string{"release", "UP"}, "release up\n"},
		{[]string{"chord", "guide", "X"}, "chord guide x\n"},
		{[]string{"chord", "3000", "GUIDE", "b"}, "chord 3000 guide b\n"},
		{[]string{"releaseall"}, "releaseall\n"},
		{[]string{"ping"}, "ping\n"},
	}
	for _, c := range cases {
		dir, fs := startFakeServer(t, "ok\n", 0)
		r := runHelper(t, "main", c.args, "XDG_RUNTIME_DIR="+dir)
		if r.code != 0 || strings.TrimSpace(r.stdout) != "ok" {
			t.Errorf("%v: code=%d stdout=%q stderr=%q", c.args, r.code, r.stdout, r.stderr)
		}
		select {
		case got := <-fs.lines:
			if got != c.line {
				t.Errorf("%v: server saw %q, want %q", c.args, got, c.line)
			}
		case <-time.After(time.Second):
			t.Errorf("%v: server saw nothing", c.args)
		}
	}
}

func TestClientSendErrReplyExitsNonZero(t *testing.T) {
	dir, _ := startFakeServer(t, "err unknown button \"z\"\n", 0)
	r := runHelper(t, "main", []string{"press", "z"}, "XDG_RUNTIME_DIR="+dir)
	if r.code != 1 || !strings.Contains(r.stdout, "err unknown button") {
		t.Fatalf("code=%d stdout=%q", r.code, r.stdout)
	}
}

func TestClientSendNoDaemon(t *testing.T) {
	dir, err := os.MkdirTemp("", "c4p")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	r := runHelper(t, "main", []string{"ping"}, "XDG_RUNTIME_DIR="+dir)
	if r.code != 1 || !strings.Contains(r.stderr, "not reachable") {
		t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
	}
}

func TestClientSendNoReply(t *testing.T) {
	dir, _ := startFakeServer(t, "", 0) // closes without replying
	r := runHelper(t, "main", []string{"ping"}, "XDG_RUNTIME_DIR="+dir)
	if r.code != 1 || !strings.Contains(r.stderr, "no reply") {
		t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
	}
}

// A chord reply arrives only after the hold, so the client's read deadline must
// exceed holdMs (here 3.5s > the plain 3s read timeout).
func TestClientChordReadTimeoutExceedsHold(t *testing.T) {
	if testing.Short() {
		t.Skip("slow")
	}
	dir, _ := startFakeServer(t, "ok\n", 3500*time.Millisecond)
	r := runHelper(t, "main", []string{"chord", "3500", "guide", "b"}, "XDG_RUNTIME_DIR="+dir)
	if r.code != 0 || strings.TrimSpace(r.stdout) != "ok" {
		t.Fatalf("code=%d stdout=%q stderr=%q", r.code, r.stdout, r.stderr)
	}
}

func TestClientNonChordReadTimeout(t *testing.T) {
	if testing.Short() {
		t.Skip("slow")
	}
	dir, _ := startFakeServer(t, "ok\n", 4*time.Second) // > 3s plain timeout
	r := runHelper(t, "main", []string{"ping"}, "XDG_RUNTIME_DIR="+dir)
	if r.code != 1 || !strings.Contains(r.stderr, "no reply") {
		t.Fatalf("code=%d stdout=%q stderr=%q", r.code, r.stdout, r.stderr)
	}
}
