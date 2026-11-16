# Troubleshooting

Symptom-driven fixes for the Control4 Steam Machine driver suite. Each entry gives the likely
cause and the fix. Status strings and debug messages are quoted exactly from `driver.lua`, so you
can search for them in Composer.

Set up with [INSTALLATION.md](INSTALLATION.md) first. Security and network guidance is in
[SECURITY.md](../SECURITY.md).

## Table of contents

1. [Start here: read the status properties](#1-start-here-read-the-status-properties)
2. [How to enable Debug Mode](#2-how-to-enable-debug-mode)
3. [Driver shows offline or cannot connect](#3-driver-shows-offline-or-cannot-connect)
4. [Token problems](#4-token-problems)
5. [Power-on does not work](#5-power-on-does-not-work)
6. [Navigation keys do not work in game mode](#6-navigation-keys-do-not-work-in-game-mode)
7. [Game does not launch](#7-game-does-not-launch)
8. [Media controls do nothing](#8-media-controls-do-nothing)
9. [TLS issues](#9-tls-issues)
10. [Colored buttons do nothing](#10-colored-buttons-do-nothing)
11. [Mini-app tile does not appear in the Watch list](#11-mini-app-tile-does-not-appear-in-the-watch-list)
12. [Reference: status strings](#12-reference-status-strings)
13. [Reference: Debug Mode messages](#13-reference-debug-mode-messages)

---

## 1. Start here: read the status properties

Most problems show up in the read-only properties on the Steam Machine driver's Properties tab.
Check these first:

| Property | Healthy value | If you see otherwise |
|---|---|---|
| Network Connection | `Online (<ip>:9170, plaintext)` or `Online (<ip>:<tls port>, TLS ...)` | See [section 3](#3-driver-shows-offline-or-cannot-connect). |
| System Bridge Connection | `Connected and authenticated` | `Invalid token` or `No token set` means a token problem. See [section 4](#4-token-problems). |
| Token Status | `Stored (encrypted at rest)` | `Not set` means no token is stored. |
| Director Connection | `Connected (driver v1.0.0 running)` | This only shows that the driver started. It does not test the Steam Machine. |

**Note:** `Director Connection` reads `driver v1.0.0` in the code, but the release is
`0.1.0-beta.1`. This is a version-string mismatch in the source. It does not indicate a fault.

---

## 2. How to enable Debug Mode

1. In Composer Pro, select the **Steam Machine (System Bridge)** driver.
2. On the **Properties** tab, set **Debug Mode** to `Print`. The default is `Off`.
3. Reproduce the problem.
4. Read the Lua output for the driver (see the Note below).
5. Set **Debug Mode** back to `Off` when you finish. Debug output adds timestamped lines to the log.

What Debug Mode does, from `driver.lua` and the vendored libraries:

- It turns on the driver's `dbg()` messages. Each one has a timestamp and is also sent to
  `C4:DebugLog`.
- It never logs WebSocket frames. The driver forces `DEBUG_WEBSOCKET` off because every outbound
  frame contains the token. Keep it that way when you share logs.
- Some messages print whether Debug Mode is on or not. Those are listed in [section 13](#13-reference-debug-mode-messages).

**Note:** The repo does not say where Composer shows Lua `print()` output, or where `C4:DebugLog`
output goes. Look in Composer's Lua or driver output pane for your version, and in the Director's
debug log if you have access to it. Confirm the location on your system.

**Before you share a log:** check it for anything that looks like a token or a certificate private
key. The driver is built not to log the token, but review the log anyway.

---

## 3. Driver shows offline or cannot connect

### 3.1 Network Connection status meanings

| Status shown | Meaning | Fix |
|---|---|---|
| `No address entered - set the IP in Connections > Network` | The Network binding (6001) is empty. | Enter the Steam Machine's IP in **Connections > Network**. |
| `Error: invalid WebSocket URL provided:...` | The WebSocket URL could not be built, usually from a bad address. | Check the IP in **Connections > Network**. |
| `Connecting to <ip> (<mode>)...` and it never changes | The TCP connection never completes. | See the causes below. |
| `Offline (Offline)` | The connection dropped. The driver retries. | Usually the Steam Machine is asleep or System Bridge stopped. |
| `Offline (Closed by remote)` | The Steam Machine closed the connection. | Check System Bridge on the Steam Machine. |
| `Online (<ip>:9170, plaintext)` but **System Bridge Connection** is not `Connected and authenticated` | The socket is open, but no successful response has arrived yet. | Check the token. See [section 4](#4-token-problems). |

**Note:** The `Offline (Offline)` text is what the code produces. It is not a typo in this guide.

### 3.2 Causes and fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| Stuck on `Connecting to ...` | Wrong IP, or port `9170` not reachable from the Director. | Confirm the IP with `ip addr` on the Steam Machine and check the reserved DHCP entry. Confirm the Director can reach the Steam Machine on `9170`, through the same VLAN or a router/switch ACL that allows it. Never port-forward it. |
| Stuck on `Connecting to ...` with TLS selected | c4tls not running, or TLS Port wrong. | See [section 9](#9-tls-issues). |
| Was working, now `Offline (Offline)` | Steam Machine asleep, powered off, or System Bridge stopped. The driver retries with a back-off that starts at 5 s and doubles to a 60 s cap. | Wake the Steam Machine with **Power On** (Wake-on-LAN). Check that System Bridge is running. |
| Connected, then offline with no traffic | No System Bridge traffic for 180 s triggers a forced reconnect. | Usually self-healing. If it repeats, check the Steam Machine's network and System Bridge. |
| System Bridge not running on the Steam Machine | Service not started or it stopped. | Start System Bridge. Confirm it starts automatically (see [INSTALLATION.md section 2](INSTALLATION.md#2-install-system-bridge-on-steamos)). |
| Director blocked by firewall or VLAN | Firewall or ACL is blocking port `9170` (or the TLS port). | Allow the Director's IP to reach the Steam Machine on the port in use. See [SECURITY.md](../SECURITY.md#transport-is-plaintext-by-default--but-you-can-encrypt-it). |
| Changed IP address | DHCP lease changed and the Network binding is stale. | Reserve the IP in DHCP. Update **Connections > Network**. The driver re-reads it on binding change. |
| Works from a laptop, not the Director | Director is on a different subnet, or an ACL blocks it. | Check the route and ACL from the Director's network. |

**Note:** The repo does not document the Director's network behaviour, so the VLAN and ACL
guidance above is general. Check it against your network.

### 3.3 Retry behaviour, for reference

- Reconnect back-off starts at **5 s** and doubles to a **60 s** cap.
- **Test Connection** (Actions tab) resets the back-off to 5 s and reconnects immediately.
- Changing **Connection Security**, **TLS Port** (in a TLS mode) or **Server Certificate** (in a TLS
  mode) tears the socket down and reconnects.

---

## 4. Token problems

| Symptom | Status text | Cause | Fix |
|---|---|---|---|
| Rejected token | **System Bridge Connection** shows `Invalid token - check the System Bridge Token property` | System Bridge returned `BAD_TOKEN` or `MISSING_TOKEN`. The token is wrong or was rotated. | Run `system-bridge client token` on the Steam Machine. Paste the current token into **System Bridge Token**. |
| No token | `No token set - paste the System Bridge token` | No token is stored. This also appears when a command is sent with no token. | Paste the token. Check **Token Status**. |
| Pasted, but the field is empty | (none) | Expected. The token is stored encrypted and the plaintext field is cleared. | Check **Token Status** shows `Stored (encrypted at rest)`. |
| Token Status reads `Not set` after an update | `Not set` | The stored token did not carry over, or was cleared. | The repo does not document whether the encrypted token survives a driver update. Paste the token again. |
| Token leaked or rotated | (none) | The token is a full local-user credential. | Rotate it (SECURITY.md gives `system-bridge client token`), then paste the new token. See [SECURITY.md](../SECURITY.md#the-system-bridge-token-is-a-full-local-user-credential). |

**Note:** A pasted value replaces the stored token. An empty field does not clear it. To remove the
token, run **Clear Stored Token**. The repo does not say whether System Bridge must be restarted
after you rotate its token.

---

## 5. Power-on does not work

Power on is the **Power On** command, or a room turning the device on. It sends Wake-on-LAN (WoL)
packets to the stored MAC address at 0 s, 2 s and 5 s, then reconnects.

| Symptom | Likely cause | Fix |
|---|---|---|
| Nothing happens, no WoL | **MAC Address** is blank. The driver sends **no** WoL packet without a MAC. | Run **Get MAC Address From Steam Machine** while the machine is online, or type the MAC. The machine must be online for the auto-fetch. The `Turned On` event still fires, so do not treat it as proof that WoL was sent. |
| **Get MAC Address From Steam Machine** says `Cannot fetch MAC - Steam Machine is offline` | The machine is off or unreachable, so the auto-fetch is not possible. | Enter the MAC by hand. Get it from the Steam Machine's wired NIC. |
| MAC looks wrong | The driver normalizes any 12 hex digits to `AA:BB:CC:DD:EE:FF`. A malformed entry is cleared. | Re-enter the MAC. Make sure it is the wired NIC's MAC, not Wi-Fi. |
| WoL works sometimes | Wi-Fi is in use, or firmware does not keep WoL armed in the power state you use. The repo does not document this. | Use wired Ethernet. Check the Steam Machine's BIOS/firmware for Wake-on-LAN. The repo does not name these menus. |
| Machine powered off fully, does not wake | Depends on firmware and NIC power state. Not documented in the repo. | Use **Sleep** (Off Mode) for the fastest resume. Check Wake-on-LAN for the power state you use. |
| Power On works, but Big Picture does not open | **Launch Into Big Picture** is `Off`, or a game launched within the last 15 s. | Set **Launch Into Big Picture** to `On`. The 15 s guard is intentional: it stops a Big Picture launch from replacing a game just started. |
| Power Off does nothing | **Off Mode** is `Do Nothing`. | Set **Off Mode** to `Sleep` or `Power Off`. |
| Machine turns off a few seconds late | Room Off is deferred by **5 s**. | Expected. A source switch or power-on within that window cancels it. |

**Note:** WoL is only as reliable as the Steam Machine's firmware and network. The repo does not
verify WoL on hardware, and the beta notes list it as unverified.

---

## 6. Navigation keys do not work in game mode

Navigation keys work differently with each **Nav Input Backend**.

| Backend | Works in | Does not work in |
|---|---|---|
| `Keyboard` (default) | Desktop Mode. Uses System Bridge key injection. | Big Picture and games. The SteamOS game session (gamescope) may ignore injected keys. |
| `Gamepad Bridge` | Big Picture, the Steam UI and games, through a virtual Xbox 360 controller. | Needs the c4pad helper installed and System Bridge restarted. |

### 6.1 Causes and fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| D-pad works in Desktop Mode, not in Big Picture | Backend is `Keyboard`. | Install c4pad, then set **Nav Input Backend** to `Gamepad Bridge`. See [INSTALLATION.md section 5.1](INSTALLATION.md#51-c4pad-gamepad-bridge). |
| Gamepad Bridge set, still nothing | c4pad not installed, daemon not running, or the allowlist is missing. | Run `~/c4pad/c4pad ping`. Expect `ok pong`. If not, run `systemctl --user status c4pad`. Confirm the `c4pad_*` entries are in System Bridge's `settings.json`. Restart System Bridge. |
| Gamepad Bridge set, input goes to the keyboard path instead | System Bridge does not know the `c4pad_*` command. The driver logs `c4pad allowlist entry missing for <cmd> - falling back`. | Re-run `install.sh`, then restart System Bridge. The driver's fallback turns held directions into single presses, and sends other commands through the keyboard path. |
| `c4pad command failed (exit N)` in Debug Mode | The c4pad daemon is not running, or the command exited non-zero. | Run `systemctl --user status c4pad`. Run `~/c4pad/c4pad ping` manually. |
| `COMMAND_NOT_FOUND` for c4pad, Flatpak System Bridge | The Flatpak sandbox can block System Bridge from spawning `~/c4pad/c4pad`. | Use a native System Bridge binary or user service. See [steamos-pad/README.md](../steamos-pad/README.md). |
| Gamepad Bridge set, no input, `/dev/uinput` error in the installer output | The user has no access to `/dev/uinput`. | Run the installer's sudo udev fallback (printed by `install.sh`). Read it before you run it. |
| Chords do nothing, navigation works | Steam controller configuration is off. | In Steam game mode, *Settings > Controller > Xbox/generic configuration support* must be on, and the default Steam Button Chord layout must be in use (c4pad README). |
| D-pad keeps moving after release | A held direction is stuck. | c4pad releases a held button after a 5 s dead-man timer. The driver refreshes active holds every 2 s. If it still sticks, restart the c4pad service with `systemctl --user restart c4pad`. |
| Menu key opens Big Picture on Keyboard, but does Start on Gamepad Bridge | Expected. The mapping differs by backend. | Keyboard: Menu/Home -> Big Picture. Gamepad Bridge: Menu -> Start, Guide -> Steam button. |
| Guide opens the Steam library on Keyboard, Steam button on Gamepad Bridge | Expected. | See the same mapping above. |

**Note:** The main README says *Guide -> Steam library* without noting the backend difference. The
code behaves as described above.

**Note:** The c4pad README lists the X and Y button labels as a hardware-verify item. If X and Y
look swapped in Steam's controller tester, that is a known open point, not a misconfiguration.

---

## 7. Game does not launch

A game launch sends `steam://` URIs through System Bridge's `OPEN` command. The driver accepts
**only `steam://` URIs**.

### 7.1 Rejections

| Symptom | Where it shows | Cause | Fix |
|---|---|---|---|
| Mini-driver **Launch URI** reads `Rejected: only a numeric App ID or a steam:// URI is allowed` | Mini-driver Properties | The **Steam App ID or URI** value is neither a numeric App ID nor a well-formed `steam://` URI. | Enter a numeric App ID (for example `620`), or a full `steam://` URI. |
| Launch silently does nothing; Debug Mode shows `LaunchURI rejected non-allowlisted URI: <uri>` | Debug Mode output | The URI scheme is not `steam`. The driver refuses `file://`, `http(s)://` and handler URIs by design. | Use a `steam://` URI. See [SECURITY.md](../SECURITY.md#what-this-code-does-to-reduce-risk). |
| Mini-driver **Launch URI** is blank | Mini-driver Properties | The App ID is blank. | Set **Steam App ID or URI**. |

### 7.2 Machine asleep or off

When the Steam Machine is offline, a launch is **queued** and the driver sends Wake-on-LAN. The
launch fires once System Bridge reconnects and authenticates.

| Off Mode | Queue window |
|---|---|
| `Power Off` | **300 s** (5 minutes) |
| `Sleep` or `Do Nothing` | **120 s** |

When the window expires, the queued launch is dropped without a message. Other causes also drop it:
a room **Off** command clears the queue.

| Symptom | Cause | Fix |
|---|---|---|
| Launch never happens, machine comes up late, **Off Mode** = `Power Off` | A cold boot took longer than the 300 s window, so the queued launch was dropped. | Use **Off Mode** = `Sleep`, which resumes in seconds. The main README and in-driver docs recommend it. |
| Launch never happens, **Off Mode** = `Sleep` | The machine took longer than the 120 s window to reconnect, or WoL failed. | Fix WoL first (see [section 5](#5-power-on-does-not-work)). Then check how long the machine takes to reconnect. |
| Launch never happens, MAC is blank | The driver sends no WoL packet without a MAC. | Set **MAC Address**. See [section 5](#5-power-on-does-not-work). |

### 7.3 Launch sent but the game does not start

| Symptom | Likely cause | Fix |
|---|---|---|
| **Game Launched** event does not fire | The driver fires it only after System Bridge replies `OPENED` for a `steam://` URI. No reply means the request did not get through. | Check the connection. Turn on Debug Mode and look for `SBSend skipped (not connected): OPEN`. |
| `Game Launched` fires, but nothing starts | Steam itself did not start the game. The repo does not document Steam's behaviour for every App ID. | Test the URI on the Steam Machine: `steam://rungameid/<appid>`. Check that the game is installed and the Steam client is logged in. |
| Big Picture opens instead of the game, or the game never starts after a room power-on | With **Launch Into Big Picture** = `On`, a room power-on while offline queues Big Picture. That queue entry replaces any game launch already queued. See the Note below. | Send the room power-on first, then select the game. Or set **Launch Into Big Picture** to `Off`. |

**Note (code behaviour, not documented in the in-driver docs):** `driver.lua` keeps one pending
launch slot. If a game launch is queued while the machine is offline, and then a room power-on
arrives with **Launch Into Big Picture** = `On`, the Big Picture queue overwrites the game. Confirm
this on your hardware before you rely on the order.

---

## 8. Media controls do nothing

Media transport keys and the **Media** commands go to System Bridge's **MEDIA_CONTROL** command.
This uses **MPRIS** through `playerctl`. It controls **media players**, not games.

| Symptom | Likely cause | Fix |
|---|---|---|
| Play/Pause does nothing with a game running | Expected. Media control reaches MPRIS players only. | Use a media player (browser, Spotify, and so on). Games are not controlled. |
| Nothing happens at all | `playerctl` missing on the Steam Machine. | Install `playerctl`. It is bundled in most desktop installs. |
| Nothing happens, no active media | No MPRIS player is running. | Start a media player first. |
| **NOW_PLAYING** or **MEDIA_STATUS** stays empty | No media player is active, or System Bridge has not sent the `media` module yet. | Start playback. Check that the driver has a connection. |
| `Media Started Playing` event never fires | The event fires only when the status changes, and it reads the `media` module. | Start and pause playback in a player. Check the status changes. |
| Volume goes to zero and stays there | **Media Mute** is one-way. It sets the MPRIS player volume to 0. | Press **Media Volume Up**. Each press raises the player volume by 5%, so repeat it to reach a comfortable level. |
| Volume buttons change the browser volume, not the game or system volume | Expected. Volume controls act on the active MPRIS player only. | Use the Steam Machine's own volume for system or game audio. The repo does not cover that path. |
| Media commands ignored while offline | Commands are not queued. | Confirm the connection with the status properties. Turn on Debug Mode and look for `SBSend skipped (not connected): MEDIA_CONTROL`. |

---

## 9. TLS issues

TLS uses the c4tls proxy on the Steam Machine. See [INSTALLATION.md section 5.2](INSTALLATION.md#52-c4tls-tls-proxy).

### 9.1 Reading the TLS status

The **Network Connection** status includes the mode actually in use:

| Status text | Meaning |
|---|---|
| `Online (<ip>:9171, TLS pinned)` | Pinned mode is working. The server is checked against the pasted certificate. |
| `Online (<ip>:9171, TLS encrypt-only)` | Encrypt-only mode. Traffic is encrypted but the server is not verified. |
| `Online (<ip>:9171, TLS encrypt-only (PINNED SELECTED BUT NO CERTIFICATE - not MITM-protected))` | Pinned mode is selected but **no** certificate is set. The driver fell back to encrypt-only. **There is no MITM protection.** |
| `Online (<ip>:9170, plaintext)` | Plaintext. The token is in cleartext. |

### 9.2 Causes and fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| Stuck on `Connecting to ...` in a TLS mode | c4tls not running. | On the Steam Machine: `systemctl --user status c4tls`. Restart with `systemctl --user restart c4tls`. |
| Stuck on `Connecting to ...` in a TLS mode | **TLS Port** does not match c4tls's listen port. | Default is `9171`. If you used `C4TLS_PORT`, set **TLS Port** to the same value. The unit runs `-listen :<port>`. |
| Stuck on `Connecting to ...` in a TLS mode | Firewall blocks the TLS port. | Allow the Director's IP to reach the TLS port. |
| Connects, then goes offline, in a TLS mode | Likely System Bridge is not running on loopback. c4tls forwards only to `127.0.0.1:9170` (inferred from the c4tls design; not tested). | Start System Bridge. Check `systemctl --user status c4tls` too. |
| Pinned mode will not connect | The Director may not accept the self-signed certificate. This is a hardware-verify item. | Switch **Connection Security** to `TLS encrypt-only (wss://)`. It needs no certificate and still encrypts the token. |
| Pinned mode will not connect, certificate looks valid | **Server Certificate** is malformed. | Paste the single base64 line the installer printed, or the full PEM. Turn on Debug Mode and look for `Server Certificate is not a valid PEM or base64-encoded PEM`. |
| Pinned selected, status says `PINNED SELECTED BUT NO CERTIFICATE` | **Server Certificate** is blank. The driver fell back to encrypt-only. | Paste the certificate, or accept encrypt-only knowingly. Debug Mode logs `TLS pinned selected but no certificate set; using encrypt-only until a cert is pasted`. |
| Works on modern firmware, fails on old firmware | c4tls defaults to a TLS 1.2 minimum. Older controller firmware may not negotiate it. | In `~/.config/systemd/user/c4tls.service`, add `-min-tls 1.1` (or `1.0`) to `ExecStart`. Run `systemctl --user daemon-reload` and `systemctl --user restart c4tls`. |
| Stopped working after the Steam Machine's IP changed | The certificate's SAN holds the LAN IP from install time. | Reserve the IP. If it changed, regenerate with `C4TLS_SAN_IP=<new-ip>` and `C4TLS_REGEN=1`, then paste the new certificate. The repo does not confirm whether the Director checks the SAN. |
| Certificate rotated, pinned mode stopped working | A pasted pin is only valid for the certificate it came from. | Paste the new certificate into **Server Certificate**. |
| Installer says to verify the fingerprint "matches what the driver reports" | The repo's driver code does not report a fingerprint in its status properties. | Compare the installer's SHA-256 with the output of `c4tls -print-cert -certdir ~/c4tls`. |

**Note:** Re-running `install.sh` keeps the existing certificate. Only `C4TLS_REGEN=1` rotates it.

---

## 10. Colored buttons do nothing

The navigator's colored buttons are **physical programmable buttons**. Control4 does not route
them to the driver by itself. You must program each button to its command (`Red Button`, `Green
Button`, `Yellow Button`, `Blue Button`) in Composer.

| Symptom | Likely cause | Fix |
|---|---|---|
| Button does nothing | The navigator button is not programmed to the command. | In Composer, program the button to the matching command. |
| Button does nothing, and the action is `None` | The action property is `None`. | Set **Red/Green/Yellow/Blue Button Action** to an action. |
| Button does nothing, action is a chord | c4pad not installed, or Steam controller configuration is off. | Install c4pad. Check *Settings > Controller > Xbox/generic configuration support* in Steam game mode. See [section 5.1 of INSTALLATION.md](INSTALLATION.md#51-c4pad-gamepad-bridge). |
| `Steam Menu` does nothing | The driver sends `c4pad_steam`, which needs c4pad. The in-driver docs say it does not. | Install c4pad. Treat `Steam Menu` as needing c4pad until tested. |
| `Launch Big Picture` or `Media Play/Pause` does nothing | Those go through System Bridge directly. | Check the connection first. See [section 3](#3-driver-shows-offline-or-cannot-connect). |
| Action is `Fire Programming Event`, but no program reacts | The event fires, but nothing in Composer programming listens for it. | Bind a Programming action to the `Red/Green/Yellow/Blue Button Pressed` event. |
| Chord fires the wrong function | The Steam button chord layout has been changed. | Restore the default Steam Button Chord layout, or edit the `c4pad_*` allowlist entries to match. |
| X/Y labels look wrong | Known hardware-verify item in c4pad. | Check Steam's controller tester. |

---

## 11. Mini-app tile does not appear in the Watch list

Each game is a **Steam Game (Mini App)** driver bound to a **Game App N** input on the Steam
Machine driver. See [INSTALLATION.md section 4](INSTALLATION.md#4-game-mini-drivers).

| Symptom | Likely cause | Fix |
|---|---|---|
| Tile does not appear | The mini-driver's **Steam Game** output is not bound to a **Game App N** input. | In **Connections**, bind **Steam Game** (`RF_MINI_APP`) to a free **Game App** input on the Steam Machine driver (inputs 1 to 25). |
| Tile appears, but selecting it does nothing | The mini-driver's **Steam App ID or URI** is blank or invalid. | Check **Launch URI**. It should show a `steam://` URI. |
| Tile shows, but `Rejected: only a numeric App ID or a steam:// URI is allowed` | The App ID or URI is malformed. | Enter a numeric App ID, or a full `steam://` URI. |
| Launch goes to the wrong game | Two mini-drivers have the same App ID, or the wrong input is bound. | Check each mini-driver's **Launch URI** and its bound input. |
| Debug Mode shows `Mini app on input <n> has no UM_STEAM_MACHINE variable set` | The mini-driver has not published its URI to the parent. The mini publishes it at startup and on property changes. | Check the mini-driver's **Launch URI** shows a value. Set **Steam App ID or URI** if it is blank. |
| Tile name is `Steam Game` | **Game Name** is blank. The driver uses `Steam Game` as a default. | Set **Game Name**. |
| Tile is intermittently missing | Not documented in the repo. Mini-driver registration depends on Composer and room bindings. | Re-check the bindings. The beta notes list the mini-app AV routing as hardware-verify. |

**Note:** The repo does not describe exactly how the Watch list orders or filters tiles, so check
these on your hardware.

---

## 12. Reference: status strings

These are exact strings the driver sets in its properties.

| Property | Strings |
|---|---|
| Network Connection | `No address entered - set the IP in Connections > Network`; `Error: <message>`; `Connecting to <ip> (<connection security>)...`; `Online (<ip>:<port>, <mode>)`; `Offline (<reason>)` |
| Network Connection (`<mode>`) | `plaintext`; `TLS encrypt-only`; `TLS pinned`; `TLS encrypt-only (PINNED SELECTED BUT NO CERTIFICATE - not MITM-protected)` |
| Network Connection (`<reason>`) | `Offline`; `Closed by remote` |
| System Bridge Connection | `Not connected`; `Connected and authenticated`; `Invalid token - check the System Bridge Token property`; `No token set - paste the System Bridge token`; `Cannot fetch MAC - Steam Machine is offline` |
| Token Status | `Not set`; `Stored (encrypted at rest)` |
| Director Connection | `Connected (driver v<version> running)` |
| Mini-driver Launch URI | `Rejected: only a numeric App ID or a steam:// URI is allowed` |

---

## 13. Reference: Debug Mode messages

Messages from `dbg()` appear only when **Debug Mode** is `Print`.

| Message | Meaning |
|---|---|
| `SBSend skipped (not connected): <event>` | A command was dropped because the socket is not up. |
| `System Bridge error: <message> (<subtype>)` | System Bridge returned an error. |
| `Undecodable message from System Bridge` | A frame could not be parsed. |
| `c4pad command failed (exit <n>) for <cmd> - is the c4pad daemon running on the Steam Machine?` | A c4pad command exited non-zero. |
| `c4pad allowlist entry missing for <cmd> - falling back` | System Bridge returned `COMMAND_NOT_FOUND` for a `c4pad_*` command. |
| `LaunchURI rejected non-allowlisted URI: <uri>` | A non-`steam://` URI was refused. |
| `Unhandled proxy command: <cmd>` | A navigator command the driver does not map. |
| `Unhandled switcher command: <cmd>` | An unmapped command on the Steam App Switcher. |
| `Mini app on input <n> has no UM_STEAM_MACHINE variable set` | A **Game App** input has no URI. |
| `SBKey rejected key token: <key>` | A keyboard token did not match the allowed shape. |
| `Unknown Steam action: <name>` | A colored button or action name is not recognised. |
| `No System Bridge traffic for 180s - reconnecting` | The stale-connection watchdog fired. |
| `TLS pinned selected but no certificate set; using encrypt-only until a cert is pasted` | Pinned mode fell back to encrypt-only. |
| `Server Certificate is not a valid PEM or base64-encoded PEM` | The pasted certificate did not parse. |

**Messages printed regardless of Debug Mode.** These come from the vendored WebSocket library, which
uses `print()` directly. They appear in the Lua output even when **Debug Mode** is `Off`:

| Message | Meaning |
|---|---|
| `Starting Web Socket... Opening net connection to <url>` | A connection attempt started. The URL has no token. |
| `WS <url> connected` | The WebSocket is open. |
| `WS <url> disconnected while running` | The socket dropped while active. |
| `WS <url> disconnected while not running` | The socket dropped while stopped. |
| `C4 network connection not setup` | The network binding could not be set up. |
| `Websocket callback <...> error` | A driver callback raised an error. |

**What a healthy connection looks like in the log:**

```
Starting Web Socket... Opening net connection to ws://<ip>:9170/api/websocket
WS ws://<ip>:9170/api/websocket connected
```

For a TLS mode, the URL is `wss://<ip>:<tls port>/api/websocket`.

**Note:** The vendored library's frame-level debug output is always off, by design. It would log
the token. Do not turn it on.

---

## Related documents

- [INSTALLATION.md](INSTALLATION.md): install, configure and verify
- [SECURITY.md](../SECURITY.md): threat model, token handling and network controls
- [RELEASE_NOTES.md](../RELEASE_NOTES.md): beta status and hardware-verify items
- [steamos-pad/README.md](../steamos-pad/README.md): c4pad details and tests
- [steamos-tls/README.md](../steamos-tls/README.md): c4tls details and modes
- [steam-machine/www/documentation.html](../steam-machine/www/documentation.html): in-driver reference
