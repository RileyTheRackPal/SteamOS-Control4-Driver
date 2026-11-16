# Installation Guide

Dealer and integrator guide for the Control4 Steam Machine driver suite (`0.1.0-beta.1`).
It covers System Bridge on the Steam Machine, Composer setup, game mini-drivers, the optional
SteamOS helpers (c4pad and c4tls), verification, upgrades and removal.

> **Beta status.** This build is unverified on real Control4 and Steam Machine hardware. See
> [RELEASE_NOTES.md](../RELEASE_NOTES.md) for the list of hardware-verify items. Read
> [SECURITY.md](../SECURITY.md) before deploying on an end-user system.

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Install System Bridge on SteamOS](#2-install-system-bridge-on-steamos)
3. [Composer setup: the Steam Machine driver](#3-composer-setup-the-steam-machine-driver)
4. [Game mini-drivers](#4-game-mini-drivers)
5. [Optional SteamOS helpers: c4pad and c4tls](#5-optional-steamos-helpers-c4pad-and-c4tls)
6. [Post-install verification checklist](#6-post-install-verification-checklist)
7. [Upgrading](#7-upgrading)
8. [Uninstall and cleanup](#8-uninstall-and-cleanup)
9. [Related documents](#9-related-documents)

---

## 1. Prerequisites

| Requirement | Detail |
|---|---|
| Control4 OS | **3.x** (`minimum_os_version` is `3.0.0` in both `driver.xml` files). |
| Composer | Composer Pro, to add the `.c4z` drivers and edit properties. |
| Steam Machine | A Steam Machine, or any SteamOS / Linux PC, running **System Bridge v5**. |
| System Bridge | Installed, set to start automatically, and running in the background. See [section 2](#2-install-system-bridge-on-steamos). |
| Network | The Steam Machine and the Control4 Director on the same LAN. Use a **dedicated VLAN** if you can. Port `9170` (and `9171` if you use TLS) must be reachable from the Director only. |
| Wired Ethernet | Required for power-on. The in-driver documentation says Wake-on-LAN needs LAN (not Wi-Fi) connectivity, so use wired Ethernet for the Steam Machine. |
| Wake-on-LAN | Enabled in the Steam Machine's BIOS/firmware. The menu names are not documented in this repo, so check your firmware. |
| Reserved IP | Reserve the Steam Machine's IP address in DHCP so the Network binding does not change. |
| `playerctl` | Needed for media control. It is bundled in most desktop installs. |
| Helper build (optional) | `c4pad` and `c4tls` are static `linux/amd64` binaries. The release bundle ships them. |

**Note:** The repo does not document a Steam Machine firmware or BIOS menu for Wake-on-LAN.
Confirm with the manufacturer's documentation.

---

## 2. Install System Bridge on SteamOS

System Bridge is a third-party application. The project site is <https://system-bridge.timmo.dev/>.
This repo does not include System Bridge install commands, so follow its own documentation for
the package you choose.

**Options** (from [steam-machine/www/documentation.html](../steam-machine/www/documentation.html)):

- **Flatpak**: recommended for the base driver on SteamOS.
- **Native package or binary** with a *user* systemd service: this survives SteamOS updates.
  **Use this option if you plan to install c4pad.** The c4pad README says the Flatpak sandbox may
  block `COMMAND_EXECUTE` from spawning `~/c4pad/c4pad`, so use a native binary or user service
  (see [steamos-pad/README.md](../steamos-pad/README.md)).

**Steps:**

1. Install System Bridge v5 on the Steam Machine using one of the options above.
2. Make sure it starts automatically and keeps running in the background.
3. Get the API token. Run this on the Steam Machine:

   ```bash
   system-bridge client token
   ```

   Or read the token file directly:

   ```
   ~/.local/share/system-bridge/v5/token
   ```

4. Keep the token secret. It is a full local-user credential. See [SECURITY.md](../SECURITY.md)
   before you copy it anywhere.

**Facts the driver relies on:**

- System Bridge listens on **TCP 9170**, WebSocket path `/api/websocket`, plaintext `ws://`.
- Configuration and the token live in `~/.local/share/system-bridge/v5/`. The c4pad installer
  edits `settings.json` in this directory.

**Note:** For a Flatpak install, the config directory may sit inside the sandbox and differ from
the path above. The repo does not document this. Confirm where the token lives before you copy it.

---

## 3. Composer setup: the Steam Machine driver

### 3.1 Add the driver

1. In Composer Pro, choose **Driver > Add or Update Driver**.
2. Add `drivers/steam-machine.c4z` from the release bundle, or `dist/steam-machine.c4z` if you
   built it with `pwsh tools/build.ps1`.
3. Add the driver to the project and place it in a room.

The driver exposes a `media_player` proxy (Steam Machine) and an `avswitch` proxy (Steam App
Switcher), which hosts up to 25 game inputs. See [section 4](#4-game-mini-drivers).

### 3.2 Network connection

1. Go to **Connections > Network**.
2. Enter the Steam Machine's IP address.

The driver reads this from network binding `6001` ("Steam Machine Network (System Bridge)"). It
connects to port `9170` (plaintext) or to the TLS port (see [section 5.2](#52-c4tls-tls-proxy)).

If no address is set, the **Network Connection** property reads:

```
No address entered - set the IP in Connections > Network
```

### 3.3 HDMI and audio bindings

1. Go to **Connections > Control/AV**.
2. Bind **HDMI OUT** to your display or AVR.
3. Optionally bind **AUDIO OUT**. It accepts stereo, optical or coax.

These are the only outputs you need to bind for the Steam Machine itself. The other AV
connections are hidden and handled by the driver. The mini-app AV routing chain is a hardware-verify
item in the beta notes.

### 3.4 Paste the System Bridge token

1. Open the driver's **Properties** tab.
2. Paste the value from `system-bridge client token` into **System Bridge Token**.

**What happens next:** the driver moves the token into Director's **encrypted PersistData** store
and clears the plaintext property. The field then looks empty. This is expected.
**Token Status** changes to `Stored (encrypted at rest)`.

To replace the token, paste a new value into the field. An empty field does **not** clear the
stored token. Use the **Clear Stored Token** action to remove it.

### 3.5 Properties reference

Defaults and option lists below come from [steam-machine/driver.xml](../steam-machine/driver.xml).

#### Status properties (read-only)

| Property | Default | What it shows |
|---|---|---|
| Driver Version | `-` | Version string set by the driver at startup. |
| Director Connection | `-` | Set to `Connected (driver v<version> running)` once the driver starts. It shows that the driver is running. It does not test the link to the Steam Machine. |
| Network Connection | `No address entered` | TCP/WebSocket link state. Examples: `Connecting to <ip> (<mode>)...`, `Online (<ip>:<port>, <mode>)`, `Offline (<reason>)`. |
| System Bridge Connection | `Not connected` | `Connected and authenticated` after the Steam Machine answers a request without an error. |
| Token Status | `Not set` | `Stored (encrypted at rest)` when a token is stored. |

#### Connection and security

| Property | Type | Default | Options / notes |
|---|---|---|---|
| System Bridge Token | Password (masked) | blank | Paste the token. It is stored encrypted and then cleared. See [3.4](#34-paste-the-system-bridge-token). |
| Connection Security | List | `Plaintext (ws://)` | `Plaintext (ws://)`, `TLS encrypt-only (wss://)`, `TLS pinned (wss://)`. TLS modes need c4tls. See [5.2](#52-c4tls-tls-proxy). |
| TLS Port | String | `9171` | Port c4tls listens on. Used only in TLS modes. Must be `1`-`65535`; anything else falls back to `9171`. |
| Server Certificate | String | blank | Used by **TLS pinned** only. Paste the base64 line that the c4tls installer prints, or a full PEM. Leave blank for Plaintext and encrypt-only. |

Changing **Connection Security**, **TLS Port** (in a TLS mode) or **Server Certificate** (in a TLS
mode) reconnects the driver.

#### Power and launch

| Property | Default | Options and behaviour |
|---|---|---|
| MAC Address | blank | Used for Wake-on-LAN. Enter 12 hex digits in any common format; the driver normalizes it to `AA:BB:CC:DD:EE:FF`. A malformed entry is cleared. If blank, the driver fills it from System Bridge system data. Without a MAC, **no WoL packet is sent**. |
| Launch Into Big Picture | `On` | `On` or `Off`. When `On`, selecting the Steam Machine in a room opens Big Picture. |
| Off Mode | `Sleep` | `Sleep` (suspend), `Power Off` (shutdown), or `Do Nothing`. Applies to the room's **Off** command and to the **Power Off** command. |

Off Mode details from `driver.lua`:

- `Sleep` sends System Bridge `POWER_SLEEP`.
- `Power Off` sends System Bridge `POWER_SHUTDOWN`.
- `Do Nothing` sends nothing.
- A room **Off** is deferred by **5 seconds**. A source switch or power-on in that window cancels it.

#### Input

| Property | Default | Options and behaviour |
|---|---|---|
| Nav Input Backend | `Keyboard` | `Keyboard`: System Bridge key injection. Works in Desktop Mode, may not reach the game session. `Gamepad Bridge`: virtual controller through c4pad. Works in Big Picture and games. See [5.1](#51-c4pad-gamepad-bridge). |

#### Colored (RGBY) buttons

The four properties below set what the **Red**, **Green**, **Yellow** and **Blue** commands do. Each
has the same option list. Defaults are shown.

| Property | Default |
|---|---|
| Red Button Action | `Steam Menu` |
| Green Button Action | `Quick Access Menu` |
| Yellow Button Action | `Toggle On-Screen Keyboard` |
| Blue Button Action | `Screenshot` |

Option list for each: `None`, `Steam Menu`, `Quick Access Menu`, `Toggle On-Screen Keyboard`,
`Screenshot`, `Toggle Magnifier`, `Force Quit Game`, `Launch Big Picture`, `Media Play/Pause`,
`Fire Programming Event`.

Control4 does not route the colored buttons to the driver automatically. Program each navigator
button to its command (`Red Button`, `Green Button`, and so on) in Composer. See
[steam-machine/www/documentation.html](../steam-machine/www/documentation.html), section
"Colored (RGBY) navigator buttons".

**Note:** The chord actions (`Quick Access Menu`, `Toggle On-Screen Keyboard`, `Screenshot`,
`Toggle Magnifier`, `Force Quit Game`) need c4pad. `Launch Big Picture` and `Media Play/Pause` do
not. **`Steam Menu` is unclear:** `driver.lua` sends it as the c4pad chord `c4pad_steam`, so it
appears to need c4pad. The in-driver documentation says it does not. Treat it as needing c4pad
until you have tested it.

#### Debug

| Property | Default | Options |
|---|---|---|
| Debug Mode | `Off` | `Off`, `Print`. Turn it on only while troubleshooting. See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#2-how-to-enable-debug-mode). |

### 3.6 Actions tab

These buttons run once. They are not Programming commands.

| Action | What it does |
|---|---|
| Get MAC Address From Steam Machine | Asks System Bridge for the system data and fills **MAC Address**. Needs the machine online. If offline, the status reads `Cannot fetch MAC - Steam Machine is offline`. |
| Test Connection | Restarts the WebSocket connection now, without waiting for the back-off timer. |
| Send Test Notification | Sends a notification titled `Control4` to the Steam Machine. Does nothing while offline. |
| Launch Big Picture Now | Opens Steam Big Picture on the Steam Machine. |
| Clear Stored Token | Removes the encrypted token. **Token Status** returns to `Not set`. |

---

## 4. Game mini-drivers

Each game is its own mini-driver. It publishes a `steam://` URI to the parent Steam Machine
driver.

**Two ways to get one:**

- **Pre-built:** use a per-game `.c4z` from `drivers/games/` in the release bundle. The game name,
  App ID and icon are already set. The list is in [GENERATED_DRIVERS.md](GENERATED_DRIVERS.md).
- **Generic:** add `drivers/steam-game-miniapp.c4z` (or `steam-game-miniapp/` built from source)
  and fill in its properties yourself.

**Mini-driver properties** (from [steam-game-miniapp/driver.xml](../steam-game-miniapp/driver.xml)):

| Property | Notes |
|---|---|
| Game Name | Display name. Shown in the Watch list. Blank becomes `Steam Game`. |
| Steam App ID or URI | Either a numeric App ID (for example `620`), which becomes `steam://rungameid/620`, or a full `steam://` URI. Find App IDs at [steamdb.info](https://steamdb.info). |
| Launch URI | Read-only. Shows the URI the mini will publish. Anything else shows `Rejected: only a numeric App ID or a steam:// URI is allowed`. |

**Binding a game to the Steam Machine:**

1. In **Connections**, bind the mini-driver's **Steam Game** output (`RF_MINI_APP`) to a free
   **Game App N** input on the Steam Machine driver. Inputs 1 to 25 are available. They sit on the
   `Steam App Switcher` proxy.
2. Repeat for each game.

The game then appears in the room's Watch list and launches its `steam://` URI when selected.
Composer may auto-bind these inputs (`autobind` is set in `driver.xml`). Check the bindings.

**Note:** The repo does not describe where the tile appears in the Watch list or how Control4
orders the tiles. Treat that as a hardware-verify item.

---

## 5. Optional SteamOS helpers: c4pad and c4tls

Both helpers run on the Steam Machine as the normal session user, with no sudo. Each has a user
systemd unit so it survives SteamOS updates and starts in game mode. Both are optional.

Full details are in the helper READMEs:

- [steamos-pad/README.md](../steamos-pad/README.md) for c4pad
- [steamos-tls/README.md](../steamos-tls/README.md) for c4tls

### 5.1 c4pad (Gamepad Bridge)

**What it does:** a persistent virtual Xbox 360 controller (`/dev/uinput`). It makes the navigator
D-pad, Enter, Back, Menu and Guide work in game mode. It also sends Steam-button chords for the
colored buttons. It has **no network listener**. Commands arrive only through System Bridge's
`COMMAND_EXECUTE` allowlist, over an owner-only Unix socket.

**Install:**

1. Get the helper files. Use `steamos-helpers/steamos-pad/` from the release bundle. Or, on
   Windows, build with `pwsh tools/build-c4pad.ps1`, which produces `dist/c4pad`.
2. Copy `c4pad`, `install.sh` and `c4pad.service` to one folder on the Steam Machine (for example
   with `scp`).
3. Run the installer as the normal session user:

   ```bash
   ./install.sh
   ```

   The installer:

   - installs the binary to `~/c4pad/c4pad` and the unit to `~/.config/systemd/user/c4pad.service`;
   - enables and starts the user service;
   - writes the `c4pad_*` allowlist entries and merges them into System Bridge's `settings.json`
     (it keeps a `settings.json.bak` backup);
   - checks `/dev/uinput` access. If the ACL is missing, it prints a one-time sudo udev rule to run.
4. **Restart System Bridge** so it reads the new allowlist. The installer prints this reminder.
5. In Composer, set **Nav Input Backend** to `Gamepad Bridge`.

**Note:** The c4pad README says the installer adds **21** `c4pad_*` entries. `install.sh` writes
**27**: the 21 press, hold and release entries, plus six chord entries (`c4pad_steam`,
`c4pad_osk`, `c4pad_qam`, `c4pad_screenshot`, `c4pad_magnifier`, `c4pad_forcequit`). The count in
the README looks out of date.

**Test on the machine:**

```bash
~/c4pad/c4pad ping           # expect: ok pong
~/c4pad/c4pad press guide    # Steam menu should open
~/c4pad/c4pad press down     # D-pad down in the UI
~/c4pad/c4pad chord guide x  # on-screen keyboard should appear
```

**Prerequisites for the chords** (from the c4pad README): in Steam game mode, *Settings >
Controller > Xbox/generic configuration support* must be on, and the default Steam Button Chord
layout must be in use.

**Note:** The installer's sudo udev fallback is for images without the standard `/dev/uinput` ACL.
Read the installer output before you run any sudo command it prints.

### 5.2 c4tls (TLS proxy)

**What it does:** System Bridge speaks plaintext `ws://` only, so the token crosses the LAN in
cleartext. c4tls terminates TLS on the Steam Machine and forwards traffic only to loopback
`127.0.0.1:9170`:

```
Control4 Director  --wss:// (TLS)-->  c4tls :9171  --ws:// (loopback)-->  System Bridge 127.0.0.1:9170
```

**Install:**

1. Get the helper files. Use `steamos-helpers/steamos-tls/` from the release bundle. Or, on
   Windows, build with `pwsh tools/build-c4tls.ps1`, which produces `dist/c4tls`.
2. Copy `c4tls`, `install.sh` and `c4tls.service` to the Steam Machine.
3. Run the installer as the normal session user:

   ```bash
   ./install.sh
   ```

   Optional environment overrides, set before running the installer:

   - `C4TLS_SAN_IP=<ip>`: LAN IP to put in the certificate. The installer auto-detects it, and
     warns if it cannot. Set it explicitly if detection is wrong.
   - `C4TLS_PORT=<port>`: listen port. Defaults to `9171`.
   - `C4TLS_REGEN=1`: rotate the certificate. Only do this if you will re-paste the pin.

   The installer generates a self-signed RSA-2048 certificate once and keeps it on re-runs. It
   prints a single base64 line and the certificate's SHA-256 fingerprint.

4. Start order: c4tls forwards to System Bridge on loopback, so **System Bridge must be running**.

**Driver properties to match:**

| Property | Value |
|---|---|
| Connection Security | `TLS encrypt-only (wss://)` (simplest, no certificate needed) or `TLS pinned (wss://)` (also stops active MITM) |
| TLS Port | `9171`, or the value you set with `C4TLS_PORT` |
| Server Certificate | For pinned mode only: paste the base64 line the installer printed |

**Modes:**

| Mode | Stops passive sniffing | Stops active MITM | Setup |
|---|---|---|---|
| Plaintext (`ws://`) | no | no | none (default) |
| TLS encrypt-only | yes | no | run c4tls |
| TLS pinned | yes | yes | run c4tls and paste the certificate |

**Note on pinned mode:** Whether the Director's TLS client accepts the self-signed certificate is a
hardware-verify item. If pinned mode fails on your firmware, use `TLS encrypt-only`. It still
encrypts the token.

**Note on TLS version:** c4tls's default minimum is TLS 1.2. Older controller firmware may not
negotiate it. The c4tls README describes adding `-min-tls 1.1` (or `1.0`) to the `ExecStart` line
in `~/.config/systemd/user/c4tls.service`, then running `systemctl --user daemon-reload` and
`systemctl --user restart c4tls`.

**Re-running `install.sh`** keeps the existing certificate, so a pasted pin stays valid. Only
`C4TLS_REGEN=1` rotates it, and then you must paste the new certificate.

See [SECURITY.md](../SECURITY.md) for the threat model and the network controls that still apply
when TLS is on.

---

## 6. Post-install verification checklist

Work through this list after the driver is installed and the Steam Machine is on.

**Connection (Properties tab):**

- [ ] **Token Status** reads `Stored (encrypted at rest)`.
- [ ] **Network Connection** reads `Online (<ip>:9170, plaintext)`. For TLS, the port is your TLS
      Port and the mode is `TLS encrypt-only` or `TLS pinned`.
- [ ] **System Bridge Connection** reads `Connected and authenticated`.
- [ ] Program or check the `ONLINE` variable. It should be `1`.

**Actions tab:**

- [ ] **Test Connection**: the link comes up or stays up.
- [ ] **Get MAC Address From Steam Machine**: **MAC Address** fills in. Confirm it matches the
      wired NIC.
- [ ] **Send Test Notification**: a `Control4` notification appears on the Steam Machine, and the
      `Notification Sent` event fires.
- [ ] **Launch Big Picture Now**: Big Picture opens on the Steam Machine.

**Power:**

- [ ] Turn the Steam Machine off from a room (with Sleep or Power Off per **Off Mode**). It goes
      to sleep or shuts down.
- [ ] Turn it on from the room. It wakes by Wake-on-LAN and reconnects. The `Came Online` event
      fires.

**Media (optional):**

- [ ] Play something in a browser or Spotify. **NOW_PLAYING** and **MEDIA_STATUS** update, and the
      `Media Started Playing` event fires.

**Games (optional):**

- [ ] Select a game mini-driver in the room's Watch list. The Steam Machine launches the game.
      `Game Launched` fires and **CURRENT_GAME** updates.

**Helpers (optional):**

- [ ] `~/c4pad/c4pad ping` returns `ok pong`.
- [ ] With **Nav Input Backend** = `Gamepad Bridge`, the D-pad moves focus in Big Picture.
- [ ] `systemctl --user status c4pad` and `systemctl --user status c4tls` show `active (running)`.

If a check fails, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 7. Upgrading

1. **Back up the project** in Composer before you change drivers.
2. **Update the parent driver.** Choose **Driver > Add or Update Driver** and select the new
   `steam-machine.c4z`. `auto_update` is `false` in `driver.xml`, so updates are manual.
3. **Update the game mini-drivers.** Each `.c4z` updates separately with the same menu. Mini-drivers
   and the parent are independent.
4. **Check Token Status** after the update. The repo does not document whether the encrypted token
   survives a driver update. If it shows `Not set`, paste the token again.
5. **Re-run the helper installers.** Both are safe to re-run:
   - c4pad: the installer restarts the daemon and replaces its own `c4pad_*` allowlist entries.
     Restart System Bridge afterwards.
   - c4tls: the installer keeps the certificate unless `C4TLS_REGEN=1` is set. A pinned
     certificate therefore stays valid.
6. **Re-verify** with the checklist in [section 6](#6-post-install-verification-checklist).

Release notes for each version are in [RELEASE_NOTES.md](../RELEASE_NOTES.md).

---

## 8. Uninstall and cleanup

Remove the stored token first, then the helpers, then the Composer drivers.

**1. Clear the stored token.** In the Steam Machine driver, run the **Clear Stored Token** action.
**Token Status** should read `Not set`. Do this before you delete the driver. The repo does not
document whether PersistData is removed automatically when a driver is deleted.

**2. Remove the helpers (optional).** The repo has no uninstall script. These commands follow from
the install paths used by the installers.

c4pad:

```bash
systemctl --user disable --now c4pad.service
rm -f ~/.config/systemd/user/c4pad.service
rm -rf ~/c4pad
```

If you added the sudo udev rule, remove it too. The installer may have added these:

```bash
sudo rm -f /etc/udev/rules.d/60-c4pad.rules /etc/atomic-update.conf.d/c4pad-keep.conf
sudo udevadm control --reload-rules
```

c4tls:

```bash
systemctl --user disable --now c4tls.service
rm -f ~/.config/systemd/user/c4tls.service
rm -rf ~/c4tls
```

Removing `~/c4tls` also deletes the TLS private key and certificate. Drivers that pinned the old
certificate will need the TLS mode reset.

**3. Remove the c4pad allowlist entries from System Bridge.** The installer writes `c4pad_*`
entries into `~/.local/share/system-bridge/v5/settings.json`. Remove them and restart System
Bridge. This `jq` filter matches the one the installer uses to replace entries. Keep a backup
first:

```bash
SETTINGS=~/.local/share/system-bridge/v5/settings.json
cp "$SETTINGS" "$SETTINGS.pre-uninstall"
jq '.commands.allowlist = ((.commands.allowlist // []) | map(select(((.id // "") | startswith("c4pad_")) | not)))' \
  "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
```

Then restart System Bridge.

**4. Remove the drivers in Composer.** Delete the Steam Machine driver and each game mini-driver
from the project. Save the project.

**5. Protect old backups.** A project backup taken while a token was stored may still contain
other sensitive data. See [SECURITY.md](../SECURITY.md#credential-at-rest-the-token-is-stored-encrypted-persistdata).

If the token may have been exposed, rotate it (SECURITY.md gives `system-bridge client token`
for this), then paste the new token into the driver.

---

## 9. Related documents

- [README.md](../README.md): project overview and build
- [SECURITY.md](../SECURITY.md): threat model, token handling and network controls
- [RELEASE_NOTES.md](../RELEASE_NOTES.md): beta status and hardware-verify items
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): symptoms, causes and fixes
- [GENERATED_DRIVERS.md](GENERATED_DRIVERS.md): the pre-built game mini-drivers
- [steam-machine/www/documentation.html](../steam-machine/www/documentation.html): the in-driver documentation shown on Composer's Documentation tab
- [steamos-pad/README.md](../steamos-pad/README.md): c4pad details
- [steamos-tls/README.md](../steamos-tls/README.md): c4tls details
