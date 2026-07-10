//go:build linux

// c4pad - virtual gamepad bridge for the Control4 Steam Machine driver.
//
// Security model: NO network listener. The daemon holds a persistent uinput
// virtual Xbox 360 pad and accepts commands only on an owner-only Unix domain
// socket. The client mode is invoked by System Bridge's COMMAND_EXECUTE
// allowlist (fixed argv, no runtime arguments), so the only network surface
// is System Bridge's existing token-authenticated WebSocket.
//
//	c4pad daemon [-hold-timeout 5s] [-tap 40ms]
//	c4pad press|hold|release <button>
//	c4pad releaseall | ping | version
//
// Buttons: up down left right (D-pad hat), a b x y, lb rb, start select guide, l3 r3
//
// Hold contract: a held button is auto-released after -hold-timeout (dead-man
// against stuck input). Callers wanting a longer hold must re-send the same
// 'hold <button>' within that window; a repeat refreshes the timestamp.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/ThomasT75/uinput"
)

const version = "1.0.0"

// A valid command line ("hold right\n") is well under this; cap the read so a
// client that never sends a newline cannot make us buffer unboundedly.
const maxCmdBytes = 128

// Cap concurrent connection handlers so a local client cannot exhaust
// goroutines/FDs by holding many slow connections open at once.
const maxConcurrentConns = 8

// Identity per the kernel xpad driver table so Steam/SDL auto-map the pad
// (drivers/input/joystick/xpad.c: 0x045e/0x028e "Microsoft X-Box 360 pad").
const (
	padName   = "Microsoft X-Box 360 pad"
	padVendor = 0x045e
	padModel  = 0x028e
)

var buttonCodes = map[string]int{
	"a":      uinput.ButtonSouth,      // BTN_A  0x130
	"b":      uinput.ButtonEast,       // BTN_B  0x131
	"x":      uinput.ButtonNorth,      // BTN_X  0x133
	"y":      uinput.ButtonWest,       // BTN_Y  0x134
	"lb":     uinput.ButtonBumperLeft, // BTN_TL 0x136
	"rb":     uinput.ButtonBumperRight,
	"select": uinput.ButtonSelect,
	"start":  uinput.ButtonStart,
	"guide":  uinput.ButtonMode, // BTN_MODE 0x13c, the Steam/Xbox button
	"l3":     uinput.ButtonThumbLeft,
	"r3":     uinput.ButtonThumbRight,
}

var hatDirections = map[string]uinput.HatDirection{
	"up":    uinput.HatUp,
	"down":  uinput.HatDown,
	"left":  uinput.HatLeft,
	"right": uinput.HatRight,
}

// opposite hat direction on the same axis: HatRelease zeroes the whole axis,
// so a tap of one direction physically ends a hold of the other
var hatOpposite = map[string]string{
	"up": "down", "down": "up", "left": "right", "right": "left",
}

func runtimeDir() string {
	dir := os.Getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		// never fall back to world-writable /tmp: the name would be squattable
		// and daemon/client could silently resolve different paths
		fmt.Fprintln(os.Stderr, "c4pad: XDG_RUNTIME_DIR is not set; run from a systemd user unit or a logind session")
		os.Exit(1)
	}
	return dir
}

func socketPath() string {
	return filepath.Join(runtimeDir(), "c4pad.sock")
}

