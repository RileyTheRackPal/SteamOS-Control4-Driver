--[[
	Control4 DriverWorks API mock harness.

	Loads a driver (steam-machine or steam-game-miniapp) into a FRESH Lua
	environment table, with a recording stub of the C4 API, a virtual file system,
	persistent store, timers, and a fake WebSocket (replacing the vendored
	websocket.lua unless opts.realWebSocket is set). Every `require` the driver
	or the vendored drivers-common-public libs perform is resolved against the
	driver's own directory and loaded into the same fresh environment, so no
	state leaks between tests.

	Usage:
		local H = require ('c4_mock')
		local env = H.machine ()          -- loaded, but OnDriverInit not yet run
		env.boot ('192.168.1.50')         -- OnDriverInit + OnDriverLateInit
		env.goOnline ('tok')              -- token stored, socket up, authenticated
		env.reset ()                      -- forget everything recorded so far
]]

local M = {}

---------------------------------------------------------------------------
-- repo root / paths
---------------------------------------------------------------------------

local function detectRoot ()
	local src = debug.getinfo (1, 'S').source:sub (2):gsub ('\\', '/')
	local root = src:match ('^(.*)/tests/lua/[^/]*$')
	if (root) then return root end
	if (src:match ('^tests/lua/')) then return '.' end
	return '.'
end

M.root = detectRoot ()

local DRIVER_DIRS = {
	['steam-machine'] = M.root .. '/steam-machine',
	['steam-game-miniapp'] = M.root .. '/steam-game-miniapp',
}
M.DRIVER_DIRS = DRIVER_DIRS

function M.readFile (path)
	local f = assert (io.open (path, 'rb'))
	local s = f:read ('a')
	f:close ()
	return s
end

---------------------------------------------------------------------------
-- driver.xml helpers (string matching only)
---------------------------------------------------------------------------

local function xmlDecode (s)
	return (s:gsub ('&lt;', '<'):gsub ('&gt;', '>'):gsub ('&quot;', '"'):gsub ('&apos;', "'"):gsub ('&amp;', '&'))
end

-- returns ordered list { {name=, default=, type=, readonly=, password=, items={...}} ... }
function M.xmlProperties (xml)
	local out = {}
	local section = xml:match ('<properties>(.-)</properties>') or ''
	for block in section:gmatch ('<property>(.-)</property>') do
		local p = {
			name = xmlDecode (block:match ('<name>(.-)</name>') or ''),
			default = xmlDecode (block:match ('<default>(.-)</default>') or ''),
			type = block:match ('<type>(.-)</type>'),
			readonly = (block:match ('<readonly>(.-)</readonly>') == 'true'),
			password = (block:match ('<password>(.-)</password>') == 'true'),
			items = {},
		}
		for item in block:gmatch ('<item>(.-)</item>') do
			table.insert (p.items, xmlDecode (item))
		end
		table.insert (out, p)
	end
	return out
end

---------------------------------------------------------------------------
-- base64
---------------------------------------------------------------------------

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function b64decode (s)
	s = s:gsub ('[^' .. B64 .. '=]', '')
	return (s:gsub ('.', function (x)
		if (x == '=') then return '' end
		local r, f = '', (B64:find (x, 1, true) - 1)
		for i = 6, 1, -1 do r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and '1' or '0') end
		return r
	end):gsub ('%d%d%d?%d?%d?%d?%d?%d?', function (x)
		if (#x ~= 8) then return '' end
		local c = 0
		for i = 1, 8 do c = c + (x:sub (i, i) == '1' and 2 ^ (8 - i) or 0) end
		return string.char (math.floor (c))
	end))
end

