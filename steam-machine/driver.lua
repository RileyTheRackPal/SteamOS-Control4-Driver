--[[
	Steam Machine (System Bridge) - Control4 DriverWorks driver

	Controls a Steam Machine / SteamOS PC (or any desktop running System Bridge v5)
	over the System Bridge WebSocket API (ws://<ip>:9170/api/websocket).

	- Power on via Wake-on-LAN, power off via System Bridge (Sleep / Shut Down, per property)
	- Navigator transport & nav keys mapped to System Bridge media control / keyboard injection
	- Optional launch into Steam Big Picture on room-on
	- Hosts up to 25 "Steam Game" mini drivers (universal minidriver pattern, RF_MINI_APP)
	  which launch titles via steam:// URIs
	- Programming events, device variables for system stats, notifications

	Uses the official Snap One common libraries (drivers-common-public), bundled.
]]

do -- constants
	DRIVER_VERSION = '1.0.0'

	MP_PROXY = 5001				-- media_player proxy binding
	SWITCHER_PROXY = 5002		-- avswitch proxy binding hosting the RF_MINI_APP inputs
	NET_BINDING = 6001			-- static network binding (address entry only; WS runs on its own binding)

	SB_PORT = 9170				-- System Bridge plaintext ws:// port
	SB_TLS_PORT = 9171			-- default c4tls proxy wss:// port
	SB_WS_PATH = '/api/websocket'
	SB_MODULES = { 'system', 'cpu', 'memory', 'gpus', 'media', 'battery' }
	CA_FILENAME = 'c4tls_ca.pem'	-- pinned cert written to the driver sandbox
	PERSIST_TOKEN_KEY = 'sb_token'	-- Director encrypted-PersistData key for the token

	MINIAPP_BINDING_START = 3101
	MINIAPP_BINDING_END = 3125
	MINIAPP_TYPE = 'UM_STEAM_MACHINE'	-- variable name minidrivers publish their steam:// URI under

	URI_BIG_PICTURE = 'steam://open/bigpicture'
	URI_LIBRARY = 'steam://open/games'
	URI_SETTINGS = 'steam://open/settings'

	-- Only these URI schemes may be sent to System Bridge OPEN. OPEN runs
	-- xdg-open on the target, so an unrestricted URI could open file:// paths
	-- (e.g. the System Bridge token file) or trigger app/desktop URI handlers
	-- that execute code. Keep this to steam:// unless you deliberately ship
	-- documented https deep-links (then add https = true).
	ALLOWED_URI_SCHEMES = { steam = true }

	MAX_VAR_LEN = 256			-- cap for strings we copy from System Bridge into Control4 variables

	LAUNCH_GRACE_SECONDS = 15	-- suppress Big Picture launch right after a game launch
	STALE_SECONDS = 180			-- no traffic for this long -> force reconnect
end

do -- driver state
	g_ip = ''
	g_token = ''
	g_mac = ''
	g_ws = nil
	g_tcpUp = false				-- TCP + WS handshake up
	g_online = false			-- authenticated (a non-error response was received)
	g_msgId = 0
	g_reconnectDelay = 5
	g_lastRx = 0
	g_wantMacUpdate = false
	g_secMode = 'Plaintext (ws://)'	-- Connection Security property
	g_tlsPort = SB_TLS_PORT
	g_caReady = false				-- pinned cert written to sandbox
	g_effectiveVerify = nil			-- actual TLS verify level in use: 'peer' | 'none' | nil (plaintext)
	g_pendingLaunch = nil		-- URI to open once authenticated
	g_lastGameLaunch = 0
	g_lastMediaStatus = nil
	g_proxyPower = nil			-- last ON/OFF notify sent to the media_player proxy
	g_pendingPad = {}			-- outstanding c4pad COMMAND_EXECUTE requests, id -> {cmd, ts}
	g_activeHolds = {}			-- direction -> c4pad hold commandID currently held
end

require ('drivers-common-public.global.handlers')
require ('drivers-common-public.global.timer')
WebSocket = require ('drivers-common-public.module.websocket')
-- JSON global is provided by drivers-common-public.global.lib (loaded by handlers)

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------

local function trim (s)
	return (tostring (s or ''):gsub ('^%s+', ''):gsub ('%s+$', ''))
end

local function normalizeMac (s)
	local hex = tostring (s or ''):gsub ('[^%x]', ''):upper ()
	if (#hex ~= 12) then
		return ''
	end
	local parts = {}
	for i = 1, 12, 2 do
		table.insert (parts, hex:sub (i, i + 1))
	end
	return table.concat (parts, ':')
end

local function setVarNum (name, value)
	if (type (value) == 'number') then
		SetVariable (name, tostring (math.floor (value + 0.5)))
	end
end

-- Sanitize a string that came from System Bridge (untrusted: plaintext ws://,
-- all-origins server) before writing it into a Control4 variable that user
-- programming may consume. Strip control chars and cap the length.
local function safeStr (s)
	s = tostring (s or ''):gsub ('%c', ' ')
	if (#s > MAX_VAR_LEN) then
		s = s:sub (1, MAX_VAR_LEN)
	end
	return s
end

-- Extract the lowercased scheme of a "<scheme>://..." URI, or nil if the value
-- is not in that form (a bare path or schemeless string fails closed).
local function uriScheme (uri)
	local scheme = tostring (uri or ''):match ('^(%a[%w+.-]*)://')
	return scheme and scheme:lower ()
end

local function uptimeText (seconds)
	seconds = math.floor (tonumber (seconds) or 0)
	local d = math.floor (seconds / 86400)
	local h = math.floor ((seconds % 86400) / 3600)
	local m = math.floor ((seconds % 3600) / 60)
	return string.format ('%dd %dh %dm', d, h, m)
end

---------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------

function OnDriverInit ()
	-- Variables must be created here, in a stable order, so programming
	-- attached to them survives Director restarts.
	C4:AddVariable ('ONLINE', '0', 'BOOL', true)
	C4:AddVariable ('UPTIME_SECONDS', '0', 'NUMBER', true)
	C4:AddVariable ('UPTIME_TEXT', '', 'STRING', true)
	C4:AddVariable ('HOSTNAME', '', 'STRING', true)
	C4:AddVariable ('CPU_TEMPERATURE', '0', 'NUMBER', true)
	C4:AddVariable ('GPU_TEMPERATURE', '0', 'NUMBER', true)
	C4:AddVariable ('CPU_USAGE', '0', 'NUMBER', true)
	C4:AddVariable ('MEMORY_USED_PERCENT', '0', 'NUMBER', true)
	C4:AddVariable ('BATTERY_PERCENT', '0', 'NUMBER', true)
	C4:AddVariable ('NOW_PLAYING', '', 'STRING', true)
	C4:AddVariable ('MEDIA_STATUS', '', 'STRING', true)
	C4:AddVariable ('CURRENT_GAME', '', 'STRING', true)

	-- Load the token from Director's encrypted PersistData store (PersistData is
	-- OnDriverInit-safe). The token is NOT kept in the plaintext password
	-- property - see OPC.System_Bridge_Token.
	local ok, stored = pcall (function () return C4:PersistGetValue (PERSIST_TOKEN_KEY, true) end)
	if (ok and type (stored) == 'string') then
		g_token = stored
	end
end

function OnDriverLateInit ()
	for property, _ in pairs (Properties) do
		OnPropertyChanged (property)
	end

	UpdateProperty ('Driver Version', DRIVER_VERSION)
	UpdateProperty ('Director Connection', 'Connected (driver v' .. DRIVER_VERSION .. ' running)')
	UpdateProperty ('Token Status', (g_token ~= '') and 'Stored (encrypted at rest)' or 'Not set')

	HideProxyInAllRooms (SWITCHER_PROXY)

	RefreshAddress ()

	SetTimer ('StaleCheck', 60 * ONE_SECOND, CheckStale, true)
end

function OnDriverDestroyed ()
	if (g_ws) then
		g_ws:delete ()
		g_ws = nil
	end
	KillAllTimers ()
end

function OnNetworkBindingChanged (idBinding, bIsBound)
	if (idBinding == NET_BINDING) then
		RefreshAddress ()
	end
end

---------------------------------------------------------------------------
-- properties
---------------------------------------------------------------------------

OPC = OPC or {}

function OPC.Debug_Mode (value)
	DEBUGPRINT = (value == 'Print')
	-- Never let the vendored WebSocket lib log raw frames: every outbound frame
	-- contains the System Bridge token, so frame logging would leak it to the
	-- Director log. Our own dbg() output never includes the token.
	DEBUG_WEBSOCKET = false
	DEBUG_RFN = false
end

function OPC.System_Bridge_Token (value)
	value = trim (value)

	-- Empty means either the post-store blank we do below, or the OnDriverLateInit
	-- property replay of an already-blanked field. In both cases keep the token
	-- that OnDriverInit loaded from encrypted PersistData - do NOT clear it here.
	-- (Use the 'Clear Stored Token' action to remove it.)
	if (value == '') then
		return
	end

	-- A newly entered token: move it into Director's encrypted PersistData store
	-- and immediately blank the plaintext property so the secret is not persisted
	-- in cleartext in the project DB / .c4bak. UpdateProperty does not re-fire
	-- OnPropertyChanged, so blanking here is safe (no recursion, no clear).
	C4:PersistSetValue (PERSIST_TOKEN_KEY, value, true)
	g_token = value
	UpdateProperty ('System Bridge Token', '')
	UpdateProperty ('Token Status', 'Stored (encrypted at rest)')

	if (g_ws and g_ws.running) then
		SBSubscribe ()
	end
end

function OPC.Connection_Security (value)
	g_secMode = value
	Reconnect ()
end

function OPC.TLS_Port (value)
	local p = tonumber (trim (value))
	if (p and p >= 1 and p <= 65535) then
		g_tlsPort = math.floor (p)
	else
		g_tlsPort = SB_TLS_PORT
	end
	if (g_secMode:find ('^TLS')) then
		Reconnect ()
	end
end

function OPC.Server_Certificate (value)
	value = trim (value)
	local pem
	if (value == '') then
		g_caReady = false
	elseif (value:find ('BEGIN CERTIFICATE')) then
		pem = value						-- pasted raw PEM
	else
		local ok, decoded = pcall (function () return C4:Base64Decode (value) end)
		if (ok and type (decoded) == 'string' and decoded:find ('BEGIN CERTIFICATE')) then
			pem = decoded				-- single-line base64 blob the installer prints
		end
	end

	if (pem) then
		-- CACERTFILE is a path relative to the driver's c4z location; write the
		-- pinned cert into the sandbox and reference it there
		FileWrite (CA_FILENAME, pem, true)
		g_caReady = true
	elseif (value ~= '') then
		g_caReady = false
		dbg ('Server Certificate is not a valid PEM or base64-encoded PEM')
	end

	if (g_secMode:find ('^TLS')) then
		Reconnect ()
	end
end

function OPC.MAC_Address (value)
	local mac = normalizeMac (value)
	if (mac ~= '') then
		g_mac = mac
		UpdateProperty ('MAC Address', mac)
	else
		g_mac = ''
		if (trim (value) ~= '') then
			-- malformed entry: clear it (immediate feedback in Composer) instead
			-- of leaving invalid text that silently disables WOL after the next
			-- Director restart; a blank property also re-enables auto-fill from
			-- System Bridge system data
			UpdateProperty ('MAC Address', '')
		end
	end
end

---------------------------------------------------------------------------
-- connection management
---------------------------------------------------------------------------

function RefreshAddress ()
	local addr = trim (C4:GetBindingAddress (NET_BINDING))

	if (addr == g_ip and g_ws) then
		return
	end

	g_ip = addr

	if (g_ws) then
		g_ws:delete ()
		g_ws = nil
	end
	CancelTimer ('Reconnect')
	SetOnline (false)
	g_tcpUp = false

	if (g_ip == '') then
		UpdateProperty ('Network Connection', 'No address entered - set the IP in Connections > Network')
		return
	end

	Connect ()
end

-- Build the WebSocket URL + TLS options for the current security mode.
-- Plaintext -> ws://ip:9170 ; TLS modes -> wss://ip:tlsport via the c4tls proxy.
function ConnectionConfig ()
	local wssURL = 'wss://' .. g_ip .. ':' .. g_tlsPort .. SB_WS_PATH
	if (g_secMode == 'TLS encrypt-only (wss://)') then
		g_effectiveVerify = 'none'
		return wssURL, { VERIFY_MODE = 'none' }
	elseif (g_secMode == 'TLS pinned (wss://)') then
		if (g_caReady) then
			g_effectiveVerify = 'peer'
			return wssURL, { VERIFY_MODE = 'peer', CACERTFILE = './' .. CA_FILENAME }
		end
		-- pinned selected but no valid cert yet: encrypt-only rather than fail.
		-- g_effectiveVerify records the DOWNGRADE so the status label makes the
		-- missing MITM protection visible (not silent).
		g_effectiveVerify = 'none-fallback'
		dbg ('TLS pinned selected but no certificate set; using encrypt-only until a cert is pasted')
		return wssURL, { VERIFY_MODE = 'none' }
	end
	g_effectiveVerify = nil
	return 'ws://' .. g_ip .. ':' .. SB_PORT .. SB_WS_PATH, nil
end

function Connect ()
	if (g_ip == '') then
		return
	end

	if (not g_ws) then
		local url, wssOptions = ConnectionConfig ()
		local ws, err = WebSocket:new (url, nil, wssOptions)
		if (not ws) then
			UpdateProperty ('Network Connection', 'Error: ' .. tostring (err))
			return
		end
		g_ws = ws
		g_ws:SetEstablishedFunction (function (socket) OnWsEstablished () end)
		g_ws:SetProcessMessageFunction (function (socket, data) OnWsMessage (data) end)
		g_ws:SetOfflineFunction (function (socket) OnWsDown ('Offline') end)
		g_ws:SetClosedByRemoteFunction (function (socket) OnWsDown ('Closed by remote') end)
	end

	UpdateProperty ('Network Connection', 'Connecting to ' .. g_ip .. ' (' .. g_secMode .. ')...')
	g_ws:Start ()
end

-- Tear down and rebuild the socket after a security/port/cert change.
function Reconnect ()
	if (g_ws) then
		g_ws:delete ()
		g_ws = nil
	end
	CancelTimer ('Reconnect')
	SetOnline (false)
	g_tcpUp = false
	g_reconnectDelay = 5
	if (g_ip ~= '') then
		Connect ()
	end
end

function OnWsEstablished ()
	g_tcpUp = true
	g_reconnectDelay = 5
	g_lastRx = os.time ()
	CancelTimer ('Reconnect')
	local port = (g_secMode:find ('^TLS')) and g_tlsPort or SB_PORT
	local enc
	if (g_effectiveVerify == 'peer') then
		enc = 'TLS pinned'
	elseif (g_effectiveVerify == 'none') then
		enc = 'TLS encrypt-only'
	elseif (g_effectiveVerify == 'none-fallback') then
		enc = 'TLS encrypt-only (PINNED SELECTED BUT NO CERTIFICATE - not MITM-protected)'
	else
		enc = 'plaintext'
	end
	UpdateProperty ('Network Connection', 'Online (' .. g_ip .. ':' .. port .. ', ' .. enc .. ')')
	SBSubscribe ()
end

function OnWsDown (reason)
	local wasUp = g_tcpUp
	g_tcpUp = false
	g_pendingPad = {}
	g_activeHolds = {}
	CancelTimer ('PadHoldRefresh')
	SetOnline (false)
	if (wasUp or (Properties ['Network Connection'] or ''):find ('Connecting')) then
		UpdateProperty ('Network Connection', 'Offline (' .. reason .. ')')
	end
	ScheduleReconnect ()
end

function ScheduleReconnect ()
	if (g_ip == '') then
		return
	end
	SetTimer ('Reconnect', g_reconnectDelay * ONE_SECOND, function ()
		g_reconnectDelay = math.min (g_reconnectDelay * 2, 60)
		if (g_ws) then
			g_ws:Start ()
		else
			Connect ()
		end
	end)
end

function CheckStale ()
	if (g_tcpUp and (os.time () - g_lastRx) > STALE_SECONDS) then
		dbg ('No System Bridge traffic for ' .. STALE_SECONDS .. 's - reconnecting')
		if (g_ws) then
			g_ws:Start ()
		end
	end

	-- drop pad requests that never got a terminal response
	local now = os.time ()
	for id, pending in pairs (g_pendingPad) do
		if (now - pending.ts > 60) then
			g_pendingPad [id] = nil
		end
	end
end

function SetOnline (online)
	-- NOTE: link state deliberately does NOT drive the media_player ON/OFF
	-- notifies. Sending ON on every reconnect would auto-select the source in
	-- rooms (and OFF would flap them) whenever the PC wakes for updates or the
	-- socket blips. Power notifies are sent only from PowerOn/PowerOff.
	if (online and not g_online) then
		g_online = true
		SetVariable ('ONLINE', '1')
		UpdateProperty ('System Bridge Connection', 'Connected and authenticated')
		C4:FireEvent ('Came Online')

		if (g_pendingLaunch) then
			local uri = g_pendingLaunch
			g_pendingLaunch = nil
			CancelTimer ('PendingLaunch')
			SBOpen (uri)
		end
	elseif (not online and g_online) then
		g_online = false
		SetVariable ('ONLINE', '0')
		UpdateProperty ('System Bridge Connection', 'Not connected')
		C4:FireEvent ('Went Offline')
	end
end

function NotifyPower (state)
	if (g_proxyPower ~= state) then
		g_proxyPower = state
		C4:SendToProxy (MP_PROXY, state, {}, 'NOTIFY')
	end
end

---------------------------------------------------------------------------
-- System Bridge protocol
---------------------------------------------------------------------------

function SBSend (event, data)
	if (not (g_ws and g_ws.running)) then
		dbg ('SBSend skipped (not connected): ' .. event)
		return false
	end
	if (g_token == '') then
		UpdateProperty ('System Bridge Connection', 'No token set - paste the System Bridge token')
		return false
	end

	g_msgId = g_msgId + 1
	local msg = {
		id = 'c4-' .. g_msgId .. '-' .. event,
		event = event,
		data = data or {},
		token = g_token,
	}
	g_ws:Send (JSON:encode (msg))
	return msg.id
end

function SBSubscribe ()
	-- listeners are dropped by the server on disconnect; (re)register every time
	SBSend ('UNREGISTER_DATA_LISTENER', {})
	SBSend ('REGISTER_DATA_LISTENER', { modules = SB_MODULES })
	SBSend ('GET_DATA', { modules = SB_MODULES })
end

function SBOpen (uri)
	return SBSend ('OPEN', { url = uri })
end

function SBMedia (action)
	return SBSend ('MEDIA_CONTROL', { action = action })
end

function SBKey (key)
	key = trim (key):lower ()
	-- robotgo key tokens are short and drawn from a fixed vocabulary
	-- ('a', 'enter', 'f1', 'audio_vol_up', 'num.', 'num+', 'lights_kbd_toggle').
	-- Constrain to that shape so a stray/hostile value can't smuggle anything
	-- unexpected into the injection call, while still admitting every real token.
	if (key ~= '' and #key <= 24 and key:match ('^[%w_%.%+%*/%-]+$')) then
		return SBSend ('KEYBOARD_KEYPRESS', { key = key, delay = 0 })
	end
	dbg ('SBKey rejected key token: ' .. tostring (key))
end

function OnWsMessage (data)
	g_lastRx = os.time ()

	local ok, msg = pcall (function () return JSON:decode (data) end)
	if (not ok or type (msg) ~= 'table') then
		dbg ('Undecodable message from System Bridge')
		return
	end

	local msgType = msg.type

	if (msgType == 'ERROR') then
		if (msg.subtype == 'BAD_TOKEN' or msg.subtype == 'MISSING_TOKEN') then
			UpdateProperty ('System Bridge Connection', 'Invalid token - check the System Bridge Token property')
		elseif (msg.subtype == 'COMMAND_NOT_FOUND' and msg.id and g_pendingPad [msg.id]) then
			local pending = g_pendingPad [msg.id]
			g_pendingPad [msg.id] = nil
			OnPadCommandMissing (pending.cmd)
		else
			dbg ('System Bridge error: ' .. tostring (msg.message) .. ' (' .. tostring (msg.subtype) .. ')')
		end
		return
	end

	-- any non-error response proves the token is good
	SetOnline (true)

	if (msgType == 'DATA_UPDATE') then
		HandleModule (msg.module, msg.data)

	elseif (msgType == 'OPENED') then
		local url = (type (msg.data) == 'table' and msg.data.url) or ''
		if (tostring (url):find ('^steam://')) then
			C4:FireEvent ('Game Launched')
		end

	elseif (msgType == 'NOTIFICATION_SENT') then
		C4:FireEvent ('Notification Sent')

	elseif (msgType == 'COMMAND_COMPLETED' and msg.id) then
		local pending = g_pendingPad [msg.id]
		g_pendingPad [msg.id] = nil
		local exitCode = type (msg.data) == 'table' and tonumber (msg.data.exitCode)
		if (pending and exitCode and exitCode ~= 0) then
			dbg ('c4pad command failed (exit ' .. exitCode .. ') for ' .. pending.cmd ..
				' - is the c4pad daemon running on the Steam Machine?')
		end
	end
end

function HandleModule (module, data)
	if (type (data) ~= 'table') then
		return
	end

	if (module == 'system') then
		if (data.uptime) then
			setVarNum ('UPTIME_SECONDS', tonumber (data.uptime))
			SetVariable ('UPTIME_TEXT', uptimeText (data.uptime))
		end
		if (data.hostname) then
			SetVariable ('HOSTNAME', safeStr (data.hostname))
		end
		local mac = normalizeMac (data.mac_address)
		if (mac ~= '') then
			if (g_wantMacUpdate or trim (Properties ['MAC Address']) == '') then
				g_wantMacUpdate = false
				g_mac = mac
				UpdateProperty ('MAC Address', mac)
			end
		end

	elseif (module == 'cpu') then
		if (data.temperature) then
			setVarNum ('CPU_TEMPERATURE', tonumber (data.temperature))
		end
		if (data.usage) then
			setVarNum ('CPU_USAGE', tonumber (data.usage))
		end

	elseif (module == 'gpus') then
		local maxTemp
		for _, gpu in ipairs (data) do
			local t = tonumber (type (gpu) == 'table' and gpu.temperature)
			if (t and (not maxTemp or t > maxTemp)) then
				maxTemp = t
			end
		end
		if (maxTemp) then
			setVarNum ('GPU_TEMPERATURE', maxTemp)
		end

	elseif (module == 'memory') then
		local pct = type (data.virtual) == 'table' and tonumber (data.virtual.percent)
		if (pct) then
			setVarNum ('MEMORY_USED_PERCENT', pct)
		end

	elseif (module == 'battery') then
		if (data.percentage) then
			setVarNum ('BATTERY_PERCENT', tonumber (data.percentage))
		end

	elseif (module == 'media') then
		local title = tostring (data.title or '')
		local artist = tostring (data.artist or '')
		local nowPlaying = title
		if (artist ~= '' and title ~= '') then
			nowPlaying = title .. ' - ' .. artist
		end
		SetVariable ('NOW_PLAYING', safeStr (nowPlaying))

		local status = tostring (data.status or ''):gsub ('%c', ''):sub (1, 32)
		if (status ~= '' and status ~= g_lastMediaStatus) then
			g_lastMediaStatus = status
			SetVariable ('MEDIA_STATUS', status)
			if (status == 'PLAYING') then
				C4:FireEvent ('Media Started Playing')
				C4:SendToProxy (MP_PROXY, 'PLAY', {}, 'NOTIFY')
			elseif (status == 'PAUSED') then
				C4:FireEvent ('Media Paused')
				C4:SendToProxy (MP_PROXY, 'PAUSE', {}, 'NOTIFY')
			elseif (status == 'STOPPED') then
				C4:FireEvent ('Media Stopped')
				C4:SendToProxy (MP_PROXY, 'STOP', {}, 'NOTIFY')
			end
		end
	end
end

---------------------------------------------------------------------------
-- power & launching
---------------------------------------------------------------------------

function PowerOn (allowBigPicture)
	CancelTimer ('DeferredOff')
	C4:FireEvent ('Turned On')
	NotifyPower ('ON')

	if (g_mac ~= '') then
		C4:SendWOL (g_mac)
		SetTimer ('WOL2', 2 * ONE_SECOND, function () C4:SendWOL (g_mac) end)
		SetTimer ('WOL3', 5 * ONE_SECOND, function () C4:SendWOL (g_mac) end)
	end

	-- re-attach promptly once the machine is up instead of waiting out the
	-- full reconnect backoff
	if (not g_tcpUp) then
		g_reconnectDelay = 5
		if (g_ws) then
			ScheduleReconnect ()
		end
	end

	if (allowBigPicture
		and Properties ['Launch Into Big Picture'] == 'On'
		and (os.time () - g_lastGameLaunch) > LAUNCH_GRACE_SECONDS) then
		if (g_online) then
			SBOpen (URI_BIG_PICTURE)
		else
			QueueLaunch (URI_BIG_PICTURE)
		end
	end
end

function PowerOff (immediate)
	C4:FireEvent ('Turned Off')
	NotifyPower ('OFF')
	g_pendingLaunch = nil
	CancelTimer ('PendingLaunch')

	local doOff = function ()
		local mode = Properties ['Off Mode'] or 'Sleep'
		if (mode == 'Sleep') then
			SBSend ('POWER_SLEEP', {})
		elseif (mode == 'Power Off') then
			SBSend ('POWER_SHUTDOWN', {})
		end
	end

	if (immediate) then
		doOff ()
	else
		-- The room also sends OFF when the user switches between two of our
		-- sources (e.g. game mini app -> game mini app). Defer the actual
		-- sleep/shutdown so a SET_INPUT / relaunch / power-on arriving within
		-- the window cancels it instead of suspending the PC mid-switch.
		SetTimer ('DeferredOff', 5 * ONE_SECOND, doOff)
	end
end

function QueueLaunch (uri)
	g_pendingLaunch = uri
	-- a cold boot after 'Power Off' takes far longer than a resume from sleep
	local window = (Properties ['Off Mode'] == 'Power Off') and 300 or 120
	SetTimer ('PendingLaunch', window * ONE_SECOND, function ()
		g_pendingLaunch = nil
	end)
end

function LaunchURI (uri, friendlyName)
	uri = trim (uri)
	if (uri == '') then
		return
	end

	-- Fail closed on any scheme we don't explicitly allow. System Bridge OPEN
	-- is xdg-open-backed, so this is the gate that stops file:// / app-handler
	-- URIs from reaching the Steam Machine (single choke point for every
	-- caller: Open URI, Launch Steam Game, mini-app SET_INPUT, URI_CMD_MAP).
	local scheme = uriScheme (uri)
	if (not (scheme and ALLOWED_URI_SCHEMES [scheme])) then
		dbg ('LaunchURI rejected non-allowlisted URI: ' .. uri)
		return
	end

	CancelTimer ('DeferredOff')

	if (scheme == 'steam') then
		g_lastGameLaunch = os.time ()
		SetVariable ('CURRENT_GAME', safeStr (friendlyName or uri))
	end

	if (g_online) then
		SBOpen (uri)
	else
		-- machine is asleep/off: wake it and launch once System Bridge is back
		QueueLaunch (uri)
		PowerOn (false)
	end
end

---------------------------------------------------------------------------
-- proxy commands (navigators / room)
---------------------------------------------------------------------------

RFP = RFP or {}

local KEY_MAP = {
	UP = 'up', START_UP = 'up',
	DOWN = 'down', START_DOWN = 'down',
	LEFT = 'left', START_LEFT = 'left',
	RIGHT = 'right', START_RIGHT = 'right',
	ENTER = 'enter',
	BACK = 'esc', CANCEL = 'esc', EXIT = 'esc',
	PAGE_UP = 'pageup', START_PAGE_UP = 'pageup',
	PAGE_DOWN = 'pagedown', START_PAGE_DOWN = 'pagedown',
}

local MEDIA_MAP = {
	PLAY = 'PLAY',
	PAUSE = 'PAUSE',
	STOP = 'STOP',
	SKIP_FWD = 'NEXT',
	SKIP_REV = 'PREVIOUS',
	SCAN_FWD = 'NEXT', START_SCAN_FWD = 'NEXT',
	SCAN_REV = 'PREVIOUS', START_SCAN_REV = 'PREVIOUS',
}

local URI_CMD_MAP = {
	MENU = URI_BIG_PICTURE,
	HOME = URI_BIG_PICTURE,
	GUIDE = URI_LIBRARY,
	SETTINGS = URI_SETTINGS,
}

-- Gamepad Bridge backend: proxy command -> System Bridge allowlist commandID
-- (c4pad_<action>_<button>, matching the entries the steamos-pad installer adds).
-- Hold commands map to true press/release pairs so lists scroll properly.
local PAD_MAP = {
	UP = 'c4pad_press_up', START_UP = 'c4pad_hold_up', STOP_UP = 'c4pad_release_up',
	DOWN = 'c4pad_press_down', START_DOWN = 'c4pad_hold_down', STOP_DOWN = 'c4pad_release_down',
	LEFT = 'c4pad_press_left', START_LEFT = 'c4pad_hold_left', STOP_LEFT = 'c4pad_release_left',
	RIGHT = 'c4pad_press_right', START_RIGHT = 'c4pad_hold_right', STOP_RIGHT = 'c4pad_release_right',
	ENTER = 'c4pad_press_a',
	BACK = 'c4pad_press_b', CANCEL = 'c4pad_press_b', EXIT = 'c4pad_press_b',
	INFO = 'c4pad_press_x',
	MENU = 'c4pad_press_start',
	GUIDE = 'c4pad_press_guide',
	PAGE_UP = 'c4pad_press_lb', START_PAGE_UP = 'c4pad_press_lb',
	PAGE_DOWN = 'c4pad_press_rb', START_PAGE_DOWN = 'c4pad_press_rb',
}

-- when a c4pad allowlist entry is missing (COMMAND_NOT_FOUND), degrade:
-- holds become plain presses; presses fall back to the keyboard/URI path
local PAD_FALLBACK = {
	START_UP = 'UP', START_DOWN = 'DOWN', START_LEFT = 'LEFT', START_RIGHT = 'RIGHT',
}

function KeyboardNav (strCommand)
	if (KEY_MAP [strCommand]) then
		SBKey (KEY_MAP [strCommand])
	elseif (URI_CMD_MAP [strCommand]) then
		LaunchURI (URI_CMD_MAP [strCommand])
	end
end

function SBPad (strCommand)
	local commandID = PAD_MAP [strCommand]
	if (not commandID) then
		return false
	end

	local holdDir = commandID:match ('^c4pad_hold_(%a+)$')
	local releaseDir = commandID:match ('^c4pad_release_(%a+)$')

	if (holdDir) then
		-- sustain the hold: the daemon dead-man releases after ~5s unless the
		-- hold is refreshed, so re-send it every 2s while active
		CancelTimer ('PadEchoRelease_' .. holdDir)
		g_activeHolds [holdDir] = commandID
		StartPadHoldRefresh ()
	elseif (releaseDir) then
		g_activeHolds [releaseDir] = nil
		StopPadHoldRefreshIfIdle ()
		-- COMMAND_EXECUTE runs async on the server, so a release can execute
		-- before its hold; echo the release once more shortly after (releasing
		-- an unheld button is a no-op in the daemon)
		SetTimer ('PadEchoRelease_' .. releaseDir, 200, function ()
			SBSend ('COMMAND_EXECUTE', { commandID = commandID })
		end)
	end

	local id = SBSend ('COMMAND_EXECUTE', { commandID = commandID })
	if (id) then
		g_pendingPad [id] = { cmd = strCommand, ts = os.time () }
	end
	return true
end

function StartPadHoldRefresh ()
	SetTimer ('PadHoldRefresh', 2 * ONE_SECOND, function ()
		local any = false
		for _, cmdID in pairs (g_activeHolds) do
			any = true
			SBSend ('COMMAND_EXECUTE', { commandID = cmdID })
		end
		if (not any) then
			CancelTimer ('PadHoldRefresh')
		end
	end, true)
end

function StopPadHoldRefreshIfIdle ()
	if (next (g_activeHolds) == nil) then
		CancelTimer ('PadHoldRefresh')
	end
end

function OnPadCommandMissing (strCommand)
	dbg ('c4pad allowlist entry missing for ' .. strCommand .. ' - falling back')
	local downgraded = PAD_FALLBACK [strCommand]
	if (downgraded) then
		SBPad (downgraded)
	elseif (not strCommand:find ('^STOP_')) then
		KeyboardNav (strCommand)
	end
end

function HandleDeviceCommand (strCommand, tParams)
	local padBackend = (Properties ['Nav Input Backend'] == 'Gamepad Bridge')

	if (strCommand == 'ON') then
		PowerOn (true)
	elseif (strCommand == 'OFF') then
		PowerOff ()
	elseif (MEDIA_MAP [strCommand]) then
		SBMedia (MEDIA_MAP [strCommand])
	elseif (padBackend and PAD_MAP [strCommand]) then
		SBPad (strCommand)
	elseif (KEY_MAP [strCommand]) then
		SBKey (KEY_MAP [strCommand])
	elseif (URI_CMD_MAP [strCommand]) then
		LaunchURI (URI_CMD_MAP [strCommand])
	elseif (strCommand:find ('^STOP_')) then
		-- releases of press-and-hold keys: nothing to do on the keyboard path
	else
		dbg ('Unhandled proxy command: ' .. strCommand)
	end
end

RFP [MP_PROXY] = function (idBinding, strCommand, tParams, args)
	if (strCommand == 'PASSTHROUGH' and tParams.PASSTHROUGH_COMMAND) then
		local inner = tParams.PASSTHROUGH_COMMAND
		tParams.PASSTHROUGH_COMMAND = nil
		HandleDeviceCommand (inner, tParams)
	else
		HandleDeviceCommand (strCommand, tParams)
	end
end

RFP [SWITCHER_PROXY] = function (idBinding, strCommand, tParams, args)
	if (strCommand == 'PASSTHROUGH' and tParams.PASSTHROUGH_COMMAND) then
		local inner = tParams.PASSTHROUGH_COMMAND
		tParams.PASSTHROUGH_COMMAND = nil
		HandleDeviceCommand (inner, tParams)

	elseif (strCommand == 'SET_INPUT') then
		CancelTimer ('DeferredOff')	-- input switch, not a real power-off
		local input = tonumber (tParams.INPUT)
		if (input and input >= MINIAPP_BINDING_START and input <= MINIAPP_BINDING_END) then
			LaunchMiniApp (idBinding, input)
		end

	elseif (strCommand == 'ON' or strCommand == 'OFF') then
		-- room housekeeping on the hidden switcher; the media_player proxy handles power
	else
		dbg ('Unhandled switcher command: ' .. strCommand)
	end
end

function LaunchMiniApp (idBinding, input)
	-- resolve: our switcher proxy device -> mini driver proxy on that input -> mini protocol device
	local proxyDeviceId = next (C4:GetBoundConsumerDevices (C4:GetDeviceID (), idBinding) or {})
	if (not proxyDeviceId) then
		return
	end
	local appProxyId = C4:GetBoundProviderDevice (proxyDeviceId, input)
	if (not appProxyId or appProxyId == 0) then
		return
	end
	local appDeviceId = C4:GetBoundProviderDevice (appProxyId, 5001)
	if (not appDeviceId or appDeviceId == 0) then
		appDeviceId = appProxyId
	end

	local uri = GetUniversalAppId (appDeviceId, MINIAPP_TYPE)
	local appName = GetUniversalAppId (appDeviceId, 'APP_NAME')

	if (uri and trim (uri) ~= '') then
		LaunchURI (uri, appName)
	else
		dbg ('Mini app on input ' .. input .. ' has no ' .. MINIAPP_TYPE .. ' variable set')
	end
end

function GetUniversalAppId (deviceId, source)
	local vars = C4:GetDeviceVariables (deviceId)
	for _, var in pairs (vars or {}) do
		if (var.name == source) then
			return (var.value)
		end
	end
	if (source ~= 'APP_ID') then
		return (GetUniversalAppId (deviceId, 'APP_ID'))
	end
end

---------------------------------------------------------------------------
-- Composer actions & programming commands (via EC dispatch)
---------------------------------------------------------------------------

EC = EC or {}

function EC.Get_MAC_Address (tParams)
	g_wantMacUpdate = true
	if (g_online) then
		SBSend ('GET_DATA', { modules = { 'system' } })
	else
		UpdateProperty ('System Bridge Connection', 'Cannot fetch MAC - Steam Machine is offline')
	end
end

function EC.Clear_Stored_Token (tParams)
	C4:PersistSetValue (PERSIST_TOKEN_KEY, '', true)
	g_token = ''
	UpdateProperty ('Token Status', 'Not set')
	UpdateProperty ('System Bridge Connection', 'No token set - paste the System Bridge token')
end

function EC.Test_Connection (tParams)
	g_reconnectDelay = 5
	if (g_ws) then
		g_ws:Start ()
	else
		RefreshAddress ()
	end
end

function EC.Send_Test_Notification (tParams)
	SBSend ('NOTIFICATION', { title = 'Control4', message = 'Test notification from your Control4 system' })
end

function EC.Power_On (tParams)
	PowerOn (true)
end

function EC.Power_Off (tParams)
	-- explicit programming command: no source-switch debounce needed
	PowerOff (true)
end

function EC.Sleep (tParams)
	SBSend ('POWER_SLEEP', {})
end

function EC.Shut_Down (tParams)
	SBSend ('POWER_SHUTDOWN', {})
end

function EC.Restart (tParams)
	SBSend ('POWER_RESTART', {})
end

function EC.Lock (tParams)
	SBSend ('POWER_LOCK', {})
end

function EC.Launch_Big_Picture (tParams)
	LaunchURI (URI_BIG_PICTURE)
end

function EC.Launch_Steam_Game (tParams)
	local appId = trim (tParams.APP_ID)
	if (appId:find ('^%d+$')) then
		LaunchURI ('steam://rungameid/' .. appId)
	elseif (appId ~= '') then
		LaunchURI (appId)	-- allow a full steam:// URI here too
	end
end

function EC.Open_URI (tParams)
	LaunchURI (tParams.URI)
end

function EC.Send_Notification (tParams)
	local title = trim (tParams.TITLE)
	if (title == '') then
		title = 'Control4'
	end
	local message = trim (tParams.MESSAGE)
	if (message == '') then
		-- the server rejects empty messages (MISSING_TEXT)
		message = title
	end
	SBSend ('NOTIFICATION', {
		title = title,
		message = message,
	})
end

function EC.Media_Play_Pause (tParams)
	SBMedia ('PLAY')	-- playerctl play-pause on Linux
end

function EC.Media_Next (tParams)
	SBMedia ('NEXT')
end

function EC.Media_Previous (tParams)
	SBMedia ('PREVIOUS')
end

function EC.Media_Stop (tParams)
	SBMedia ('STOP')
end

function EC.Media_Volume_Up (tParams)
	SBMedia ('VOLUME_UP')
end

function EC.Media_Volume_Down (tParams)
	SBMedia ('VOLUME_DOWN')
end

function EC.Media_Mute (tParams)
	-- one-way on Linux: playerctl sets the MPRIS player volume to 0
	SBMedia ('MUTE')
end

function EC.Send_Keyboard_Key (tParams)
	SBKey (tParams.KEY)
end

local GAMEPAD_BUTTON_TOKENS = {
	['A'] = 'a', ['B'] = 'b', ['X'] = 'x', ['Y'] = 'y',
	['D-Pad Up'] = 'up', ['D-Pad Down'] = 'down',
	['D-Pad Left'] = 'left', ['D-Pad Right'] = 'right',
	['LB'] = 'lb', ['RB'] = 'rb',
	['Start'] = 'start', ['Select'] = 'select',
	['Guide (Steam)'] = 'guide',
}

-- Send a c4pad allowlist command by its ID and track it for the missing/fail
-- fallback (a no-op if the Gamepad Bridge is not installed).
function PadCmd (commandID)
	local id = SBSend ('COMMAND_EXECUTE', { commandID = commandID })
	if (id) then
		g_pendingPad [id] = { cmd = commandID, ts = os.time () }
	end
end

function EC.Press_Gamepad_Button (tParams)
	local token = GAMEPAD_BUTTON_TOKENS [tParams.BUTTON or '']
	if (token) then
		PadCmd ('c4pad_press_' .. token)
	end
end

---------------------------------------------------------------------------
-- Steam UI actions + colored (RGBY) navigator buttons
---------------------------------------------------------------------------
-- The chord actions require the c4pad Gamepad Bridge (they are Steam-button
-- combos on the virtual pad). Launch Big Picture / Media Play/Pause go over
-- System Bridge directly and work without c4pad.
local STEAM_ACTIONS = {
	['Steam Menu']                = function () PadCmd ('c4pad_steam') end,
	['Quick Access Menu']         = function () PadCmd ('c4pad_qam') end,
	['Toggle On-Screen Keyboard'] = function () PadCmd ('c4pad_osk') end,
	['Screenshot']                = function () PadCmd ('c4pad_screenshot') end,
	['Toggle Magnifier']          = function () PadCmd ('c4pad_magnifier') end,
	['Force Quit Game']           = function () PadCmd ('c4pad_forcequit') end,
	['Launch Big Picture']        = function () LaunchURI (URI_BIG_PICTURE) end,
	['Media Play/Pause']          = function () SBMedia ('PLAY') end,
}

function SteamAction (name)
	local f = STEAM_ACTIONS [name]
	if (f) then
		f ()
	else
		dbg ('Unknown Steam action: ' .. tostring (name))
	end
end

-- A colored button command runs the action chosen in its property, or fires a
-- programming event if set to Custom.
function RunButtonAction (color)
	local action = Properties [color .. ' Button Action'] or 'None'
	if (action == 'None') then
		return
	elseif (action == 'Fire Programming Event') then
		C4:FireEvent (color .. ' Button Pressed')
	else
		SteamAction (action)
	end
end

function EC.Red_Button (tParams)    RunButtonAction ('Red') end
function EC.Green_Button (tParams)  RunButtonAction ('Green') end
function EC.Yellow_Button (tParams) RunButtonAction ('Yellow') end
function EC.Blue_Button (tParams)   RunButtonAction ('Blue') end

-- standalone action commands (bind any navigator button / scene directly)
function EC.Steam_Menu (tParams)                 SteamAction ('Steam Menu') end
function EC.Quick_Access_Menu (tParams)          SteamAction ('Quick Access Menu') end
EC ['Toggle_On-Screen_Keyboard'] = function (tParams) SteamAction ('Toggle On-Screen Keyboard') end
function EC.Screenshot (tParams)                 SteamAction ('Screenshot') end
function EC.Toggle_Magnifier (tParams)           SteamAction ('Toggle Magnifier') end
function EC.Force_Quit_Game (tParams)            SteamAction ('Force Quit Game') end
