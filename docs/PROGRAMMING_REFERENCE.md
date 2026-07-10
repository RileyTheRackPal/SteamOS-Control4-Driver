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
| Red / Green / Yellow / Blue Button Pressed | the matching colored-button command runs while its action is set to **Fire Programming Event** (for fully custom programming) |

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
| Red / Green / Yellow / Blue Button | — (runs that color's configured action — see below) |
| Steam Menu | — (Guide button) |
| Quick Access Menu | — (Steam+A; needs c4pad) |
| Toggle On-Screen Keyboard | — (Steam+X; needs c4pad) |
| Screenshot | — (Steam+R1; needs c4pad) |
| Toggle Magnifier | — (Steam+L1; needs c4pad) |
| Force Quit Game | — (Steam+B held; needs c4pad) |

## Colored (RGBY) navigator buttons

Control4's colored remote/touchscreen buttons are **physical programmable buttons** — Control4
does not auto-route them to the driver. To use them: in Composer, **program the navigator's
red/green/yellow/blue button to execute the matching command** on the Steam Machine
(`Red Button`, `Green Button`, …).

Each colored button's behavior is chosen by a **property dropdown** (System Design →
`Red/Green/Yellow/Blue Button Action`) from: None, Steam Menu, Quick Access Menu, Toggle
On-Screen Keyboard, Screenshot, Toggle Magnifier, Force Quit Game, Launch Big Picture, Media
Play/Pause, or **Fire Programming Event** (which fires the matching event above so you can bind
*any* Control4 programming). The chord actions (keyboard/quick-access/screenshot/magnifier/
force-quit) require the c4pad Gamepad Bridge; Steam Menu / Big Picture / Play-Pause do not.

The individual Steam actions are also exposed as standalone commands (Steam Menu, Quick Access
Menu, …), so you can bind them to any navigator button or scene directly, not just the four colors.

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
