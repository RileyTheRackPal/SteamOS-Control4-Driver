# Security & Privacy

This driver suite controls a Steam Machine through **System Bridge**. Read this
before deploying on an end-user system. It covers the threat model, the
mitigations built into this code, and the deployment steps you must take that
the code cannot enforce for you.

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

## Transport is plaintext — this cannot be fixed in the driver

System Bridge exposes **`ws://` only (no TLS)** and its server **accepts all
origins**; the token travels in cleartext in every WebSocket message. Anyone who
can sniff the LAN segment or reach port 9170 can capture and replay it. We cannot
add TLS to a dependency that does not offer it. You **must** compensate at the
network layer:

- Put the Steam Machine and the Control4 Director on a **dedicated/trusted VLAN**.
- **Firewall port 9170** so only the Director's IP may reach it. **Never
  port-forward 9170** to the internet.
- Prefer **wired Ethernet** for both endpoints over Wi-Fi.
- Rotate the token (`system-bridge client token`) if it may have been exposed.

## Credential at rest: encrypt production builds

A DriverWorks `<password>` property is only masked in Composer — it is **not
encrypted** unless the driver itself is encrypted. The developer `.c4z` built by
`tools/build.ps1` is **unencrypted**, so the pasted System Bridge token is stored
in **cleartext** in the Director project database and in every `.c4bak`/project
backup an integrator copies off-site.

- **Do not install an unencrypted build with a real token on a production system.**
  Produce an **encrypted** release `.c4z` (Snap One DriverPackager with a
  developer signing key, `encryption="2"` on `<script>`) for deployment.
- Never share a project backup that was taken while a real token was configured;
  rotate the token if you do.

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
