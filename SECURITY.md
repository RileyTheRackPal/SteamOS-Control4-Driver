# Security & Privacy

This driver suite controls a Steam Machine through **System Bridge**. Read this
before deploying on an end-user system. It covers the threat model, the
mitigations built into this code, and the deployment steps you must take that
the code cannot enforce for you.

## At a glance

| Exposure | Control | Where |
|---|---|---|
| Token **on the LAN** (cleartext ws://) | c4tls TLS proxy + VLAN/firewall | `steamos-tls/`, network |
| Token **at rest** in Director DB / backups | encrypted PersistData (built in) | this driver |
| Driver **source code** (optional) | `encryption="2"` via DriverPackager (free) | build step |

## The System Bridge token is a full local-user credential

System Bridge authenticates every request with a single UUID **token**. That one
token grants an attacker, per the System Bridge protocol:

- `OPEN` — open arbitrary URIs/paths via `xdg-open` (browser pages, and — absent
  our allowlist — `file://` paths and app/desktop URI handlers that execute)
- `POWER_SHUTDOWN` / `POWER_RESTART` / `POWER_SLEEP`
- Arbitrary **file reads** (`GET_FILES` / `GET_FILE`, REST `GET /api/data`)
- **Keyboard injection**
- `COMMAND_EXECUTE` of allowlisted commands (including our `c4pad_*` entries)

There is no per-capability scoping. **Token disclosure = full remote control of
the machine and its user's data.** Treat it like a password to the PC.

## Transport is plaintext by default — but you can encrypt it

System Bridge exposes **`ws://` only (no TLS)** and its server **accepts all
origins**; by default the token travels in cleartext in every WebSocket message,
so anyone who can sniff the LAN segment or reach port 9170 can capture and replay
it.

**You can encrypt it with the c4tls proxy (recommended).** `steamos-tls/` ships a
tiny TLS-terminating reverse proxy for the Steam Machine: the driver connects
`wss://` to it and it forwards plaintext only to loopback, so the token is
encrypted on the wire. Set the driver's **Connection Security** property to
`TLS encrypt-only` (stops passive sniffing) or `TLS pinned` (also stops active
MITM). See `steamos-tls/README.md`. This is the one control that actually takes
the token off the wire in cleartext.

Whether or not you enable TLS, also compensate at the network layer:

- Put the Steam Machine and the Control4 Director on a **dedicated/trusted VLAN**.
- **Firewall port 9170** (and the TLS port, e.g. 9171) so only the Director's IP
  may reach it. **Never port-forward** them to the internet. A host firewall on
  the Steam Machine or a router/switch ACL both work; the router/switch is more
  durable (survives SteamOS updates, can't be disabled from a compromised box).
  Note a host firewall filters *connections* but not passive *sniffing* of the
  cleartext token — which is exactly what enabling TLS (above) closes.
- Prefer **wired Ethernet** for both endpoints over Wi-Fi.
- Rotate the token (`system-bridge client token`) if it may have been exposed.

## Credential at rest: the token is stored encrypted (PersistData)

A DriverWorks `<password>` property is only **masked in Composer's UI — the value
itself is stored unprotected** in the project, and (per Snap One's docs) driver
encryption does **not** change that: encrypting the driver protects the **Lua
source code**, not persisted property values.

So this driver does **not** keep the token in the password property. On entry it
moves the token into Director's **encrypted PersistData store**
(`C4:PersistSetValue(key, token, true)` — "encrypted in the database") and blanks
the plaintext property. The token is loaded back with `C4:PersistGetValue(key,
true)` at startup. Effect: the plaintext token is not persisted in the project DB
or in a `.c4bak`; the **Token Status** property shows whether an encrypted token
is stored, and the **Clear Stored Token** action removes it.

Honest limits of this control:
- The cryptographic strength of Director's PersistData encryption is not
  documented, and the Director firmware's decryption key has historically been
  extractable. So this defeats **casual** extraction from a shared/stolen project
  backup (the realistic threat — integrators copy `.c4bak` files off-site); it is
  not a guarantee against an attacker with Director-level access to the live
  system.
- Still avoid sharing project backups taken with a real token, and rotate the
  token (`system-bridge client token`) if a backup may have been exposed.
- **Optionally also encrypt the driver** (`encryption="2"` via Snap One's free,
  open-source DriverPackager — **no signing key required**; certification is a
  separate free program) to hide the token-handling code. That is additive IP
  protection, **not** the at-rest control.

## Data privacy

The driver subscribes to System Bridge data modules and copies some fields into
Control4 variables: **uptime, CPU/GPU temperature, CPU/memory usage, battery,
hostname, MAC address, now-playing title/artist**. Implications:

- All of it (plus everything else in the `system` module — usernames, PIDs, IPs,
  machine UUID, camera/mic-usage flags — which System Bridge sends whole and we
  cannot sub-filter) crosses the **cleartext LAN** on every refresh, readable by
  anyone holding the token.
- `HOSTNAME`, `NOW_PLAYING`, and `CURRENT_GAME` are written to Control4 variables
  that **persist in the Director DB and project backups**, creating a longer-lived
  record of usage/viewing habits than the transient traffic. If this is
  unwanted, remove those `C4:AddVariable`/`SetVariable` calls in `driver.lua`.

## What this code does to reduce risk

- **URI scheme allowlist** (`driver.lua` `LaunchURI`, mirrored in the mini-app
  `UpdateAppData`): only `steam://` URIs are sent to `OPEN`; `file://`, `http(s)://`,
  and app-handler URIs are rejected — a malicious/misconfigured game mini-driver
  or programmer cannot open arbitrary local files or handlers.
- **Inbound-data sanitization**: strings from System Bridge are stripped of
  control characters and length-capped before entering Control4 variables.
- **Keyboard tokens** are constrained to a safe charset.
- **c4pad has no network listener** — it is driven only over an owner-only Unix
  socket via System Bridge's `COMMAND_EXECUTE` (fixed argv, no runtime args, no
  shell). It refuses to run unless its runtime dir is owner-private, bounds
  socket reads, caps concurrent connections, and runs under a **sandboxed
  systemd unit** (`NoNewPrivileges`, `ProtectSystem=full`, syscall filter, the
  System Bridge token dir made inaccessible, `/dev/uinput` the only device).
- **Optional TLS transport** (`steamos-tls/c4tls`): encrypts the token on the
  LAN, terminating TLS on the Steam Machine and forwarding only to loopback.
  Stdlib-only static binary, self-signed RSA cert usable as its own pin, also
  sandboxed. See `steamos-tls/README.md`.
- **Supply chain**: the one native dependency (`ThomasT75/uinput`) is version-
  pinned with committed `go.sum`; release builds run `go mod verify` and
  `-mod=readonly` (no network, no silent manifest rewrite). Vendored Lua libs are
  documented in `steam-machine/drivers-common-public/PROVENANCE.md`. Packaging
  excludes stray/secret files.

## Residual risk you accept

- With the Gamepad Bridge installed, a stolen token can drive full game-mode UI
  navigation, including the Steam store — **set a Steam purchase PIN / Family
  settings** if a payment method is saved.
- The token remains readable by any process running as the same session user on
  the Steam Machine; the c4pad sandbox limits the *daemon's* reach but is not a
  substitute for protecting the box itself.
- On multi-user machines, ensure `~/c4pad` and its binary stay owned by the
  session user with no group/world write (the installer checks and refuses
  otherwise). Stock single-user SteamOS is not exposed to this.
