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
| `tools/build.ps1` | - | Packages each driver folder into a `.c4z` under `dist/` |
| `tools/build-c4pad.ps1` | - | Cross-compiles the c4pad SteamOS helper (static linux/amd64) |
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

## Known limitations

- Keyboard injection (the default Nav Input Backend) may not reach the gamescope game session on SteamOS (X11-only injection); install the **c4pad Gamepad Bridge** (`steamos-pad/`) and switch the backend property to fix navigation in game mode - `steam://` launching works everywhere either way
- Media transport controls MPRIS players (browser/Spotify), not the game itself; Media Mute is one-way (playerctl sets player volume to 0)
- With Off Mode = `Power Off`, a queued game launch survives up to 5 minutes of cold boot; Sleep mode (default) resumes in seconds
- "Notification Sent" event fires for notifications sent *by Control4*; System Bridge does not report other desktop notifications
- The drivers are unsigned/unencrypted; Composer will treat them as developer drivers

## Implementation notes

- WebSocket client + dispatch layers are the official Snap One [drivers-common-public](https://github.com/control4/drivers-common-public) libraries, vendored under `steam-machine/drivers-common-public/`
- The mini-app contract (RF_MINI_APP binding, `SET_INPUT`, `PASSTHROUGH`, `APP_NAME`/`UM_STEAM_MACHINE` device variables) mirrors Control4's shipped `roku.c4z` / `um_netflix.c4z` universal-minidriver pattern
- System Bridge protocol targets v5.x (Go): token in every WS message, `DATA_UPDATE` pushes routed by `module`, media actions `PLAY/PAUSE/NEXT/PREVIOUS/STOP/VOLUME_UP/VOLUME_DOWN/MUTE`
