#!/usr/bin/env bash
# c4tls installer for SteamOS (run ON the Steam Machine as the session user).
# Sets up the TLS-terminating proxy that puts the System Bridge token on an
# encrypted wss:// channel. No root required.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/c4tls"
UNIT_DIR="$HOME/.config/systemd/user"
LISTEN_PORT="${C4TLS_PORT:-9171}"

echo "== c4tls install =="

# Detect the LAN IP the Control4 Director will connect to (so it goes in the cert SAN).
LAN_IP="${C4TLS_SAN_IP:-}"
if [ -z "$LAN_IP" ]; then
	LAN_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')" || true
fi
if [ -z "$LAN_IP" ]; then
	echo "WARNING: could not auto-detect the LAN IP; set C4TLS_SAN_IP=<ip> and re-run for pinned mode to work." >&2
fi

# 1) binary (owner-only regular file; refuse an unsafe install dir)
if [ -L "$INSTALL_DIR" ]; then echo "refusing: $INSTALL_DIR is a symlink" >&2; exit 1; fi
if [ -e "$INSTALL_DIR" ]; then
	if [ "$(stat -c %u "$INSTALL_DIR")" != "$(id -u)" ] || [ $(( 0$(stat -c %a "$INSTALL_DIR") & 022 )) -ne 0 ]; then
		echo "refusing: $INSTALL_DIR is not owner-only" >&2; exit 1
	fi
fi
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"
rm -f "$INSTALL_DIR/c4tls"
install -m 700 "$HERE/c4tls" "$INSTALL_DIR/c4tls"
echo "installed $INSTALL_DIR/c4tls"

# 2) generate the cert (with the LAN IP as CN + SAN) and print it for pinning
if [ -n "$LAN_IP" ]; then
	"$INSTALL_DIR/c4tls" -regen -certdir "$INSTALL_DIR" -san "$LAN_IP" >/dev/null 2>&1 || true
else
	"$INSTALL_DIR/c4tls" -regen -certdir "$INSTALL_DIR" >/dev/null 2>&1 || true
fi
chmod 600 "$INSTALL_DIR/key.pem" 2>/dev/null || true
chmod 644 "$INSTALL_DIR/cert.pem" 2>/dev/null || true

# 3) systemd user unit (survives updates, autostarts in game mode)
mkdir -p "$UNIT_DIR"
# stamp the detected port/certdir into the unit
sed "s/-listen :9171/-listen :$LISTEN_PORT/" "$HERE/c4tls.service" > "$UNIT_DIR/c4tls.service"
systemctl --user daemon-reload
systemctl --user enable c4tls.service
systemctl --user restart c4tls.service
echo "c4tls.service enabled + (re)started on port $LISTEN_PORT"

# 4) print the pinning material
echo ""
echo "== TLS setup for Composer =="
echo "In the Steam Machine driver properties:"
echo "  - Connection Security: 'TLS encrypt-only (wss://)'  (simplest; stops passive sniffing)"
echo "  - TLS Port: $LISTEN_PORT"
echo ""
echo "For 'TLS pinned (wss://)' (also stops active MITM), additionally paste this"
echo "single line into the driver's 'Server Certificate' property:"
echo ""
if command -v base64 >/dev/null 2>&1; then
	base64 -w0 "$INSTALL_DIR/cert.pem"; echo ""
else
	echo "(base64 unavailable; paste the PEM below instead)"
	cat "$INSTALL_DIR/cert.pem"
fi
echo ""
echo "Certificate SHA-256 (verify it matches what the driver reports):"
"$INSTALL_DIR/c4tls" -print-cert -certdir "$INSTALL_DIR" 2>/dev/null | grep -i sha256 || true
echo "== done =="
