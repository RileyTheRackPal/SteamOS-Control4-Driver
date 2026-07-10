# Vendored third-party Lua libraries — provenance

These files are shipped verbatim inside the `.c4z` so the driver has no runtime
download dependency. They are **unmodified** copies of upstream. To re-verify,
diff against the upstream raw files.

| File | Upstream | Source URL |
|---|---|---|
| `global/handlers.lua` | Snap One `drivers-common-public` (`COMMON_HANDLERS_VER = 17`) | https://raw.githubusercontent.com/control4/drivers-common-public/master/global/handlers.lua |
| `global/timer.lua` | Snap One `drivers-common-public` (`COMMON_TIMER_VER = 10`) | https://raw.githubusercontent.com/control4/drivers-common-public/master/global/timer.lua |
| `global/lib.lua` | Snap One `drivers-common-public` | https://raw.githubusercontent.com/control4/drivers-common-public/master/global/lib.lua |
| `module/websocket.lua` | Snap One `drivers-common-public` (`COMMON_WEBSOCKET_VER = 7`) | https://raw.githubusercontent.com/control4/drivers-common-public/master/module/websocket.lua |
| `module/metrics.lua` | Snap One `drivers-common-public` | https://raw.githubusercontent.com/control4/drivers-common-public/master/module/metrics.lua |
| `module/json.lua` | Jeffrey Friedl's JSON (shipped by Snap One `drivers-common-public`) | https://raw.githubusercontent.com/control4/drivers-common-public/master/module/json.lua |

Fetched 2026-07-08 from the `control4/drivers-common-public` repository (MIT/Snap One licensed).
Re-verify integrity by re-downloading each URL and comparing (e.g. `git diff` after
a fresh fetch); the version constants above are grep-able sanity checks.
