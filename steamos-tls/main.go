//go:build linux

// c4tls - TLS-terminating reverse proxy for the Control4 Steam Machine driver.
//
// System Bridge speaks plaintext ws:// only, so the token travels in cleartext
// on the LAN. c4tls terminates TLS on the LAN side and forwards the decrypted
// stream to System Bridge on loopback, so the token is encrypted on the wire and
// exists in cleartext only on the machine's own loopback interface.
//
//	Control4 Director  --wss:// (TLS)-->  c4tls :9171  --ws:// (loopback)-->  System Bridge 127.0.0.1:9170
//
// Stdlib only (crypto/tls, net) — no third-party dependencies. On first run it
// generates a self-signed cert covering the SANs you pass; the client (the
// driver) can either accept it without verification (encrypt-only, stops passive
// sniffing) or pin the printed cert as its trust anchor (also stops active MITM).
//
//	c4tls -listen :9171 -backend 127.0.0.1:9170 -certdir <dir> -san <ip-or-host> [-san ...]
//	c4tls -print-cert -certdir <dir>     # print the cert PEM + fingerprint (for pinning)
package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const version = "1.0.0"

type sanList []string

func (s *sanList) String() string { return strings.Join(*s, ",") }
func (s *sanList) Set(v string) error {
	*s = append(*s, v)
	return nil
}

func main() {
	var sans sanList
	listen := flag.String("listen", ":9171", "TLS listen address (LAN side)")
	backend := flag.String("backend", "127.0.0.1:9170", "plaintext backend (System Bridge)")
	certDir := flag.String("certdir", defaultCertDir(), "directory holding cert.pem / key.pem")
	flag.Var(&sans, "san", "IP or hostname to include in the cert SAN (repeatable); include the LAN IP the Director connects to")
	printCert := flag.Bool("print-cert", false, "print the certificate PEM and SHA-256 fingerprint, then exit")
	regen := flag.Bool("regen", false, "regenerate the certificate even if one exists")
	minTLS := flag.String("min-tls", "1.2", "minimum TLS version: 1.0, 1.1, or 1.2 (lower only if an old Control4 controller cannot negotiate 1.2)")
	showVer := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVer {
		fmt.Println("c4tls " + version)
		return
	}

	certPath := filepath.Join(*certDir, "cert.pem")
	keyPath := filepath.Join(*certDir, "key.pem")

	if *printCert {
		pemBytes, err := os.ReadFile(certPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "no certificate at "+certPath+": "+err.Error())
			os.Exit(1)
		}
		printCertInfo(pemBytes)
		return
	}

	// -regen is an admin action: (re)generate the cert and EXIT (never start the
	// proxy), so the installer can call it synchronously and then print the cert.
	if *regen {
		_ = os.Remove(certPath)
		_ = os.Remove(keyPath)
		if err := ensureCert(*certDir, certPath, keyPath, sans); err != nil {
			fmt.Fprintln(os.Stderr, "cert error: "+err.Error())
			os.Exit(1)
		}
		if pemBytes, err := os.ReadFile(certPath); err == nil {
			printCertInfo(pemBytes)
		}
		return
	}

	// Normal (service) start: generate only if absent, then listen.
	if err := ensureCert(*certDir, certPath, keyPath, sans); err != nil {
		fmt.Fprintln(os.Stderr, "cert error: "+err.Error())
		os.Exit(1)
	}

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot load keypair: "+err.Error())
		os.Exit(1)
	}

	minVer := uint16(tls.VersionTLS12)
	switch *minTLS {
	case "1.0":
		minVer = tls.VersionTLS10
	case "1.1":
		minVer = tls.VersionTLS11
	case "1.2":
		minVer = tls.VersionTLS12
	default:
		fmt.Fprintln(os.Stderr, "c4tls: unknown -min-tls "+*minTLS+"; using 1.2")
	}

	tlsCfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   minVer,
	}

	ln, err := tls.Listen("tcp", *listen, tlsCfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cannot listen on "+*listen+": "+err.Error())
		os.Exit(1)
	}
	defer ln.Close()

	fmt.Printf("c4tls %s up: TLS %s -> %s\n", version, *listen, *backend)
	if pemBytes, err := os.ReadFile(certPath); err == nil {
		if fp, ok := fingerprint(pemBytes); ok {
			fmt.Println("cert SHA-256: " + fp)
		}
	}

	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return // listener closed (shutdown)
			}
			// transient accept error: log and keep serving
			fmt.Fprintln(os.Stderr, "c4tls: accept error: "+err.Error())
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go proxy(conn, *backend)
	}
}

