#!/usr/bin/env bash
# c4pad installer for SteamOS (run ON the Steam Machine, as the desktop/game session user).
# No root needed on stock SteamOS: Valve's own udev rules already grant the
# session user access to /dev/uinput (TAG+="uaccess").
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/c4pad"
UNIT_DIR="$HOME/.config/systemd/user"
SB_DIR="${SYSTEM_BRIDGE_CONFIG_DIR:-$HOME/.local/share/system-bridge/v5}"
SETTINGS="$SB_DIR/settings.json"

echo "== c4pad install =="

# 1) binary
mkdir -p "$INSTALL_DIR"
cp -f "$HERE/c4pad" "$INSTALL_DIR/c4pad"
chmod +x "$INSTALL_DIR/c4pad"
echo "installed $INSTALL_DIR/c4pad"

# 2) check /dev/uinput access for this user
if getfacl -p /dev/uinput 2>/dev/null | grep -q "user:$(id -un):rw"; then
	echo "/dev/uinput: OK (uaccess ACL present for $(id -un))"
else
	cat <<'EOF'
WARNING: no per-user ACL found on /dev/uinput. On stock SteamOS this should
exist. Fallback (needs sudo, once):

  sudo tee /etc/udev/rules.d/60-c4pad.rules >/dev/null <<'RULE'
KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
RULE
  sudo mkdir -p /etc/atomic-update.conf.d
  printf '[keep]\n/etc/udev/rules.d/60-c4pad.rules\n' | sudo tee /etc/atomic-update.conf.d/c4pad-keep.conf >/dev/null
  sudo udevadm control --reload-rules && sudo udevadm trigger && sudo modprobe uinput

(The keep-list drop-in makes the rule survive SteamOS updates.)
EOF
fi

# 3) systemd user unit (survives SteamOS updates, autostarts in game mode)
mkdir -p "$UNIT_DIR"
cp -f "$HERE/c4pad.service" "$UNIT_DIR/c4pad.service"
systemctl --user daemon-reload
systemctl --user enable --now c4pad.service
echo "c4pad.service enabled + started"

# 4) System Bridge command allowlist
ALLOW="$HERE/c4pad-allowlist.json"
{
	echo '['
	first=1
	emit() {
		[ $first -eq 1 ] && first=0 || echo ','
		printf '  {"id":"c4pad_%s_%s","name":"c4pad %s %s","command":"%s/c4pad","workingDir":"%s","arguments":["%s","%s"]}' \
			"$1" "$2" "$1" "$2" "$INSTALL_DIR" "$INSTALL_DIR" "$1" "$2"
	}
	for b in up down left right; do
		emit press "$b"; emit hold "$b"; emit release "$b"
	done
	for b in a b x y lb rb start select guide; do
		emit press "$b"
	done
	echo ''
	echo ']'
} > "$ALLOW"
echo "generated $ALLOW"

if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
	cp -f "$SETTINGS" "$SETTINGS.bak"
	jq --slurpfile new "$ALLOW" \
		'.commands.allowlist = (((.commands.allowlist // []) + $new[0]) | unique_by(.id))' \
		"$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
	echo "merged 21 entries into $SETTINGS (backup: settings.json.bak)"
	echo "RESTART System Bridge to pick up the allowlist."
else
	cat <<EOF
Could not auto-merge (jq missing or $SETTINGS not found).
Manually merge the contents of $ALLOW into the "commands": {"allowlist": [...]}
array of $SETTINGS, then restart System Bridge.
EOF
fi

# 5) smoke test
sleep 1
if "$INSTALL_DIR/c4pad" ping >/dev/null 2>&1; then
	echo "daemon reachable: OK. Try: $INSTALL_DIR/c4pad press guide (Steam menu should open)"
else
	echo "daemon not reachable yet - check: systemctl --user status c4pad"
fi
echo "== done =="
