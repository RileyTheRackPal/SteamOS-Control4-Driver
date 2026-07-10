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

# 2) cert: generate only if absent (re-running the installer must NOT rotate the
#    cert and silently invalidate a pinned Server Certificate in Composer).
#    Force rotation with C4TLS_REGEN=1. -regen generates and exits (no listen).
SAN_ARGS=()
[ -n "$LAN_IP" ] && SAN_ARGS=(-san "$LAN_IP")
if [ "${C4TLS_REGEN:-0}" = "1" ] || [ ! -f "$INSTALL_DIR/cert.pem" ]; then
	if ! "$INSTALL_DIR/c4tls" -regen -certdir "$INSTALL_DIR" "${SAN_ARGS[@]}"; then
		echo "ERROR: certificate generation failed" >&2; exit 1
	fi
else
	echo "keeping existing cert (set C4TLS_REGEN=1 to rotate)"
fi
if [ ! -f "$INSTALL_DIR/cert.pem" ]; then
	echo "ERROR: no certificate at $INSTALL_DIR/cert.pem" >&2; exit 1
fi
chmod 600 "$INSTALL_DIR/key.pem"
chmod 644 "$INSTALL_DIR/cert.pem"

# 3) systemd user unit (survives updates, autostarts in game mode)
mkdir -p "$UNIT_DIR"
# stamp the detected port into the unit; anchor on the flag (not the value) and
# verify the substitution took, so a future unit reformat can't silently ship 9171
sed -E "s/-listen :[0-9]+/-listen :$LISTEN_PORT/" "$HERE/c4tls.service" > "$UNIT_DIR/c4tls.service"
grep -q -- "-listen :$LISTEN_PORT" "$UNIT_DIR/c4tls.service" || {
	echo "ERROR: failed to stamp listen port into the unit (ExecStart format changed?)" >&2; exit 1
}
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
"$INSTALL_DIR/c4tls" -print-cert -certdir "$INSTALL_DIR" 2>/dev/null | grep -i fingerprint || true
echo "== done =="