// proxy terminates the TLS conn and splices it to a fresh backend TCP conn.
func proxy(client net.Conn, backend string) {
	defer client.Close()

	up, err := net.DialTimeout("tcp", backend, 5*time.Second)
	if err != nil {
		return
	}
	defer up.Close()

	done := make(chan struct{}, 2)
	// client -> backend
	go func() {
		_, _ = io.Copy(up, client)
		if c, ok := up.(*net.TCPConn); ok {
			_ = c.CloseWrite() // half-close so the backend sees EOF
		}
		done <- struct{}{}
	}()
	// backend -> client
	go func() {
		_, _ = io.Copy(client, up)
		if c, ok := client.(*tls.Conn); ok {
			_ = c.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	<-done
}

func defaultCertDir() string {
	if dir := os.Getenv("XDG_DATA_HOME"); dir != "" {
		return filepath.Join(dir, "c4tls")
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, ".local", "share", "c4tls")
	}
	return "."
}

// ensureCert generates a self-signed cert covering sans if cert/key are absent.
func ensureCert(dir, certPath, keyPath string, sans sanList) error {
	if _, err := os.Stat(certPath); err == nil {
		if _, err := os.Stat(keyPath); err == nil {
			return nil // already present
		}
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}

	// RSA-2048: the most universally accepted server-cert algorithm for old
	// embedded OpenSSL TLS clients (Control4's stack is vintage — its documented
	// method enum tops out at tlsv1_1). ed25519/ECDSA are smaller but riskier
	// against an unknown client.
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return err
	}

	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}

	// First operator-supplied IP becomes the CN too — some TLS clients match the
	// connect IP against CN as well as SAN, so cover both (zero downside).
	cn := "c4tls"
	for _, s := range sans {
		if net.ParseIP(s) != nil {
			cn = s
			break
		}
	}

	tmpl := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: cn},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		// self-signed leaf usable directly as its own pinned trust anchor across
		// both lenient (Go) and strict (OpenSSL) clients — hence IsCA + CertSign
		IsCA: true,
	}

	// Always cover loopback; add operator-supplied IPs/hostnames.
	tmpl.IPAddresses = append(tmpl.IPAddresses, net.IPv4(127, 0, 0, 1), net.IPv6loopback)
	for _, s := range sans {
		if ip := net.ParseIP(s); ip != nil {
			tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
		} else {
			tmpl.DNSNames = append(tmpl.DNSNames, s)
		}
	}
	// Deliberately no os.Hostname() fallback: the driver connects by IP, so an
	// internal hostname SAN adds nothing and would leak the box name into the
	// pinned cert.

	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return err
	}

	certOut, err := os.OpenFile(certPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if err := pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: der}); err != nil {
		certOut.Close()
		return err
	}
	certOut.Close()

	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	keyOut, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if err := pem.Encode(keyOut, &pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}); err != nil {
		keyOut.Close()
		return err
	}
	keyOut.Close()

	fmt.Fprintln(os.Stderr, "c4tls: generated self-signed cert at "+certPath)
	return nil
}

// fingerprint returns the SHA-256 of the DER cert as colon-separated hex,
// matching `openssl x509 -fingerprint -sha256` so the installer can verify it.
func fingerprint(pemBytes []byte) (string, bool) {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return "", false
	}
	sum := sha256.Sum256(block.Bytes)
	pairs := make([]string, len(sum))
	for i, b := range sum {
		pairs[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(pairs, ":"), true
}

func printCertInfo(pemBytes []byte) {
	if fp, ok := fingerprint(pemBytes); ok {
		fmt.Println("SHA-256 fingerprint: " + fp)
	}
	fmt.Print(string(pemBytes))
}
