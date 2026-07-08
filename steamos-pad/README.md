# c4pad - virtual gamepad bridge for SteamOS

Makes Control4 navigator D-pad/select/back work in **game mode** (Big Picture), where
keyboard injection cannot reach. A tiny daemon holds a persistent virtual **Xbox 360
controller** (`/dev/uinput`) that Steam treats exactly like a real pad - correct glyphs,
works in the UI *and in games*.

## Security model

- **No network listener.** The daemon accepts commands only on an owner-only
  (`0600`) Unix domain socket in `$XDG_RUNTIME_DIR` (it refuses to start
  without `XDG_RUNTIME_DIR` rather than fall back to a world-writable dir);
  single-instance is enforced with an atomic `flock`.
- The Control4 driver triggers buttons through **System Bridge's existing
  token-authenticated WebSocket** via `COMMAND_EXECUTE` allowlist entries -
  fixed program + arguments, no runtime arguments, no shell. The c4pad entries
  add no new commands, but be clear about what a stolen System Bridge token
  already buys: with the Gamepad Bridge installed it means full game-mode UI
  control (Big Picture navigation, on-screen keyboard, settings, and - combined
  with System Bridge's built-in OPEN event - store pages, including purchase
  flows if a payment method is saved; consider a Steam purchase PIN). The token
  also grants System Bridge's own power/open/file commands, so treat it as a
  full local-user credential. It travels in cleartext over `ws://` in every
  message - keep port 9170 on a trusted LAN/VLAN and never port-forward it.
- A dead-man timer auto-releases any held button after 5 s, so a dropped
  remote can never leave the D-pad stuck (the driver refreshes active holds
  every 2 s to sustain intentional long holds).
- On stock SteamOS no root is needed: Valve's own udev rules already grant the
  session user access to `/dev/uinput` (the same mechanism Steam Input uses).

## Install

1. On Windows: `pwsh tools/build-c4pad.ps1` -> `dist/c4pad` (static linux/amd64 binary)
2. Copy `dist/c4pad`, `steamos-pad/install.sh`, `steamos-pad/c4pad.service` to one
   folder on the Steam Machine (e.g. via `scp`), then run `./install.sh` as the
   normal session user (no sudo). It:
   - installs the binary to `~/c4pad/` and a **user** systemd unit (both survive
     SteamOS updates and autostart in game mode)
   - generates and (with `jq`) merges the 21 `c4pad_*` allowlist entries into
     System Bridge's `settings.json` - **restart System Bridge afterwards**
   - verifies `/dev/uinput` access and prints a one-time sudo fallback
     (udev rule + update keep-list) if your image lacks the standard ACL
3. In Composer: set the driver's **Nav Input Backend** property to **Gamepad Bridge**.

Note: for `COMMAND_EXECUTE` to reach `~/c4pad/c4pad`, run System Bridge as a native
binary/user service (recommended), not the Flatpak - the Flatpak sandbox may block
spawning host binaries.

## Test on the machine

```bash
~/c4pad/c4pad ping           # ok pong
~/c4pad/c4pad press guide    # Steam menu should open
~/c4pad/c4pad press down     # D-pad down in the UI
```

## Button map (Control4 -> pad)

| Navigator | Pad | | Navigator | Pad |
|---|---|---|---|---|
| D-pad | D-pad (hat, true hold/release) | | Info | X |
| OK/Enter | A | | Menu | Start |
| Back/Cancel | B | | Guide | Guide (Steam) |
| Page Up/Down | LB / RB | | | |

Verify-on-hardware notes: X/Y label orientation (library naming vs kernel aliases -
check in Steam's controller tester and swap `x`/`y` codes in `main.go` if reversed);
the virtual pad reports version 0x0001 rather than a real pad's 0x0114 (Steam matches
VID/PID so this should not matter); the uinput library advertises the D-pad hat with a
+/-32767 range while emitting +/-1 like a real xpad - SDL handles hats by sign so this
should be invisible, but confirm D-pad response in the controller tester.
