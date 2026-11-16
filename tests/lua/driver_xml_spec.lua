-- driver.xml <-> driver.lua consistency (string matching only, no XML library)
local H = require ('c4_mock')

local function slurp (driver, file) return H.readFile (H.DRIVER_DIRS [driver] .. '/' .. file) end

local machineXml = slurp ('steam-machine', 'driver.xml')
local machineLua = slurp ('steam-machine', 'driver.lua')
local miniXml = slurp ('steam-game-miniapp', 'driver.xml')
local miniLua = slurp ('steam-game-miniapp', 'driver.lua')

local function set (list)
	local s = {}
	for _, v in ipairs (list) do s [v] = true end
	return s
end

-- <command> definitions live in <commands>; actions reference a command by name
local function declaredCommands (xml)
	local out = {}
	local section = xml:match ('<commands>(.-)</commands>') or ''
	for name in section:gmatch ('<command>%s*<name>(.-)</name>') do out [#out + 1] = name end
	return out
end

local function declaredActions (xml)
	local out = {}
	local section = xml:match ('<actions>(.-)</actions>') or ''
	for block in section:gmatch ('<action>(.-)</action>') do
		out [#out + 1] = { name = block:match ('<name>(.-)</name>'), command = block:match ('<command>(.-)</command>') }
	end
	return out
end

local function declaredEvents (xml)
	local out = {}
	local section = xml:match ('<events>(.-)</events>') or ''
	for name in section:gmatch ('<event>.-<name>(.-)</name>') do out [#out + 1] = name end
	return out
end

describe ('machine driver.xml: identity', function ()
	it ('has a name, manufacturer, DriverWorks control and a version', function ()
		check.matches (machineXml, '<name>Steam Machine %(System Bridge%)</name>')
		check.matches (machineXml, '<version>%d+</version>')
		check.matches (machineXml, '<driver>DriverWorks</driver>')
		check.matches (machineXml, '<script file="driver%.lua"')
		check.matches (machineXml, '<manufacturer>[^<]+</manufacturer>')
		check.matches (machineXml, '<minimum_os_version>[%d%.]+</minimum_os_version>')
	end)

	it ('declares the media_player and avswitch proxies matching the Lua constants', function ()
		local env = H.machine ()
		check.matches (machineXml, '<proxy proxybindingid="5001"[^>]*>media_player</proxy>')
		check.matches (machineXml, '<proxy proxybindingid="5002"[^>]*>avswitch</proxy>')
		check.eq (env.MP_PROXY, 5001)
		check.eq (env.SWITCHER_PROXY, 5002)
		check.matches (machineXml, '<proxies qty="2">')
	end)

	it ('declares the network binding and the 25 mini-app inputs the driver expects', function ()
		local env = H.machine ()
		check.matches (machineXml, '<connection>%s*<id>' .. env.NET_BINDING .. '</id>')
		local count, seen = 0, {}
		for block in machineXml:gmatch ('<connection[^>]*>(.-)</connection>') do
			if (block:find ('<classname>RF_MINI_APP</classname>', 1, true)) then
				count = count + 1
				seen [tonumber (block:match ('<id>(%d+)</id>'))] = true
				check.matches (block, '<consumer>True</consumer>')
			end
		end
		check.eq (count, env.MINIAPP_BINDING_END - env.MINIAPP_BINDING_START + 1)
		check.truthy (seen [env.MINIAPP_BINDING_START])
		check.truthy (seen [env.MINIAPP_BINDING_END])
	end)

	it ('the System Bridge port in the TCP binding is the plaintext port the driver uses', function ()
		local env = H.machine ()
		check.contains (machineXml, '<number>' .. env.SB_PORT .. '</number>')
	end)
end)

describe ('machine driver.xml: properties', function ()
	local props = H.xmlProperties (machineXml)
	local byName = {}
	for _, p in ipairs (props) do byName [p.name] = p end

	it ('every OPC handler in driver.lua has a matching property', function ()
		local n = 0
		for handler in machineLua:gmatch ('function%s+OPC%.([%w_]+)') do
			n = n + 1
			local found = false
			for _, p in ipairs (props) do
				if (p.name:gsub ('%s+', '_') == handler) then found = true end
			end
			check.truthy (found, 'OPC.' .. handler .. ' has no property in driver.xml')
		end
		check.truthy (n >= 6)
	end)

	it ('every property the Lua code reads or writes exists in the XML', function ()
		-- Properties ['X'] / UpdateProperty ('X', ...) literals
		local names = {}
		for name in machineLua:gmatch ("Properties %['([^']+)'%]") do names [name] = true end
		for name in machineLua:gmatch ("UpdateProperty %('([^']+)'") do names [name] = true end
		local n = 0
		for name in pairs (names) do
			n = n + 1
			check.truthy (byName [name], 'property "' .. name .. '" used in driver.lua but missing from driver.xml')
		end
		check.truthy (n >= 10)
	end)

	it ('the token property is a masked (password) field, empty by default', function ()
		local p = byName ['System Bridge Token']
		check.truthy (p)
		check.eq (p.password, true)
		check.eq (p.default, '')
	end)

	it ('status properties are read-only', function ()
		for _, name in ipairs ({ 'Driver Version', 'Network Connection', 'System Bridge Connection',
			'Director Connection', 'Token Status' }) do
			check.eq (byName [name].readonly, true, name)
		end
	end)

	it ('LIST defaults are members of their item list', function ()
		for _, p in ipairs (props) do
			if (p.type == 'LIST') then
				check.truthy (set (p.items) [p.default], p.name .. ' default "' .. p.default .. '" not in its items')
			end
		end
	end)

	it ('Connection Security items match the strings ConnectionConfig compares against', function ()
		local items = set (byName ['Connection Security'].items)
		check.truthy (items ['Plaintext (ws://)'])
		check.truthy (items ['TLS encrypt-only (wss://)'])
		check.truthy (items ['TLS pinned (wss://)'])
		check.contains (machineLua, "'TLS encrypt-only (wss://)'")
		check.contains (machineLua, "'TLS pinned (wss://)'")
		local env = H.machine ()
		check.eq (env.g_secMode, byName ['Connection Security'].default)
	end)

	it ('Off Mode / Nav Input Backend / Launch Into Big Picture items are the ones the code branches on', function ()
		local off = set (byName ['Off Mode'].items)
		check.truthy (off ['Sleep'] and off ['Power Off'] and off ['Do Nothing'])
		check.truthy (set (byName ['Nav Input Backend'].items) ['Gamepad Bridge'])
		check.truthy (set (byName ['Launch Into Big Picture'].items) ['On'])
		check.truthy (set (byName ['Debug Mode'].items) ['Print'])
	end)

	it ('the default TLS port property equals the driver default', function ()
		local env = H.machine ()
		check.eq (tonumber (byName ['TLS Port'].default), env.SB_TLS_PORT)
	end)

	it ('every colored-button action item is handled by the driver (none silently dropped)', function ()
		for _, color in ipairs ({ 'Red', 'Green', 'Yellow', 'Blue' }) do
			local p = byName [color .. ' Button Action']
			check.truthy (p, color)
			check.eq (p.items [1], 'None', color)
			for _, action in ipairs (p.items) do
				local env = H.machine ()
				env.goOnline ()
				env.Properties [color .. ' Button Action'] = action
				env.ExecuteCommand (color .. ' Button')
				if (action == 'None') then
					check.eq (#env.g_ws.sent, 0, color .. '/' .. action)
				elseif (action == 'Fire Programming Event') then
					check.eq (env.c4.count ('FireEvent'), 1, color .. '/' .. action)
				else
					check.eq (#env.g_ws.sent, 1, color .. '/' .. action .. ' produced no System Bridge call')
				end
			end
		end
	end)

	it ('all four colored-button properties offer the same action list', function ()
		local red = table.concat (byName ['Red Button Action'].items, '|')
		for _, color in ipairs ({ 'Green', 'Yellow', 'Blue' }) do
			check.eq (table.concat (byName [color .. ' Button Action'].items, '|'), red, color)
		end
	end)
end)

describe ('machine driver.xml: commands, actions and events', function ()
	local env = H.machine ()
	local commands = declaredCommands (machineXml)
	local actions = declaredActions (machineXml)

	it ('declares a healthy number of commands and actions', function ()
		check.truthy (#commands >= 25, 'commands found: ' .. #commands)
		check.truthy (#actions >= 5, 'actions found: ' .. #actions)
	end)

	it ('every <command> has an EC handler (spaces normalized to underscores)', function ()
		for _, name in ipairs (commands) do
			local key = name:gsub ('%s+', '_')
			check.eq (type (env.EC [key]), 'function', 'command "' .. name .. '" has no EC.' .. key)
		end
	end)

	it ('every <action> points at a declared-or-handled command', function ()
		for _, a in ipairs (actions) do
			check.truthy (a.command and a.command ~= '', 'action "' .. tostring (a.name) .. '" has no <command>')
			local key = a.command:gsub ('%s+', '_')
			check.eq (type (env.EC [key]), 'function', 'action "' .. a.name .. '" -> EC.' .. key)
		end
	end)

	it ('command names are unique', function ()
		local seen = {}
		for _, name in ipairs (commands) do
			check.falsy (seen [name], 'duplicate command ' .. name)
			seen [name] = true
		end
	end)

	it ('every EC handler the driver defines is exposed as a command or action', function ()
		local exposed = set (commands)
		for _, a in ipairs (actions) do exposed [a.command] = true end
		local exposedKeys = {}
		for name in pairs (exposed) do exposedKeys [name:gsub ('%s+', '_')] = true end
		for key, fn in pairs (env.EC) do
			if (type (fn) == 'function') then
				check.truthy (exposedKeys [key], 'EC.' .. key .. ' is not declared in driver.xml')
			end
		end
	end)

	it ('command parameters used by handlers are declared in the XML', function ()
		for _, param in ipairs ({ 'APP_ID', 'URI', 'TITLE', 'MESSAGE', 'KEY', 'BUTTON' }) do
			check.contains (machineXml, '<name>' .. param .. '</name>', param)
		end
	end)

	it ('the Press Gamepad Button dropdown lists exactly the buttons the driver maps', function ()
		local block = machineXml:match ('<name>Press Gamepad Button</name>(.-)</command>')
		local items = {}
		for item in block:gmatch ('<item>(.-)</item>') do items [#items + 1] = item end
		check.eq (#items, 13)
		for _, button in ipairs (items) do
			local e = H.machine ()
			e.goOnline ()
			e.ExecuteCommand ('Press Gamepad Button', { BUTTON = button })
			check.eq (#e.g_ws.sent, 1, 'button "' .. button .. '" is in the XML but ignored by the driver')
		end
	end)

	it ('every FireEvent literal in driver.lua is a declared <event>', function ()
		local events = set (declaredEvents (machineXml))
		local n = 0
		for name in machineLua:gmatch ("FireEvent %('([^']+)'%)") do
			n = n + 1
			check.truthy (events [name], 'event "' .. name .. '" fired but not declared')
		end
		check.truthy (n >= 8)
		for _, color in ipairs ({ 'Red', 'Green', 'Yellow', 'Blue' }) do
			check.truthy (events [color .. ' Button Pressed'], color)
		end
	end)

	it ('event ids are unique', function ()
		local seen = {}
		local section = machineXml:match ('<events>(.-)</events>')
		for id in section:gmatch ('<id>(%d+)</id>') do
			check.falsy (seen [id], 'duplicate event id ' .. id)
			seen [id] = true
		end
	end)
end)

describe ('mini app driver.xml', function ()
	local props = H.xmlProperties (miniXml)
	local byName = {}
	for _, p in ipairs (props) do byName [p.name] = p end

	it ('has identity, version and a media_player proxy on 5001', function ()
		check.matches (miniXml, '<name>Steam Game %(Mini App%)</name>')
		check.matches (miniXml, '<version>%d+</version>')
		check.matches (miniXml, '<driver>DriverWorks</driver>')
		check.matches (miniXml, '<proxy proxybindingid="5001"[^>]*>media_player</proxy>')
	end)

	it ('exposes an RF_MINI_APP connection on the binding the Lua code uses', function ()
		local env = H.miniapp ()
		check.matches (miniXml, '<id>' .. env.APP_BINDING .. '</id>.-<classname>RF_MINI_APP</classname>')
	end)

	it ('every property the Lua code touches is declared', function ()
		for name in miniLua:gmatch ("Properties %['([^']+)'%]") do
			check.truthy (byName [name], name)
		end
		for name in miniLua:gmatch ("UpdateProperty %('([^']+)'") do
			check.truthy (byName [name], name)
		end
	end)

	it ('Launch URI is read-only (derived, never typed)', function ()
		check.eq (byName ['Launch URI'].readonly, true)
		check.eq (byName ['Game Name'].readonly, false)
	end)

	it ('machine driver and mini app agree on the shared variable name', function ()
		local m = H.machine ()
		local a = H.miniapp ()
		check.eq (m.MINIAPP_TYPE, a.MINIAPP_TYPE)
		check.eq (m.MINIAPP_BINDING_START, a.APP_BINDING)
	end)
end)