// assertOwnerPrivateDir refuses to run unless the socket's parent directory is
// a real dir, owned by us, with no group/other bits. This closes socket-path
// squat/rename/TOCTOU vectors on the .sock and .lock files if XDG_RUNTIME_DIR
// is ever pointed at a shared/world-traversable path. Under a logind session /
// systemd user unit (the only supported launch path) /run/user/<uid> is 0700
// and this always passes.
func assertOwnerPrivateDir(dir string) {
	fi, err := os.Lstat(dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "c4pad: cannot stat "+dir+": "+err.Error())
		os.Exit(1)
	}
	if fi.Mode()&os.ModeSymlink != 0 || !fi.IsDir() {
		fmt.Fprintln(os.Stderr, "c4pad: "+dir+" is not a real directory")
		os.Exit(1)
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		if int(st.Uid) != os.Getuid() {
			fmt.Fprintln(os.Stderr, "c4pad: "+dir+" is not owned by the current user")
			os.Exit(1)
		}
	}
	if fi.Mode().Perm()&0o077 != 0 {
		fmt.Fprintln(os.Stderr, "c4pad: "+dir+" is group/other-accessible; refusing (socket would not be private)")
		os.Exit(1)
	}
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "daemon":
		runDaemon(os.Args[2:])
	case "press", "hold", "release":
		if len(os.Args) != 3 {
			usage()
			os.Exit(2)
		}
		clientSend(os.Args[1] + " " + strings.ToLower(os.Args[2]))
	case "releaseall", "ping":
		clientSend(os.Args[1])
	case "version":
		fmt.Println("c4pad " + version)
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: c4pad daemon [-hold-timeout D] [-tap D] | press|hold|release <button> | releaseall | ping | version")
}

// ---------------------------------------------------------------------------
// client mode (invoked by System Bridge COMMAND_EXECUTE allowlist entries)
// ---------------------------------------------------------------------------

func clientSend(line string) {
	conn, err := net.DialTimeout("unix", socketPath(), 2*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "c4pad daemon not reachable at "+socketPath()+": "+err.Error())
		os.Exit(1)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))

	if _, err := conn.Write([]byte(line + "\n")); err != nil {
		fmt.Fprintln(os.Stderr, "write failed: "+err.Error())
		os.Exit(1)
	}
	reply, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		fmt.Fprintln(os.Stderr, "no reply: "+err.Error())
		os.Exit(1)
	}
	reply = strings.TrimSpace(reply)
	fmt.Println(reply)
	if !strings.HasPrefix(reply, "ok") {
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// daemon mode
// ---------------------------------------------------------------------------

type daemon struct {
	mu          sync.Mutex
	pad         uinput.Gamepad
	held        map[string]time.Time // button/hat token -> time held (for dead-man release)
	tapDelay    time.Duration
	holdTimeout time.Duration
	sem         chan struct{} // bounds concurrent connection handlers
}

func runDaemon(args []string) {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	holdTimeout := fs.Duration("hold-timeout", 5*time.Second, "auto-release held buttons after this long (stuck-button dead-man)")
	tapDelay := fs.Duration("tap", 40*time.Millisecond, "duration a 'press' holds the button down")
	_ = fs.Parse(args)

	assertOwnerPrivateDir(runtimeDir())
	sock := socketPath()

	// single-instance guard: flock is atomic and auto-released on process
	// death (incl. SIGKILL), unlike a dial-probe which races a second startup
	lockFile, err := os.OpenFile(sock+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot open lock file: "+err.Error())
		os.Exit(1)
	}
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		// exit 0: benign duplicate, must not trip systemd Restart=on-failure
		fmt.Fprintln(os.Stderr, "another c4pad daemon is already running (lock held on "+sock+".lock)")
		os.Exit(0)
	}
	// lockFile stays open (and locked) for the daemon's lifetime.
	// Under the lock, any existing socket file is by definition stale.
	_ = os.Remove(sock)

	pad, err := uinput.CreateGamepad("/dev/uinput", []byte(padName), padVendor, padModel)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot create virtual gamepad: "+err.Error())
		fmt.Fprintln(os.Stderr, "check /dev/uinput access: getfacl /dev/uinput (see install docs for the udev fallback)")
		os.Exit(1)
	}

	d := &daemon{
		pad:         pad,
		held:        map[string]time.Time{},
		tapDelay:    *tapDelay,
		holdTimeout: *holdTimeout,
		sem:         make(chan struct{}, maxConcurrentConns),
	}

	// owner-only socket: restrict via umask during listen, then verify
	oldMask := syscall.Umask(0177)
	listener, err := net.Listen("unix", sock)
	syscall.Umask(oldMask)
	if err != nil {
		_ = pad.Close()
		fmt.Fprintln(os.Stderr, "cannot listen on "+sock+": "+err.Error())
		os.Exit(1)
	}
	_ = os.Chmod(sock, 0o600)

	fmt.Println("c4pad " + version + " up: virtual pad '" + padName + "' created, socket " + sock)

	// dead-man janitor: release anything held longer than holdTimeout
	stop := make(chan struct{})
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				d.releaseStale()
			}
		}
	}()

	// graceful shutdown: release everything and destroy the pad
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		close(stop)
		listener.Close()
		d.releaseAll()
		_ = d.pad.Close()
		_ = os.Remove(sock)
		os.Exit(0)
	}()

	for {
		conn, err := listener.Accept()
		if err != nil {
			// listener closed during shutdown
			return
		}
		select {
		case d.sem <- struct{}{}:
			go func() {
				defer func() { <-d.sem }()
				d.handle(conn)
			}()
		default:
			// at capacity: drop rather than pile up goroutines
			_, _ = conn.Write([]byte("err busy\n"))
			_ = conn.Close()
		}
	}
}