local function b64encode (data)
	return ((data:gsub ('.', function (x)
		local r, b = '', x:byte ()
		for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
		return r
	end) .. '0000'):gsub ('%d%d%d?%d?%d?%d?', function (x)
		if (#x < 6) then return '' end
		local c = 0
		for i = 1, 6 do c = c + (x:sub (i, i) == '1' and 2 ^ (6 - i) or 0) end
		return B64:sub (c + 1, c + 1)
	end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

M.b64encode = b64encode
M.b64decode = b64decode

---------------------------------------------------------------------------
-- fake WebSocket (same surface the driver uses from websocket.lua)
---------------------------------------------------------------------------

local function newFakeWebSocketModule (state)
	local WS = {}
	WS.__index = WS
	WS.Sockets = {}

	function WS:new (url, headers, options)
		if (type (url) ~= 'string' or not url:match ('^wss?://')) then
			return nil, 'invalid WebSocket URL provided:' .. tostring (url)
		end
		local ws = setmetatable ({
			url = url, headers = headers, options = options,
			running = false, starts = 0, deleted = false, sent = {},
		}, WS)
		table.insert (state.sockets, ws)
		return ws
	end

	function WS:Start () self.starts = self.starts + 1; return self end
	function WS:Close () self.running = false; return self end
	function WS:delete () self.deleted = true; self.running = false end
	function WS:Send (s) table.insert (self.sent, s) end
	function WS:SetProcessMessageFunction (f) self.onMessage = f end
	function WS:SetEstablishedFunction (f) self.onEstablished = f end
	function WS:SetOfflineFunction (f) self.onOffline = f end
	function WS:SetClosedByRemoteFunction (f) self.onClosed = f end

	-- test helpers
	function WS:establish () self.running = true; self.onEstablished (self) end
	function WS:emit (data) self.onMessage (self, data) end
	function WS:dropOffline () self.running = false; self.onOffline (self) end
	function WS:dropRemote () self.running = false; self.onClosed (self) end

	return WS
end

---------------------------------------------------------------------------
-- environment construction
---------------------------------------------------------------------------

local function stringify (v)
	if (type (v) == 'table') then
		local parts = {}
		for k, x in pairs (v) do parts [#parts + 1] = tostring (k) .. '=' .. stringify (x) end
		table.sort (parts)
		return '{' .. table.concat (parts, ',') .. '}'
	end
	return tostring (v)
end

function M.new (driverName, opts)
	opts = opts or {}
	local dir = assert (DRIVER_DIRS [driverName], 'unknown driver ' .. tostring (driverName))

	local env = setmetatable ({}, { __index = _G })
	env._G = env

	local c4 = {
		calls = {},
		addr = {},			-- binding id -> address returned by GetBindingAddress
		persist = {},		-- key -> { value =, encrypted = }
		files = {},			-- virtual sandbox file system: name -> content
		sockets = {},		-- fake websockets created, in order
		printed = {},		-- everything the driver print()ed
		overrides = {},		-- name -> function(...) replacing a default impl
	}
	env.c4 = c4

	-- Properties table seeded from driver.xml defaults (as Director would)
	env.Properties = {}
	local xml = M.readFile (dir .. '/driver.xml')
	for _, p in ipairs (M.xmlProperties (xml)) do
		env.Properties [p.name] = p.default
	end
	env.Variables = {}
	env.PersistData = {}
	env.C4SystemEvents = { OnPIP = 6, OnAll = 1 }

	env.print = function (...)
		local t = table.pack (...)
		for i = 1, t.n do t [i] = tostring (t [i]) end
		local line = table.concat (t, '\t')
		table.insert (c4.printed, line)
		if (os.getenv ('TEST_VERBOSE')) then print (line) end
	end

	-- recorder ---------------------------------------------------------
	local function record (name, ...)
		table.insert (c4.calls, { name = name, args = table.pack (...) })
	end

	local defaults = {}
	local NOISE = { StatsdCounter = true, StatsdGauge = true, StatsdAdjustGauge = true, StatsdTimer = true,
		StatsdString = true, StatsdJSONObject = true, StatsdIncrementMeter = true }

	function defaults.GetDeviceID () return 100 end
	function defaults.GetTime () return os.time () * 1000 end
	function defaults.GetBindingAddress (_, b) return c4.addr [b] or '' end
	function defaults.GetDriverConfigInfo () return 'mock' end
	function defaults.GetVersionInfo () return { version = '3.3.0.0' } end
	function defaults.GetBoundConsumerDevices () return {} end
	function defaults.GetBoundProviderDevice () return 0 end
	function defaults.GetDeviceVariables () return {} end
	function defaults.GetDeviceVariable () return nil end
	function defaults.GetDevicesByC4iName () return {} end
	function defaults.GetProxyDevices () return {} end
	function defaults.GetDeviceDisplayName (_, id) return 'device ' .. tostring (id) end
	function defaults.Base64Decode (_, s) return b64decode (s) end
	function defaults.Base64Encode (_, s) return b64encode (s) end

	function defaults.UpdateProperty (_, name, value) env.Properties [name] = value end
	function defaults.SetVariable (_, name, value) env.Variables [name] = value end
	function defaults.AddVariable (_, name, value) env.Variables [name] = value end

	function defaults.PersistSetValue (_, key, value, encrypted)
		c4.persist [key] = { value = value, encrypted = encrypted }
	end
	function defaults.PersistGetValue (_, key)
		local e = c4.persist [key]
		return e and e.value or nil
	end
	function defaults.PersistDeleteValue (_, key) c4.persist [key] = nil end

	-- virtual file system -------------------------------------------------
	local handles = {}
	function defaults.FileExists (_, name) return c4.files [name] ~= nil end
	function defaults.FileOpen (_, name)
		if (c4.files [name] == nil) then c4.files [name] = '' end
		handles [#handles + 1] = { name = name, pos = 0 }
		return #handles
	end
	function defaults.FileGetSize (_, h) return #c4.files [handles [h].name] end
	function defaults.FileSetPos (_, h, pos) handles [h].pos = pos end
	function defaults.FileWrite (_, h, len, content)
		local f = handles [h]
		local cur = c4.files [f.name]
		c4.files [f.name] = cur:sub (1, f.pos) .. content .. cur:sub (f.pos + #content + 1)
		return #content
	end
	function defaults.FileRead (_, h, len) local f = handles [h]; return c4.files [f.name]:sub (f.pos + 1, f.pos + len) end
	function defaults.FileClose () end
	function defaults.FileDelete (_, name) c4.files [name] = nil end

	function defaults.SetTimer (_, delay, fn, repeating)
		local t = { delay = delay, fn = fn, repeating = repeating, cancelled = false }
		function t:Cancel () self.cancelled = true; return nil end
		return t
	end

	local C4 = {}
	setmetatable (C4, { __index = function (_, name)
		return function (self, ...)
			if (not NOISE [name]) then record (name, ...) end
			local fn = c4.overrides [name] or defaults [name]
			if (fn) then return fn (self, ...) end
		end
	end })
	env.C4 = C4

	-- calls helpers ----------------------------------------------------------
	function c4.of (name)
		local out = {}
		for _, c in ipairs (c4.calls) do
			if (c.name == name) then out [#out + 1] = c.args end
		end
		return out
	end
	function c4.count (name) return #c4.of (name) end
	function c4.override (name, fn) c4.overrides [name] = fn end

	-- module loading ---------------------------------------------------------
	local loaded = {}
	env.package = { loaded = loaded, path = '' }
	local fakeWS = (not opts.realWebSocket) and newFakeWebSocketModule (c4) or nil

	env.require = function (name)
		if (loaded [name] ~= nil) then return loaded [name] end
		if (fakeWS and name == 'drivers-common-public.module.websocket') then
			loaded [name] = fakeWS
			return fakeWS
		end
		local path = dir .. '/' .. name:gsub ('%.', '/') .. '.lua'
		local fn, err = loadfile (path, 't', env)
		if (not fn) then error ('require ' .. name .. ': ' .. tostring (err), 2) end
		local result = fn (name)
		if (result == nil) then result = true end
		loaded [name] = result
		return result
	end

	-- load the driver itself
	local chunk, err = loadfile (dir .. '/driver.lua', 't', env)
	assert (chunk, err)
	chunk ()

	-----------------------------------------------------------------------
	-- convenience helpers on env
	-----------------------------------------------------------------------

	function env.ws () return env.g_ws end

	-- forget everything recorded so far (calls, prints, frames sent)
	function env.reset ()
		c4.calls = {}
		c4.printed = {}
		for _, s in ipairs (c4.sockets) do s.sent = {}; s.starts = 0 end
	end

	-- simulate the user editing a property in Composer
	function env.setProperty (name, value)
		env.Properties [name] = value
		return env.OnPropertyChanged (name)
	end

	-- OnDriverInit + OnDriverLateInit with the given network binding address
	function env.boot (ip)
		c4.addr [6001] = ip
		env.OnDriverInit ()
		env.OnDriverLateInit ()
	end

	-- decoded frames sent through the fake socket (optionally one socket)
	function env.sent (ws)
		ws = ws or env.g_ws
		local out = {}
		for _, raw in ipairs (ws and ws.sent or {}) do
			out [#out + 1] = env.JSON:decode (raw)
		end
		return out
	end

	function env.sentEvents (ws)
		local ev = {}
		for _, m in ipairs (env.sent (ws)) do ev [#ev + 1] = m.event end
		return ev
	end

	-- last frame sent, decoded
	function env.lastSent ()
		local all = env.sent ()
		return all [#all]
	end

	-- feed a decoded table to the driver as a System Bridge message
	function env.rx (tbl)
		env.g_ws:emit (env.JSON:encode (tbl))
	end

	-- full happy path: stored token, socket established, first non-error push
	function env.goOnline (token)
		if (not env.g_ws) then env.boot ('192.168.1.50') end
		env.Properties ['System Bridge Token'] = token or 'test-token-123'
		env.OnPropertyChanged ('System Bridge Token')
		env.g_ws:establish ()
		env.rx ({ type = 'DATA_UPDATE', module = 'cpu', data = {} })
		assert (env.g_online, 'goOnline: driver did not reach online state')
		env.reset ()
	end

	-- fire a driver timer by name (as Director would on expiry)
	function env.fireTimer (name)
		local t = env.Timer [name]
		assert (t, 'no active timer ' .. name)
		t.fn (t, 0)
	end

	function env.timer (name) return env.Timer [name] end

	-- every call/log line stringified, for leak scans. Excludes websocket frames.
	function env.observableText (skip)
		skip = skip or {}
		local parts = {}
		for _, line in ipairs (c4.printed) do parts [#parts + 1] = line end
		for _, c in ipairs (c4.calls) do
			if (not skip [c.name]) then
				for i = 1, c.args.n do parts [#parts + 1] = stringify (c.args [i]) end
			end
		end
		for k, v in pairs (env.Properties) do parts [#parts + 1] = tostring (k) .. '=' .. tostring (v) end
		for k, v in pairs (env.Variables) do parts [#parts + 1] = tostring (k) .. '=' .. tostring (v) end
		return table.concat (parts, '\n')
	end

	return env
end

function M.machine (opts) return M.new ('steam-machine', opts) end
function M.miniapp (opts) return M.new ('steam-game-miniapp', opts) end

return M
