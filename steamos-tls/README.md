# c4tls - TLS proxy for System Bridge

System Bridge speaks plaintext `ws://` only, so the System Bridge token travels in
**cleartext on the LAN**. `c4tls` is a tiny TLS-terminating reverse proxy that puts
that traffic on an encrypted `wss://` channel:

```
Control4 Director  --wss:// (TLS)-->  c4tls :9171  --ws:// (loopback)-->  System Bridge 127.0.0.1:9170
```

The token is then encrypted on the wire and exists in cleartext only on the Steam
Machine's own loopback interface.

## Why a proxy (and why our own)

- System Bridge has no TLS and no plans to add it; we can't change that.
- The driver's WebSocket layer already supports `wss://`, so the only missing
  piece is something on the Steam Machine to terminate TLS.
- c4tls is **stdlib-only Go** (empty `go.sum` — nothing to audit or CVE-track),
  a single static binary, same deployment model as c4pad. It is a byte-level TCP
  forwarder, so the WebSocket upgrade passes through untouched.

## Security model

- Terminates TLS on the LAN side, forwards **plaintext only to loopback** `127.0.0.1:9170`.
- On first run it generates a self-signed **RSA-2048** cert (10-year) whose CN and
  SAN include loopback plus the LAN IP you pass, so it validates whether the
  Control4 client checks the name or just the chain. The cert is marked `IsCA` so
  it works as its own pinned trust anchor under both lenient and strict clients.
- The private key is `0600`; the cert is public.
- Runs under a sandboxed systemd user unit (`ProtectSystem=strict`,
  `ProtectHome=read-only`, syscall filter, INET+loopback only).

## Install

1. On Windows: `pwsh tools/build-c4tls.ps1` -> `dist/c4tls` (static linux/amd64).
2. Copy `dist/c4tls`, `steamos-tls/install.sh`, `steamos-tls/c4tls.service` to the
   Steam Machine and run `./install.sh` (no sudo). It auto-detects the LAN IP for
   the cert SAN (override with `C4TLS_SAN_IP=<ip>`), installs a user systemd unit,
   and prints the cert (base64 + SHA-256) for pinning.
3. In Composer, set the driver properties:
   - **Connection Security**: `TLS encrypt-only (wss://)` (simplest; stops passive
     sniffing) or `TLS pinned (wss://)` (also stops active MITM).
   - **TLS Port**: `9171` (or your override).
   - For pinned mode, paste the base64 line the installer printed into **Server
     Certificate**.

## Modes

| Mode | Driver `VERIFY_MODE` | Stops passive sniffing | Stops active MITM | Setup |
|---|---|---|---|---|
| Plaintext (ws://) | — | no | no | none (default) |
| TLS encrypt-only | `none` | **yes** | no | run c4tls |
| TLS pinned | `peer` + cert | **yes** | **yes** | run c4tls + paste cert |

## Hardware-verify notes

The Go-side design is functionally tested (cert SAN, pinned + encrypt-only
handshakes round-trip). What can only be confirmed against a real Control4
controller:

- Whether the Director's (vintage OpenSSL) TLS client accepts an RSA-2048
  self-signed CA via `CACERTFILE` for pinned mode. If pinned fails on your
  firmware, fall back to `TLS encrypt-only` (still encrypts the token) — that
  path uses `VERIFY_MODE='none'` and needs no cert.
- Whether it matches the connect IP against the SAN (we put an IP SAN + CN=IP to
  cover both behaviors).

If pinned mode won't connect, the driver logs it (Debug Mode = Print) and you can
switch to encrypt-only with no cert.

## CLI

```
c4tls -listen :9171 -backend 127.0.0.1:9170 -certdir <dir> -san <lan-ip>
c4tls -print-cert -certdir <dir>     # print PEM + SHA-256 (pinning handoff)
c4tls -regen     -certdir <dir> -san <lan-ip>   # regenerate the cert
```