func (d *daemon) handle(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	// bound the read so a client that never sends a newline can't make us
	// buffer unboundedly (local memory-exhaustion DoS)
	line, err := bufio.NewReader(io.LimitReader(conn, maxCmdBytes)).ReadString('\n')
	if err != nil && line == "" {
		return
	}
	fields := strings.Fields(strings.ToLower(line))

	reply := "err bad command"
	switch {
	case len(fields) == 1 && fields[0] == "ping":
		reply = "ok pong"
	case len(fields) == 1 && fields[0] == "releaseall":
		d.releaseAll()
		reply = "ok"
	case len(fields) == 2:
		if err := d.execute(fields[0], fields[1]); err != nil {
			reply = "err " + err.Error()
		} else {
			reply = "ok"
		}
	}
	_, _ = conn.Write([]byte(reply + "\n"))
}

func (d *daemon) execute(action, token string) error {
	hat, isHat := hatDirections[token]
	code, isButton := buttonCodes[token]
	if !isHat && !isButton {
		return fmt.Errorf("unknown button %q", token)
	}

	d.mu.Lock()
	defer d.mu.Unlock()

	switch action {
	case "press":
		delete(d.held, token) // a tap ends any active hold of this token
		if isHat {
			delete(d.held, hatOpposite[token]) // tap release zeroes the shared axis
			if err := d.pad.HatPress(hat); err != nil {
				return err
			}
			time.Sleep(d.tapDelay)
			return d.pad.HatRelease(hat)
		}
		if err := d.pad.ButtonDown(code); err != nil {
			return err
		}
		time.Sleep(d.tapDelay)
		return d.pad.ButtonUp(code)

	case "hold":
		var err error
		if isHat {
			err = d.pad.HatPress(hat)
		} else {
			err = d.pad.ButtonDown(code)
		}
		if err == nil {
			d.held[token] = time.Now()
		}
		return err

	case "release":
		delete(d.held, token)
		if isHat {
			return d.pad.HatRelease(hat)
		}
		return d.pad.ButtonUp(code)
	}
	return fmt.Errorf("unknown action %q", action)
}

func (d *daemon) releaseToken(token string) {
	if hat, ok := hatDirections[token]; ok {
		_ = d.pad.HatRelease(hat)
	} else if code, ok := buttonCodes[token]; ok {
		_ = d.pad.ButtonUp(code)
	}
}

func (d *daemon) releaseStale() {
	d.mu.Lock()
	defer d.mu.Unlock()
	now := time.Now()
	for token, since := range d.held {
		if now.Sub(since) > d.holdTimeout {
			d.releaseToken(token)
			delete(d.held, token)
		}
	}
}

func (d *daemon) releaseAll() {
	d.mu.Lock()
	defer d.mu.Unlock()
	for token := range d.held {
		d.releaseToken(token)
		delete(d.held, token)
	}
}
