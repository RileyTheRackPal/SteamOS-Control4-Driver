# Programming reference — Steam Machine (System Bridge) driver

What the main driver exposes in Composer's **Programming** view, plus the **Actions**
tab (which is separate from Programming).

## Events — "When the Steam Machine …"

| Event | Fires when |
|---|---|
| Came Online | System Bridge connects (reachable + authenticated) |
| Went Offline | System Bridge connection is lost |
| Turned On | the device is selected / turned on in a room |
| Turned Off | a room turns the device off |
| Game Launched | a game or `steam://` URI is launched |
| Notification Sent | Control4 successfully delivers a notification to it |
| Media Started Playing | media begins playing (MPRIS) |
| Media Paused | media is paused |
| Media Stopped | media stops |

## Device commands — things you can make it do in a script

| Command | Parameters |
|---|---|
| Power On | — (Wake-on-LAN) |
| Power Off | — (obeys the Off Mode property) |
| Sleep / Shut Down / Restart / Lock | — |
| Launch Big Picture | — |
| Launch Steam Game | App ID |
| Open URI | URI (`steam://` only, enforced) |
| Send Notification | Title, Message |
| Media Play Pause / Next / Previous / Stop | — |
| Media Volume Up / Down / Mute | — (MPRIS player volume; Mute is one-way) |
| Send Keyboard Key | Key (Desktop Mode; may not reach the game session) |
| Press Gamepad Button | Button (needs the c4pad Gamepad Bridge) |

## Variables — for conditionals and values

| Variable | Type | Meaning |
|---|---|---|
| ONLINE | BOOL | System Bridge connected |
| UPTIME_SECONDS | NUMBER | uptime in seconds |
| UPTIME_TEXT | STRING | uptime formatted (e.g. `2d 3h 10m`) |
| HOSTNAME | STRING | machine hostname |
| CPU_TEMPERATURE | NUMBER | °C |
| GPU_TEMPERATURE | NUMBER | °C (hottest GPU) |
| CPU_USAGE | NUMBER | % |
| MEMORY_USED_PERCENT | NUMBER | % |
| BATTERY_PERCENT | NUMBER | % (null-ish on a desktop) |
| NOW_PLAYING | STRING | current media title – artist |
| MEDIA_STATUS | STRING | PLAYING / PAUSED / STOPPED |
| CURRENT_GAME | STRING | last launched game name / URI |

## Actions tab (one-click buttons — not Programming)

Get MAC Address From Steam Machine · Test Connection · Send Test Notification ·
Launch Big Picture Now · Clear Stored Token.
