# Control4 Steam Machine driver suite — 0.1.0-beta.1

First public beta. Control4 DriverWorks drivers to control a Steam Machine (or any
SteamOS / Linux PC running [System Bridge](https://system-bridge.timmo.dev/) v5),
with optional SteamOS helpers for game-mode input and encrypted transport.

## What's in the bundle

```
drivers/
  steam-machine.c4z            main driver (add this to your project)
  steam-game-miniapp.c4z       blank per-game tile template
  games/                       per-game drivers (top-50 most-played + all Valve titles)
steamos-helpers/
  steamos-pad/   c4pad + install.sh + unit + README   (gamepad bridge)
  steamos-tls/   c4tls + install.sh + unit + README   (TLS proxy)
README.md · SECURITY.md · docs/GENERATED_DRIVERS.md
```

## Features

- **Steam Machine control** over System Bridge: Wake-on-LAN power on, sleep/shutdown/
  restart/lock, launch games by App ID or `steam://` URI, notifications, media control.
- **Navigator integration**: appears in a room's Watch list (media_player proxy),
  transport + D-pad mapped to the machine; power/media state reported back.
- **Programming**: events (online/offline, on/off, game launched, media, colored
  buttons), variables (uptime, CPU/GPU temp, usage, now-playing), and device commands.
- **Game mini-drivers**: one `.c4z` per game with the square Steam icon baked in;
  `tools/make-game-drivers.ps1` batch-builds the top-50 most-played + all Valve titles.
- **c4pad Gamepad Bridge** (optional): a virtual Xbox 360 pad so navigator keys work
  in game mode, plus Steam-button chords (on-screen keyboard, Quick Access, screenshot,
  magnifier, force-quit) bound to the colored (RGBY) navigator buttons. No network listener.
- **c4tls TLS proxy** (optional): encrypts the System Bridge token on the LAN
  (`wss://` → loopback), since System Bridge itself is plaintext-only.
- **Security**: the API token is stored in Director's encrypted PersistData (not a
  cleartext property); `steam://`-only URI allowlist; input sanitization. Full threat
  model in `SECURITY.md`.
- **Steam-themed documentation** on Composer's Documentation tab.

## Install (quick)

1. Composer → Driver → Add or Update Driver → add `drivers/steam-machine.c4z`.
2. Connections → Network: enter the Steam Machine IP. Bind HDMI OUT to your display.
3. Paste the System Bridge token (`system-bridge client token`) into the driver property.
4. Optional: add game drivers from `drivers/games/` and bind each to a Game App slot.
5. Optional helpers: copy `steamos-helpers/steamos-pad` (and `/steamos-tls`) to the
   Steam Machine and run `install.sh`. See `SECURITY.md` for deployment hardening.

## Beta status — verify on hardware

This build is **unverified on real Control4 + Steam Machine hardware**. Known
hardware-verify items:

- The mini-app AV routing / `SET_INPUT` chain (modeled on Control4's shipped Roku driver).
- c4pad: Steam-button chords firing in game mode; the X/Y button-label orientation.
- c4tls **pinned** TLS mode (whether the Director's TLS client accepts the self-signed
  CA) — the **encrypt-only** mode is the no-cert fallback.
- Whether a dealer-programmed colored button reaches the driver's `Red/Green/…` command.

The `.c4z` files are **unencrypted developer drivers** (Composer will flag them as such).
Driver encryption is optional and protects only the Lua source, not the token (which is
already stored encrypted). See `SECURITY.md`.

## Requirements

- Control4 OS 3.x; System Bridge **v5** on the Steam Machine (SteamOS/Linux).
- For power-on: Wake-on-LAN enabled in firmware + wired Ethernet.
- Helpers target SteamOS game mode; install as user systemd services (survive updates).
