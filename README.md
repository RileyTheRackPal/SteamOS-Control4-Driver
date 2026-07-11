# Control4 Steam Machine Driver (via System Bridge)

Control4 DriverWorks drivers for controlling a [Steam Machine](https://store.steampowered.com/hardware/steammachine)
(or any SteamOS / Linux / Windows PC) through [System Bridge](https://system-bridge.timmo.dev/) v5,
with per-game quick-launch **mini drivers** using Steam's `steam://` URI handling.

## What's here

| Directory | Driver | Purpose |
|---|---|---|
| `steam-machine/` | **Steam Machine (System Bridge)** | Main device driver: media_player proxy, HDMI/audio outputs, WoL power-on, System Bridge WebSocket control, programming events/variables, hosts up to 25 game mini apps |
| `steam-game-miniapp/` | **Steam Game (Mini App)** | Per-game Watch-list tile; publishes its `steam://` URI to the parent (universal-minidriver pattern, `RF_MINI_APP`) |
| `steamos-pad/` | **c4pad** | SteamOS helper: persistent uinput virtual Xbox 360 pad + owner-only local socket, driven via System Bridge `COMMAND_EXECUTE` (no network listener) - makes navigator keys work in game mode; see [steamos-pad/README.md](steamos-pad/README.md) |
| `steamos-tls/` | **c4tls** | Optional TLS-terminating proxy: encrypts the System Bridge token on the LAN (`wss://` -> loopback `ws://`); stdlib-only static binary; see [steamos-tls/README.md](steamos-tls/README.md) |
| `tools/build.ps1` | - | Packages each driver folder into a `.c4z` under `dist/` |
| `tools/build-c4pad.ps1` | - | Cross-compiles the c4pad SteamOS helper (static linux/amd64) |
| `tools/build-c4tls.ps1` | - | Cross-compiles the c4tls TLS proxy (static linux/amd64) |
| `tools/make-game-driver.ps1` | - | Builds one per-game mini-driver `.c4z` from a Steam AppID, with the game's square icon (official client icon → logo → box art) baked in as the Navigator icons |
| `tools/make-game-drivers.ps1` | - | Batch-builds mini-drivers for the top-50 most-played games and/or all Valve titles |
| `tools/steam-driver-lib.ps1` | - | Shared library used by the two generators (icon fetch/compositing + driver packaging) |
| `tools/make-icons.ps1` | - | Regenerates the placeholder icons |

## Features

- **Connections view**: Steam Machine IP entered on the Network tab (port 9170); HDMI OUT + AUDIO OUT physical connections
- **System Design properties**: Launch Into Big Picture (On/Off), Off Mode (Sleep / Power Off / Do Nothing), MAC address, System Bridge token, live status for network / System Bridge / Director connection
- **Actions tab**: Get MAC Address From Steam Machine (auto-fetch via System Bridge), Test Connection, Send Test Notification, Launch Big Picture Now
- **Programming**: events (Came Online, Went Offline, Turned On/Off, Game Launched, Notification Sent, Media Started/Paused/Stopped), variables (uptime, CPU/GPU temperature, CPU/memory usage, battery, hostname, now playing, current game), and device commands (power, launch game by App ID, open URI, notifications, media control, keyboard keys)
- **Navigator media controls**: transport keys -> System Bridge media control (MPRIS); D-pad/Enter/Back -> keyboard injection; Menu/Home -> Big Picture; Guide -> Steam library
- **Power**: on = Wake-on-LAN (+ optional Big Picture launch), off = suspend or shutdown per the Off Mode property; picking a game while the machine sleeps wakes it and launches once System Bridge reconnects

## Build

```powershell
pwsh tools/build.ps1   # -> dist/steam-machine.c4z, dist/steam-game-miniapp.c4z
```

Install the `.c4z` files via Composer Pro > Driver > Add or Update Driver. See each driver's
`www/documentation.html` (shown in Composer's Documentation tab) for setup steps, including
System Bridge installation on SteamOS and per-game mini-app cloning with custom icons.

## Steam Machine prerequisites

1. System Bridge v5 installed and running (Flatpak recommended on SteamOS; config/token live in `~/.local/share/system-bridge/v5/`)
2. Token from `system-bridge client token` pasted into the driver's properties
3. Wake-on-LAN enabled in firmware + wired Ethernet for power-on
4. `playerctl` present for media control (bundled in most desktop installs)

## Security & privacy (read before deploying)

**[SECURITY.md](SECURITY.md) is required reading before you install this on an
end-user system.** In short:

- The System Bridge **token is a full local-user credential** (arbitrary file
  reads, shutdown, `OPEN`, keyboard, command execution) and travels in
  **cleartext over `ws://`** by default. Encrypt it by installing the **c4tls
  proxy** (`steamos-tls/`) and setting the driver's **Connection Security**
  property to a TLS mode. Whether or not you enable TLS, put the Steam Machine +
  Director on a **dedicated VLAN**, **firewall port 9170 to the Director only**,
  and never port-forward it.
- The token is stored in Director's **encrypted PersistData**, not in a cleartext
  property (Token Status property + Clear Stored Token action). Still don't share
  project backups taken with a real token. Driver encryption is optional and only
  protects the source code, not the token.
- The driver enforces a **`steam://`-only URI allowlist**, sanitizes inbound
  data, and the c4pad helper has **no network listener** and runs sandboxed. See
  SECURITY.md for the full threat model, the data collected, and residual risk.

## Known limitations

- Keyboard injection (the default Nav Input Backend) may not reach the gamescope game session on SteamOS (X11-only injection); install the **c4pad Gamepad Bridge** (`steamos-pad/`) and switch the backend property to fix navigation in game mode - `steam://` launching works everywhere either way
- Media transport controls MPRIS players (browser/Spotify), not the game itself; Media Mute is one-way (playerctl sets player volume to 0)
- With Off Mode = `Power Off`, a queued game launch survives up to 5 minutes of cold boot; Sleep mode (default) resumes in seconds
- "Notification Sent" event fires for notifications sent *by Control4*; System Bridge does not report other desktop notifications
- The token is stored in Director's **encrypted PersistData** (not in a cleartext property); see [SECURITY.md](SECURITY.md). The developer `.c4z` is unsigned/unencrypted (Composer treats it as a developer driver) — optionally encrypt it with the free DriverPackager to also hide the source, but note driver encryption protects the *code*, not the stored token

## Reference

- The **Programming reference** (events, device commands, colored-button actions, variables) lives in the driver's own documentation — [steam-machine/www/documentation.html](steam-machine/www/documentation.html), shown on Composer's Documentation tab
- [docs/GENERATED_DRIVERS.md](docs/GENERATED_DRIVERS.md) — the game mini-drivers `make-game-drivers.ps1` produces (top-50 + all Valve titles)

## Implementation notes

- WebSocket client + dispatch layers are the official Snap One [drivers-common-public](https://github.com/control4/drivers-common-public) libraries, vendored under `steam-machine/drivers-common-public/`
- The mini-app contract (RF_MINI_APP binding, `SET_INPUT`, `PASSTHROUGH`, `APP_NAME`/`UM_STEAM_MACHINE` device variables) mirrors Control4's shipped `roku.c4z` / `um_netflix.c4z` universal-minidriver pattern
- System Bridge protocol targets v5.x (Go): token in every WS message, `DATA_UPDATE` pushes routed by `module`, media actions `PLAY/PAUSE/NEXT/PREVIOUS/STOP/VOLUME_UP/VOLUME_DOWN/MUTE`
