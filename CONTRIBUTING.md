# Contributing

Thanks for working on the Control4 Steam Machine driver suite. This guide covers the
developer setup, the repository layout, how each build tool works, the release process, and
the conventions the code already follows. For the architecture see
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). For the threat model read
[SECURITY.md](SECURITY.md) before changing anything that touches tokens, launching, or the
network.

## Dev setup

| Tool | Version | Used for |
|---|---|---|
| PowerShell 7 (`pwsh`) | 7.x | All build and release scripts in `tools/`. They call `pwsh -NoProfile` themselves |
| Windows | 10 or 11 | `tools/make-icons.ps1` and `tools/steam-driver-lib.ps1` load `System.Drawing`, and the script headers mark `make-icons.ps1` as Windows-only |
| Go | 1.21 (from `go.mod`) | `steamos-pad` and `steamos-tls`. `build-c4pad.ps1` and `build-c4tls.ps1` use `C:\Program Files\Go\bin\go.exe` if present, otherwise `go` from `PATH` |
| Lua | 5.x | The driver is Lua. Composer runs it on the Director, so building does not need an interpreter. A standalone Lua interpreter is for the test suite (see [Testing](#testing)) |
| Git | any recent | Source control. `.gitattributes` forces LF line endings for the Linux-bound files |
| Composer Pro | Control4 OS 3.x | Installing and testing the drivers |
| Hardware | a Control4 Director, a Steam Machine or SteamOS PC running System Bridge v5 | Real-device checks. The beta items still to verify are listed in [RELEASE_NOTES.md](RELEASE_NOTES.md) |

The game mini-driver generators make HTTP calls to Steam (see below), so they need internet access.

## Repository layout

| Path | Contents |
|---|---|
| `steam-machine/` | Main driver. `driver.xml` (properties, actions, commands, events, connections), `driver.lua`, `www/documentation.html` and `www/documentation.css` (the Composer Documentation tab), `www/icons/` |
| `steam-machine/drivers-common-public/` | Vendored Snap One libraries, unmodified. See `PROVENANCE.md` |
| `steam-game-miniapp/` | Blank Steam Game mini-driver template. `driver.xml`, `driver.lua`, `www/`, `www/icons/device/` (the template art). The generators overwrite these icons |
| `steamos-pad/` | c4pad Go source (`main.go`, `go.mod`, `go.sum`), `install.sh`, `c4pad.service`, `README.md` |
| `steamos-tls/` | c4tls Go source (`main.go`, `go.mod`, `go.sum` (empty)), `install.sh`, `c4tls.service`, `README.md` |
| `tools/` | PowerShell build, icon, generator and release scripts |
| `docs/` | `ARCHITECTURE.md`, `GENERATED_DRIVERS.md`, `INSTALLATION.md`, `TROUBLESHOOTING.md` |
| `dist/` | Build output (git-ignored) |
| Root docs | `README.md`, `SECURITY.md`, `RELEASE_NOTES.md`, `CONTRIBUTING.md` |

`.gitignore` excludes `dist/`, `*.c4z` and `*.zip`. Do not commit built artifacts.

## Building

All commands run from the repository root. Outputs go to `dist/`.

| Command | Output | Notes |
|---|---|---|
| `pwsh tools/build.ps1` | `dist/steam-machine.c4z`, `dist/steam-game-miniapp.c4z` | Packages every folder with a `driver.xml` (currently those two). Stages a copy, drops excluded files (`.bak`, `~`, `.tmp`, `.log`, `.orig`, `.swp`, `.DS_Store`, `Thumbs.db`, `settings.json`, and files named `token`), then `Compress-Archive` puts `driver.xml` at the zip root. Prints a warning for each excluded file |
| `pwsh tools/build-c4pad.ps1` | `dist/c4pad` | Static linux/amd64 binary: `GOOS=linux GOARCH=amd64 CGO_ENABLED=0`, `-trimpath -ldflags '-s -w' -mod=readonly`. Runs `go mod verify` first, so a mismatch with `go.sum` fails the build |
| `pwsh tools/build-c4tls.ps1` | `dist/c4tls` | Same flags as c4pad. The module is stdlib-only, so `go mod verify` only confirms no dependency was added |
| `pwsh tools/make-game-driver.ps1 -AppId <id>` | `dist/steam-game-<id>.c4z` | One game. Optional `-Name` and `-Style auto\|icon\|logo\|boxart`. Name comes from the Steam store API (`Steam Game <id>` if that fails) |
| `pwsh tools/make-game-drivers.ps1` | `dist/steam-game-<id>.c4z` for each game | Batch. `-Top50` (current most-played chart), `-Valve` (curated Valve list), `-AppIds 620,570`, `-Style`, `-DelayMs` (default 350 ms between games). With no set switch it builds both Top50 and Valve, de-duplicated. Output is listed in [docs/GENERATED_DRIVERS.md](docs/GENERATED_DRIVERS.md) |
| `pwsh tools/make-icons.ps1` | PNG files under `steam-machine/` and `steam-game-miniapp/` | Placeholder icons. Writes `images/icons/device_sm.png` (16 px) and `device_lg.png` (32 px), and `www/icons/device_<size>.png` for 16, 32, 70, 90, 300, 512 and 1024. Main driver uses navy and white, mini template uses green |
| `tools/steam-driver-lib.ps1` | none | Shared library. Dot-sourced by the two generators; do not run it directly |

What the game generators do:

- Icon source, best first: the official square `clienticon` from Steam, then the game
  logo, then a box-art crop. `-Style` forces one source.
- Copies `steam-game-miniapp/` to a staging folder, deletes the template PNGs under
  `www/icons`, and writes `www/icons/device/experience_{70,90,300,512,1024}.png` plus
  `www/icons/device_sm.png` and `device_lg.png`.
- Rewrites that copy's `driver.xml`: name `<Game> (Steam)`, model, version + 1, created and
  modified stamps, the `Game Name` and `Steam App ID or URI` property defaults, and the
  icon paths (`steam-game-miniapp` becomes `steam-game-<id>`).
- Zips the staging folder to `dist/steam-game-<id>.c4z` and deletes the staging folder.

Steam endpoints used by the generators: `store.steampowered.com/api/appdetails` (name),
`api.steamcmd.net/v1/info/<id>` (clienticon hash), `cdn.cloudflare.steamstatic.com` (images),
and `api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/` (Top50).

> **Note:** `make-icons.ps1` writes under `images/icons/`, but `driver.xml` references
> `icons/device_sm.png` and `icons/device_lg.png`, and the tracked tree has no `images/` or
> root `icons/` folder. The generated game drivers use `www/icons/device/...` in the same way,
> while their `driver.xml` points at `icons/device/...`. The shipped beta is built this way, but
> confirm icon resolution on hardware before changing the packaging.

## Release process

`tools/release.ps1` assembles the bundle. Publishing (tag and GitHub release) is manual.

1. **Choose the version.** `release.ps1 -Version` takes it. The default in the script is
   `0.1.0-beta.1`.
2. **Generate the game drivers first.** `release.ps1` does not run `make-game-drivers.ps1`.
   It only copies `dist/steam-game-<digits>.c4z` files that already exist, so run
   `pwsh tools/make-game-drivers.ps1` beforehand.
3. **Run the release script.**

   ```powershell
   pwsh tools/release.ps1 -Version 0.1.0-beta.1
   ```

   The script:
   1. Runs `build-c4pad.ps1`, `build-c4tls.ps1` and `build.ps1`. Their standard output is
      discarded, while errors still print. It then checks that `dist/c4pad`, `dist/c4tls`, `dist/steam-machine.c4z` and
      `dist/steam-game-miniapp.c4z` exist, and fails if any is missing.
   2. Stages `dist/release/Control4-SteamMachine-<version>/` with this layout:

      ```text
      drivers/
        steam-machine.c4z
        steam-game-miniapp.c4z
        games/                    steam-game-<id>.c4z for every generated game
      steamos-helpers/
        steamos-pad/              c4pad, install.sh, c4pad.service, README.md
        steamos-tls/              c4tls, install.sh, c4tls.service, README.md
      docs/
        GENERATED_DRIVERS.md
      README.md
      SECURITY.md
      RELEASE_NOTES.md
      ```

   3. Zips the staged folder to `dist/release/Control4-SteamMachine-<version>.zip` with
      `Compress-Archive`.
   4. Computes the SHA-256 of the zip, prints it, and writes
      `dist/release/Control4-SteamMachine-<version>.zip.sha256` as `<hash>  <zip name>`.

   > **Note:** the child builds run with `| Out-Null` and no exit-code check, so a failed Go
   > build can leave an old binary in `dist/`. Check the build output above the release summary.
   >
   > **Note:** only `README.md`, `SECURITY.md`, `RELEASE_NOTES.md` and `docs/GENERATED_DRIVERS.md`
   > are copied into the bundle. The README's relative links to `docs/INSTALLATION.md`,
   > `docs/TROUBLESHOOTING.md`, `docs/ARCHITECTURE.md` and `CONTRIBUTING.md` will not resolve
   > inside the zip until the script copies those files too.

4. **Check the hash.** Compare `Get-FileHash dist/release/<zip> -Algorithm SHA256` with the
   `.sha256` file.
5. **Tag and publish.** Tag the commit as `v<version>`, push the tag, and create a GitHub release
   from that tag with the zip and its `.sha256`. Mark beta builds as pre-releases. The
   tag and release commands are not in the scripts, for example:

   ```bash
   git tag v0.1.0-beta.1
   git push origin v0.1.0-beta.1
   gh release create v0.1.0-beta.1 --prerelease \
     dist/release/Control4-SteamMachine-0.1.0-beta.1.zip \
     dist/release/Control4-SteamMachine-0.1.0-beta.1.zip.sha256
   ```

   Before tagging, update `RELEASE_NOTES.md`. Its "Beta status" list is the hardware-verify
   checklist.

## Coding conventions

These follow from the existing code and SECURITY.md. Keep them when you change things.

- **`steam://` allowlist.** `LaunchURI` in `steam-machine/driver.lua` is the one gate for
  System Bridge `OPEN`. It accepts only the schemes in `ALLOWED_URI_SCHEMES` (`steam`).
  The mini-app's `UpdateAppData` applies the same check. Adding a scheme such as `https` is a
  deliberate security change. The source comment says to add `https = true` only for documented
  deep-links. Every new launch path must go through `LaunchURI`.
- **Token only in PersistData.** The token lives in encrypted Director PersistData under
  `sb_token`, and the plaintext property is blanked on save. Do not write it to a property,
  a variable, a log line or a file. `OPC.Debug_Mode` turns off WebSocket frame logging
  because every outbound frame carries the token, and `dbg` output must not include it.
- **Sanitize data from System Bridge.** It is untrusted. Use `safeStr` before writing a value
  into a variable, keep the `SBKey` character whitelist, and keep the length caps.
- **No network listener in c4pad.** The daemon accepts commands only on the owner-only Unix
  socket, and the systemd unit is sandboxed. New commands go through the System Bridge
  `COMMAND_EXECUTE` allowlist with fixed argv and no runtime arguments, as SECURITY.md describes.
  Do not add a TCP listener or a shell.
- **Go dependencies.** `steamos-pad` has one pinned dependency (`ThomasT75/uinput`) with a
  committed `go.sum`. Builds run `go mod verify` and `-mod=readonly`. Do not run
  `go mod tidy` as part of a build or release. `steamos-tls` is stdlib-only, so keep it that way.
- **Vendored libraries are unmodified.** Do not edit anything under
  `steam-machine/drivers-common-public/`. Update it by re-fetching the upstream files and
  checking them against [PROVENANCE.md](steam-machine/drivers-common-public/PROVENANCE.md).
- **Naming for Composer callbacks.** Control4 maps a property, action or command name to a Lua
  function by replacing spaces with underscores. A property `Off Mode` needs `OPC.Off_Mode`, a
  command `Get MAC Address` needs `EC.Get_MAC_Address`, and a proxy command needs an `RFP` entry.
  Keep the names in `driver.xml` and `driver.lua` in step.
- **Documentation.** Composer shows `www/documentation.html` on the Documentation tab. Update it
  when you add or rename a property or command, along with the `driver.xml` tooltips.
- **Versions.** The main driver has two version values that no script keeps in step: the
  `DRIVER_VERSION` constant in `steam-machine/driver.lua` (currently `1.0.0`) and `<version>` in
  `steam-machine/driver.xml` (currently `1`). The generators increment `<version>` for each game
  driver. Update both by hand when you release a changed main driver.
- **Line endings and generated files.** Keep LF endings for `*.lua`, `*.go`, `*.xml`, `*.html`,
  `*.sh`, `*.service` and `go.mod`/`go.sum` (see `.gitattributes`). Do not commit `*.c4z`,
  `*.zip` or `dist/`. Never commit a `settings.json` or token file. `build.ps1` excludes them,
  but do not rely on that alone.

## Commit messages

Recent history (`git log --oneline`) uses lowercase conventional prefixes followed by a short
subject:

```text
1e49a37 release: 0.1.0-beta.1
804e344 style: Steam-themed stylesheet for the driver documentation
600c4de docs: fold the programming reference into the driver documentation
7865a5d feat: RGBY navigator buttons -> configurable Steam actions (+ c4pad chords)
9b42353 security: patch audit findings + document System Bridge threat model
b639914 fix: apply c4pad review findings (12 confirmed, all minor)
```

Prefixes in use: `feat:`, `fix:`, `security:`, `docs:`, `style:`, `chore:`, `release:`. Use the
prefix that matches the change, and keep the subject in the imperative mood.

## Testing

Run every suite from the repo root:

```powershell
pwsh tools/test.ps1                   # all suites
pwsh tools/test.ps1 -Suite lua,go     # a subset (lua, powershell, go)
```

The same suites run in GitHub Actions on every push and pull request
(`.github/workflows/test.yml`).

| Suite | Location | Run on its own | What it covers |
|---|---|---|---|
| Lua driver specs | `tests/lua/` | `lua tests/lua/run.lua [name-filter]` | Both drivers loaded into a mocked DriverWorks environment (`c4_mock.lua` records every `C4:` call; a fresh driver per test). Covers property handlers, token storage in PersistData, the `steam://` allowlist, launch queue and power, System Bridge message routing, proxy/EC commands, colored buttons, the mini-app contract, and `driver.xml` ↔ `driver.lua` consistency. Needs Lua 5.4; no LuaRocks packages |
| PowerShell build tools | `tests/powershell/` | `pwsh -NoProfile -File tests/powershell/run.ps1 [-Filter Lib]` | `build.ps1` packaging (zip contents, exclusions), `steam-driver-lib.ps1` with the Steam network calls stubbed, generator parameter validation, `release.ps1` bundle layout + SHA-256, `make-icons.ps1`. Runs in temp "scratch repos", never touches `dist/`. Dependency-free (no Pester). Windows-oriented: `System.Drawing` and `release.ps1` tests skip on Linux |
| Go helpers | `steamos-pad/main_test.go`, `steamos-tls/main_test.go` | `cd steamos-pad && go test ./...` (Linux) | c4pad socket protocol, press/hold/chord/release logic and the hold dead-man, socket-dir permission checks (using a fake gamepad, no `/dev/uinput` needed); c4tls cert generation/reuse/permissions, fingerprints, and the TLS → plaintext proxy |

The Go helpers are `//go:build linux`. On Windows, `tools/test.ps1` cross-compiles static
linux/amd64 test binaries and runs them inside a WSL distro (`-WslDistro`, default
`docker-desktop`, which Docker Desktop installs); with no WSL distro it only vets and compiles them.

Conventions:

- Tests must not need the network, Control4 hardware or a Steam Machine. Stub network calls.
- Don't change production code to make a test pass. If a test exposes a real bug, keep the test
  and mark it skipped with a `BUG:` reason (`pending(...)` in Lua, `-Skip 'BUG: ...'` in
  PowerShell, `t.Skip("BUG: ...")` in Go) until the fix lands, then un-skip it.
- When you add a property, action, command or event to `driver.xml`, the Lua `driver_xml_spec`
  will fail until the matching `OPC.` / `EC.` handler exists (and vice versa).
