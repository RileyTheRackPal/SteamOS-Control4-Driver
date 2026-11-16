//go:build linux

package main

import (
	"bytes"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"flag"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// sanList
// ---------------------------------------------------------------------------

func TestSanListSetAndString(t *testing.T) {
	var s sanList
	if got := s.String(); got != "" {
		t.Errorf("empty String() = %q", got)
	}
	for _, v := range []string{"192.168.1.5", "steam.lan", "10.0.0.1"} {
		if err := s.Set(v); err != nil {
			t.Fatalf("Set(%q): %v", v, err)
		}
	}
	if got, want := s.String(), "192.168.1.5,steam.lan,10.0.0.1"; got != want {
		t.Errorf("String() = %q, want %q", got, want)
	}
	if len(s) != 3 {
		t.Errorf("len = %d", len(s))
	}
}

func TestSanListAsFlagValue(t *testing.T) {
	var s sanList
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	fs.Var(&s, "san", "")
	if err := fs.Parse([]string{"-san", "1.2.3.4", "-san", "host.example"}); err != nil {
		t.Fatal(err)
	}
	if len(s) != 2 || s[0] != "1.2.3.4" || s[1] != "host.example" {
		t.Errorf("sans = %v", s)
	}
}

// ---------------------------------------------------------------------------
// defaultCertDir
// ---------------------------------------------------------------------------

func TestDefaultCertDir(t *testing.T) {
	t.Run("XDG_DATA_HOME", func(t *testing.T) {
		t.Setenv("XDG_DATA_HOME", "/xdg/data")
		t.Setenv("HOME", "/home/someone")
		if got, want := defaultCertDir(), filepath.Join("/xdg/data", "c4tls"); got != want {
			t.Errorf("got %q want %q", got, want)
		}
	})
	t.Run("HOME fallback", func(t *testing.T) {
		t.Setenv("XDG_DATA_HOME", "")
		t.Setenv("HOME", "/home/someone")
		if got, want := defaultCertDir(), filepath.Join("/home/someone", ".local", "share", "c4tls"); got != want {
			t.Errorf("got %q want %q", got, want)
		}
	})
	t.Run("no home", func(t *testing.T) {
		t.Setenv("XDG_DATA_HOME", "")
		t.Setenv("HOME", "")
		if got := defaultCertDir(); got != "." {
			t.Errorf("got %q want \".\"", got)
		}
	})
}

// ---------------------------------------------------------------------------
// ensureCert / fingerprint
// ---------------------------------------------------------------------------

func genCert(t *testing.T, sans sanList) (dir, certPath, keyPath string) {
	t.Helper()
	dir = filepath.Join(t.TempDir(), "certs", "nested")
	certPath = filepath.Join(dir, "cert.pem")
	keyPath = filepath.Join(dir, "key.pem")
	if err := ensureCert(dir, certPath, keyPath, sans); err != nil {
		t.Fatalf("ensureCert: %v", err)
	}
	return
}

func parseCertFile(t *testing.T, path string) *x509.Certificate {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	blk, _ := pem.Decode(b)
	if blk == nil || blk.Type != "CERTIFICATE" {
		t.Fatalf("no CERTIFICATE block in %s", path)
	}
	c, err := x509.ParseCertificate(blk.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func TestEnsureCertCreatesFilesWithPerms(t *testing.T) {
	dir, certPath, keyPath := genCert(t, sanList{"192.168.1.50"})

	di, err := os.Stat(dir)
	if err != nil || !di.IsDir() {
		t.Fatalf("cert dir not created: %v", err)
	}
	if m := di.Mode().Perm(); m&0o077 != 0 {
		t.Errorf("dir perm = %#o, want no group/other bits", m)
	}
	ci, err := os.Stat(certPath)
	if err != nil {
		t.Fatal(err)
	}
	if m := ci.Mode().Perm(); m != 0o644 && m != 0o640 && m != 0o600 {
		t.Errorf("cert perm = %#o", m)
	}
	ki, err := os.Stat(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if m := ki.Mode().Perm(); m != 0o600 {
		t.Errorf("key perm = %#o, want 0600", m)
	}
}

func TestEnsureCertContents(t *testing.T) {
	_, certPath, keyPath := genCert(t, sanList{"192.168.1.50", "steam.lan", "fd00::1"})
	c := parseCertFile(t, certPath)

	if c.Subject.CommonName != "192.168.1.50" {
		t.Errorf("CN = %q, want first IP SAN", c.Subject.CommonName)
	}
	if !c.IsCA || !c.BasicConstraintsValid {
		t.Error("cert should be IsCA with valid basic constraints (self-pinning)")
	}
	if c.KeyUsage&x509.KeyUsageCertSign == 0 || c.KeyUsage&x509.KeyUsageDigitalSignature == 0 || c.KeyUsage&x509.KeyUsageKeyEncipherment == 0 {
		t.Errorf("key usage = %v", c.KeyUsage)
	}
	if len(c.ExtKeyUsage) != 1 || c.ExtKeyUsage[0] != x509.ExtKeyUsageServerAuth {
		t.Errorf("ext key usage = %v", c.ExtKeyUsage)
	}
	if c.SerialNumber == nil || c.SerialNumber.Sign() <= 0 {
		t.Errorf("serial = %v", c.SerialNumber)
	}
	now := time.Now()
	if !c.NotBefore.Before(now) {
		t.Errorf("NotBefore %v not in the past", c.NotBefore)
	}
	if c.NotAfter.Before(now.AddDate(9, 11, 0)) {
		t.Errorf("NotAfter %v is less than ~10 years out", c.NotAfter)
	}
	if err := c.CheckSignatureFrom(c); err != nil {
		t.Errorf("not self-signed: %v", err)
	}

	// SANs: loopback always, plus operator IPs and DNS names
	for _, ip := range []string{"127.0.0.1", "::1", "192.168.1.50", "fd00::1"} {
		if err := c.VerifyHostname(ip); err != nil {
			t.Errorf("SAN missing %s: %v", ip, err)
		}
	}
	if err := c.VerifyHostname("steam.lan"); err != nil {
		t.Errorf("DNS SAN missing: %v", err)
	}
	if err := c.VerifyHostname("other.lan"); err == nil {
		t.Error("cert unexpectedly valid for other.lan")
	}
	if err := c.VerifyHostname("10.9.9.9"); err == nil {
		t.Error("cert unexpectedly valid for unlisted IP")
	}
	if len(c.DNSNames) != 1 || c.DNSNames[0] != "steam.lan" {
		t.Errorf("DNSNames = %v", c.DNSNames)
	}

	// no hostname leak
	if h, err := os.Hostname(); err == nil && h != "" && h != "steam.lan" {
		for _, n := range c.DNSNames {
			if n == h {
				t.Errorf("os.Hostname %q leaked into cert", h)
			}
		}
	}

	// key matches cert, PKCS#8 RSA-2048
	kb, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	blk, _ := pem.Decode(kb)
	if blk == nil || blk.Type != "PRIVATE KEY" {
		t.Fatalf("key PEM block = %v", blk)
	}
	k, err := x509.ParsePKCS8PrivateKey(blk.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	rk, ok := k.(*rsa.PrivateKey)
	if !ok {
		t.Fatalf("key type %T", k)
	}
	if rk.N.BitLen() != 2048 {
		t.Errorf("key size = %d", rk.N.BitLen())
	}
	if !rk.PublicKey.Equal(c.PublicKey) {
		t.Error("private key does not match cert public key")
	}
	if _, err := tls.LoadX509KeyPair(certPath, keyPath); err != nil {
		t.Errorf("LoadX509KeyPair: %v", err)
	}
}

func TestEnsureCertCNDefaultsWhenNoIP(t *testing.T) {
	_, certPath, _ := genCert(t, sanList{"steam.lan"})
	if cn := parseCertFile(t, certPath).Subject.CommonName; cn != "c4tls" {
		t.Errorf("CN = %q, want c4tls", cn)
	}
	_, certPath, _ = genCert(t, nil)
	c := parseCertFile(t, certPath)
	if c.Subject.CommonName != "c4tls" {
		t.Errorf("CN = %q", c.Subject.CommonName)
	}
	if err := c.VerifyHostname("127.0.0.1"); err != nil {
		t.Errorf("loopback SAN missing with no operator SANs: %v", err)
	}
}

func TestEnsureCertFirstIPBecomesCN(t *testing.T) {
	_, certPath, _ := genCert(t, sanList{"host.lan", "10.1.1.1", "10.2.2.2"})
	if cn := parseCertFile(t, certPath).Subject.CommonName; cn != "10.1.1.1" {
		t.Errorf("CN = %q, want 10.1.1.1", cn)
	}
}

func TestEnsureCertReusesExisting(t *testing.T) {
	dir, certPath, keyPath := genCert(t, sanList{"192.168.1.50"})
	certBefore, _ := os.ReadFile(certPath)
	keyBefore, _ := os.ReadFile(keyPath)

	// different SANs must NOT regenerate when both files exist
	if err := ensureCert(dir, certPath, keyPath, sanList{"10.0.0.9"}); err != nil {
		t.Fatal(err)
	}
	certAfter, _ := os.ReadFile(certPath)
	keyAfter, _ := os.ReadFile(keyPath)
	if !bytes.Equal(certBefore, certAfter) || !bytes.Equal(keyBefore, keyAfter) {
		t.Error("existing cert/key were overwritten")
	}
}

func TestEnsureCertRegeneratesIfKeyMissing(t *testing.T) {
	dir, certPath, keyPath := genCert(t, nil)
	before, _ := os.ReadFile(certPath)
	if err := os.Remove(keyPath); err != nil {
		t.Fatal(err)
	}
	if err := ensureCert(dir, certPath, keyPath, nil); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(certPath)
	if bytes.Equal(before, after) {
		t.Error("cert not regenerated although key was missing")
	}
	if _, err := tls.LoadX509KeyPair(certPath, keyPath); err != nil {
		t.Errorf("regenerated pair invalid: %v", err)
	}
}

func TestEnsureCertRegeneratesIfCertMissing(t *testing.T) {
	dir, certPath, keyPath := genCert(t, nil)
	if err := os.Remove(certPath); err != nil {
		t.Fatal(err)
	}
	if err := ensureCert(dir, certPath, keyPath, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := tls.LoadX509KeyPair(certPath, keyPath); err != nil {
		t.Errorf("regenerated pair invalid: %v", err)
	}
}

func TestEnsureCertUniqueSerials(t *testing.T) {
	_, c1, _ := genCert(t, nil)
	_, c2, _ := genCert(t, nil)
	if parseCertFile(t, c1).SerialNumber.Cmp(parseCertFile(t, c2).SerialNumber) == 0 {
		t.Error("two generated certs share a serial")
	}
}

func TestEnsureCertUncreatableDir(t *testing.T) {
	base := t.TempDir()
	blocker := filepath.Join(base, "file")
	if err := os.WriteFile(blocker, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(blocker, "sub") // parent is a regular file
	if err := ensureCert(dir, filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem"), nil); err == nil {
		t.Error("expected error when dir cannot be created")
	}
}

func TestEnsureCertUnwritableCertPath(t *testing.T) {
	dir := t.TempDir()
	// certPath points into a nonexistent subdirectory -> OpenFile fails
	err := ensureCert(dir, filepath.Join(dir, "missing", "cert.pem"), filepath.Join(dir, "key.pem"), nil)
	if err == nil {
		t.Error("expected error when cert file cannot be created")
	}
}

func TestFingerprint(t *testing.T) {
	_, certPath, _ := genCert(t, sanList{"192.168.1.50"})
	pemBytes, _ := os.ReadFile(certPath)
	fp, ok := fingerprint(pemBytes)
	if !ok {
		t.Fatal("fingerprint !ok on valid PEM")
	}

	blk, _ := pem.Decode(pemBytes)
	sum := sha256.Sum256(blk.Bytes)
	parts := strings.Split(fp, ":")
	if len(parts) != 32 {
		t.Fatalf("got %d groups, want 32: %s", len(parts), fp)
	}
	for i, p := range parts {
		if len(p) != 2 || p != strings.ToUpper(p) {
			t.Fatalf("group %d = %q, want 2 upper-case hex chars", i, p)
		}
		var b byte
		for _, ch := range []byte(p) {
			b <<= 4
			switch {
			case ch >= '0' && ch <= '9':
				b |= ch - '0'
			case ch >= 'A' && ch <= 'F':
				b |= ch - 'A' + 10
			default:
				t.Fatalf("non-hex %q in %q", ch, p)
			}
		}
		if b != sum[i] {
			t.Fatalf("byte %d = %02X, want %02X", i, b, sum[i])
		}
	}
	// deterministic
	if fp2, _ := fingerprint(pemBytes); fp2 != fp {
		t.Error("fingerprint not deterministic")
	}
	// trailing junk after the PEM block is ignored
	if fp3, ok := fingerprint(append(append([]byte{}, pemBytes...), "garbage\n"...)); !ok || fp3 != fp {
		t.Error("trailing data changed fingerprint")
	}
}

func TestFingerprintInvalid(t *testing.T) {
	for _, in := range [][]byte{nil, {}, []byte("not pem"), []byte("-----BEGIN CERTIFICATE-----\n!!!notbase64\n-----END CERTIFICATE-----\n")} {
		if fp, ok := fingerprint(in); ok || fp != "" {
			t.Errorf("fingerprint(%q) = %q,%v; want \"\",false", in, fp, ok)
		}
	}
}

func TestFingerprintDiffersBetweenCerts(t *testing.T) {
	_, a, _ := genCert(t, nil)
	_, b, _ := genCert(t, nil)
	pa, _ := os.ReadFile(a)
	pb, _ := os.ReadFile(b)
	fa, _ := fingerprint(pa)
	fb, _ := fingerprint(pb)
	if fa == fb {
		t.Error("distinct certs share a fingerprint")
	}
}

func TestPrintCertInfo(t *testing.T) {
	_, certPath, _ := genCert(t, nil)
	pemBytes, _ := os.ReadFile(certPath)
	out := captureStdout(t, func() { printCertInfo(pemBytes) })
	fp, _ := fingerprint(pemBytes)
	if !strings.HasPrefix(out, "SHA-256 fingerprint: "+fp+"\n") {
		t.Errorf("output header = %q", out[:min(len(out), 120)])
	}
	if !strings.HasSuffix(out, string(pemBytes)) {
		t.Error("output does not end with the PEM")
	}
	if out := captureStdout(t, func() { printCertInfo([]byte("junk")) }); out != "junk" {
		t.Errorf("invalid PEM output = %q (want only the raw bytes)", out)
	}
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	done := make(chan string)
	go func() { b, _ := io.ReadAll(r); done <- string(b) }()
	fn()
	w.Close()
	os.Stdout = old
	return <-done
}

// ---------------------------------------------------------------------------
// proxy()
// ---------------------------------------------------------------------------

// startEcho starts a loopback TCP server running handler per connection.
func startBackend(t *testing.T, handler func(net.Conn)) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip("cannot listen on loopback: ", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go handler(c)
		}
	}()
	return ln.Addr().String()
}

func TestProxyEchoBothDirectionsPlainConn(t *testing.T) {
	backend := startBackend(t, func(c net.Conn) {
		defer c.Close()
		_, _ = io.Copy(c, c)
	})
	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() { proxy(srv, backend); close(done) }()
	_ = cli.SetDeadline(time.Now().Add(10 * time.Second))

	msg := []byte("hello through the proxy")
	go func() { _, _ = cli.Write(msg) }()
	buf := make([]byte, len(msg))
	if _, err := io.ReadFull(cli, buf); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf, msg) {
		t.Errorf("echo = %q", buf)
	}
	cli.Close()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("proxy did not return after client close")
	}
}

func TestProxyBackendUnreachableClosesClient(t *testing.T) {
	// grab a port nobody listens on
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skip(err)
	}
	addr := ln.Addr().String()
	ln.Close()

	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() { proxy(srv, addr); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("proxy did not return when backend is down")
	}
	_ = cli.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := cli.Read(make([]byte, 1)); err == nil {
		t.Error("client conn should be closed (EOF)")
	}
}

func TestProxyBackendCloseEndsSession(t *testing.T) {
	backend := startBackend(t, func(c net.Conn) {
		_, _ = c.Write([]byte("bye"))
		c.Close()
	})
	cli, srv := net.Pipe()
	done := make(chan struct{})
	go func() { proxy(srv, backend); close(done) }()
	_ = cli.SetDeadline(time.Now().Add(10 * time.Second))
	b, _ := io.ReadAll(cli)
	if string(b) != "bye" {
		t.Errorf("got %q", b)
	}
	cli.Close() // proxy waits for both directions
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("proxy hung")
	}
}

// TLS front end -> plaintext backend, with the half-close paths (*tls.Conn
// CloseWrite and *net.TCPConn CloseWrite) exercised.
func TestProxyOverTLS(t *testing.T) {
	_, certPath, keyPath := genCert(t, sanList{"127.0.0.1"})
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		t.Fatal(err)
	}

	// backend: reads until EOF (proves CloseWrite half-close propagates), then
	// replies with an upper-cased copy and closes.
	backend := startBackend(t, func(c net.Conn) {
		defer c.Close()
		data, _ := io.ReadAll(c)
		_, _ = c.Write([]byte(strings.ToUpper(string(data))))
	})

	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Skip(err)
	}
	defer ln.Close()
	proxied := make(chan struct{})
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		proxy(c, backend)
		close(proxied)
	}()

	pool := x509.NewCertPool()
	pool.AddCert(parseCertFile(t, certPath))
	conn, err := tls.Dial("tcp", ln.Addr().String(), &tls.Config{RootCAs: pool, ServerName: "127.0.0.1", MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatalf("pinned-cert handshake failed: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))

	payload := bytes.Repeat([]byte("token=secret;"), 5000) // > one TLS record
	if _, err := conn.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := conn.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(conn)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, bytes.ToUpper(payload)) {
		t.Errorf("got %d bytes, want %d upper-cased bytes", len(got), len(payload))
	}
	select {
	case <-proxied:
	case <-time.After(10 * time.Second):
		t.Fatal("proxy did not finish")
	}
}

func TestProxyRejectsUnpinnedClient(t *testing.T) {
	_, certPath, keyPath := genCert(t, sanList{"127.0.0.1"})
	cert, _ := tls.LoadX509KeyPair(certPath, keyPath)
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{cert}})
	if err != nil {
		t.Skip(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			_ = c.(*tls.Conn).Handshake()
			c.Close()
		}
	}()
	// default roots do not trust the self-signed cert
	_, err = tls.Dial("tcp", ln.Addr().String(), &tls.Config{ServerName: "127.0.0.1"})
	if err == nil {
		t.Error("expected verification failure without pinning")
	}
}
