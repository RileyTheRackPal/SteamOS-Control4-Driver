#!/usr/bin/env bash
# c4pad installer for SteamOS (run ON the Steam Machine, as the desktop/game session user).
# No root needed on stock SteamOS: Valve's own udev rules already grant the
# session user access to /dev/uinput (TAG+="uaccess").
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/c4pad"
UNIT_DIR="$HOME/.config/systemd/user"
SB_DIR="${SYSTEM_BRIDGE_CONFIG_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/system-bridge/v5}"
SETTINGS="$SB_DIR/settings.json"

echo "== c4pad install =="

# 1) binary — this path becomes a System-Bridge-invocable (COMMAND_EXECUTE) and
#    systemd-autostarted executable, so it must be a regular file owned by us
#    with no group/world write. Refuse unsafe install dirs before writing.
if [ -L "$INSTALL_DIR" ]; then
	echo "refusing: $INSTALL_DIR is a symlink" >&2; exit 1
fi
if [ -e "$INSTALL_DIR" ]; then
	if [ "$(stat -c %u "$INSTALL_DIR")" != "$(id -u)" ] || [ $(( 0$(stat -c %a "$INSTALL_DIR") & 022 )) -ne 0 ]; then
		echo "refusing: $INSTALL_DIR is not owner-only (must be owned by you, no group/world write)" >&2; exit 1
	fi
fi
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"
# install unlink-replaces (never writes through a symlink) and sets mode 700:
# no group/world read or write on the executable itself
rm -f "$INSTALL_DIR/c4pad"
install -m 700 "$HERE/c4pad" "$INSTALL_DIR/c4pad"
if [ ! -f "$INSTALL_DIR/c4pad" ] || [ -L "$INSTALL_DIR/c4pad" ] || [ "$(stat -c %u "$INSTALL_DIR/c4pad")" != "$(id -u)" ]; then
	echo "binary integrity check failed for $INSTALL_DIR/c4pad" >&2; exit 1
fi
echo "installed $INSTALL_DIR/c4pad"
command -v sha256sum >/dev/null 2>&1 && sha256sum "$INSTALL_DIR/c4pad"

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
systemctl --user enable c4pad.service
# restart (not --now) so re-running the installer upgrades a live daemon too
systemctl --user restart c4pad.service
echo "c4pad.service enabled + (re)started"

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

chmod 600 "$ALLOW"  # generated file names the exec path; keep it owner-only
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
	# the backup sits next to the plaintext token file; do not leave it world-readable
	( umask 077; cp -f "$SETTINGS" "$SETTINGS.bak" )
	chmod --reference="$SETTINGS" "$SETTINGS.bak" 2>/dev/null || chmod 600 "$SETTINGS.bak"
	# replace-by-prefix: drop all prior c4pad_* entries, append the fresh 21
	# (idempotent re-install; foreign entries keep their order); preserve mode
	if jq --slurpfile new "$ALLOW" \
		'.commands.allowlist = (((.commands.allowlist // []) | map(select(((.id // "") | startswith("c4pad_")) | not))) + $new[0])' \
		"$SETTINGS" > "$SETTINGS.tmp" \
		&& chmod --reference="$SETTINGS" "$SETTINGS.tmp"; then
		mv "$SETTINGS.tmp" "$SETTINGS"
		echo "merged 21 entries into $SETTINGS (backup: settings.json.bak)"
		echo "RESTART System Bridge to pick up the allowlist."
	else
		rm -f "$SETTINGS.tmp"
		echo "ERROR: allowlist merge failed; $SETTINGS left unchanged (backup at settings.json.bak)" >&2
	fi
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
