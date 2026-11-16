-- steam-machine: RFP proxy commands, HandleDeviceCommand, EC actions, colored buttons, mini-app launch, c4pad
local H = require ('c4_mock')

local function online ()
	local env = H.machine ()
	env.goOnline ()
	return env
end

local function padMode ()
	local env = online ()
	env.Properties ['Nav Input Backend'] = 'Gamepad Bridge'
	return env
end

local function eventsFired (env)
	local out = {}
	for _, a in ipairs (env.c4.of ('FireEvent')) do out [#out + 1] = a [1] end
	return out
end

describe ('proxy commands: keyboard backend (default)', function ()
	local KEYS = {
		UP = 'up', DOWN = 'down', LEFT = 'left', RIGHT = 'right', ENTER = 'enter',
		BACK = 'esc', CANCEL = 'esc', EXIT = 'esc', PAGE_UP = 'pageup', PAGE_DOWN = 'pagedown',
		START_UP = 'up', START_DOWN = 'down', START_LEFT = 'left', START_RIGHT = 'right',
	}

	it ('maps navigator commands to System Bridge KEYBOARD_KEYPRESS', function ()
		for cmd, key in pairs (KEYS) do
			local env = online ()
			env.ReceivedFromProxy (5001, cmd, {})
			local m = env.lastSent ()
			check.eq (m.event, 'KEYBOARD_KEYPRESS', cmd)
			check.eq (m.data.key, key, cmd)
			check.eq (m.data.delay, 0, cmd)
		end
	end)

	it ('STOP_* releases send nothing on the keyboard path', function ()
		local env = online ()
		for _, c in ipairs ({ 'STOP_UP', 'STOP_DOWN', 'STOP_LEFT', 'STOP_RIGHT' }) do
			env.ReceivedFromProxy (5001, c, {})
		end
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('MENU / HOME launch Big Picture; GUIDE the library; SETTINGS settings', function ()
		local expected = { MENU = 'steam://open/bigpicture', HOME = 'steam://open/bigpicture',
			GUIDE = 'steam://open/games', SETTINGS = 'steam://open/settings' }
		for cmd, uri in pairs (expected) do
			local env = online ()
			env.ReceivedFromProxy (5001, cmd, {})
			check.eq (env.lastSent ().event, 'OPEN', cmd)
			check.eq (env.lastSent ().data.url, uri, cmd)
		end
	end)

	it ('transport commands map to MEDIA_CONTROL', function ()
		local expected = { PLAY = 'PLAY', PAUSE = 'PAUSE', STOP = 'STOP', SKIP_FWD = 'NEXT', SKIP_REV = 'PREVIOUS',
			SCAN_FWD = 'NEXT', SCAN_REV = 'PREVIOUS', START_SCAN_FWD = 'NEXT', START_SCAN_REV = 'PREVIOUS' }
		for cmd, action in pairs (expected) do
			local env = online ()
			env.ReceivedFromProxy (5001, cmd, {})
			check.eq (env.lastSent ().event, 'MEDIA_CONTROL', cmd)
			check.eq (env.lastSent ().data.action, action, cmd)
		end
	end)

	it ('PASSTHROUGH unwraps PASSTHROUGH_COMMAND and strips it from the params', function ()
		local env = online ()
		local params = { PASSTHROUGH_COMMAND = 'ENTER', ROOM_ID = '3' }
		env.ReceivedFromProxy (5001, 'PASSTHROUGH', params)
		check.eq (env.lastSent ().data.key, 'enter')
		check.is_nil (params.PASSTHROUGH_COMMAND)
	end)

	it ('PASSTHROUGH also works on the switcher proxy', function ()
		local env = online ()
		env.ReceivedFromProxy (5002, 'PASSTHROUGH', { PASSTHROUGH_COMMAND = 'PAUSE' })
		check.eq (env.lastSent ().data.action, 'PAUSE')
	end)

	it ('unknown commands are ignored harmlessly', function ()
		local env = online ()
		env.ReceivedFromProxy (5001, 'DANCE', {})
		env.ReceivedFromProxy (5002, 'DANCE', {})
		env.ReceivedFromProxy (9999, 'UP', {})
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('switcher ON/OFF are housekeeping only', function ()
		local env = online ()
		env.ReceivedFromProxy (5002, 'ON', {})
		env.ReceivedFromProxy (5002, 'OFF', {})
		check.eq (#env.g_ws.sent, 0)
		check.deep_eq (eventsFired (env), {})
	end)
end)

describe ('proxy commands: Gamepad Bridge backend', function ()
	it ('presses map to c4pad_press_* allowlist commands', function ()
		local expected = { UP = 'c4pad_press_up', ENTER = 'c4pad_press_a', BACK = 'c4pad_press_b',
			CANCEL = 'c4pad_press_b', EXIT = 'c4pad_press_b', INFO = 'c4pad_press_x', MENU = 'c4pad_press_start',
			GUIDE = 'c4pad_press_guide', PAGE_UP = 'c4pad_press_lb', PAGE_DOWN = 'c4pad_press_rb' }
		for cmd, id in pairs (expected) do
			local env = padMode ()
			env.ReceivedFromProxy (5001, cmd, {})
			local m = env.lastSent ()
			check.eq (m.event, 'COMMAND_EXECUTE', cmd)
			check.eq (m.data.commandID, id, cmd)
		end
	end)

	it ('tracks the request so a COMMAND_NOT_FOUND can degrade it', function ()
		local env = padMode ()
		env.ReceivedFromProxy (5001, 'ENTER', {})
		local id = env.lastSent ().id
		check.eq (env.g_pendingPad [id].cmd, 'ENTER')
	end)

	it ('START_UP holds, refreshes every 2s, and STOP_UP releases + echoes the release', function ()
		local env = padMode ()
		env.ReceivedFromProxy (5001, 'START_UP', {})
		check.eq (env.lastSent ().data.commandID, 'c4pad_hold_up')
		check.eq (env.g_activeHolds.up, 'c4pad_hold_up')
		local refresh = env.timer ('PadHoldRefresh')
		check.eq (refresh.delay, 2000)
		check.eq (refresh.repeating, true)

		env.reset ()
		env.fireTimer ('PadHoldRefresh')
		check.eq (env.lastSent ().data.commandID, 'c4pad_hold_up')

		env.reset ()
		env.ReceivedFromProxy (5001, 'STOP_UP', {})
		check.eq (env.lastSent ().data.commandID, 'c4pad_release_up')
		check.is_nil (env.g_activeHolds.up)
		check.is_nil (env.timer ('PadHoldRefresh'))
		check.eq (env.timer ('PadEchoRelease_up').delay, 200)

		env.reset ()
		env.fireTimer ('PadEchoRelease_up')
		check.eq (env.lastSent ().data.commandID, 'c4pad_release_up')
	end)

	it ('SETTINGS / HOME have no pad mapping and fall through to the steam:// path', function ()
		local env = padMode ()
		env.ReceivedFromProxy (5001, 'SETTINGS', {})
		check.eq (env.lastSent ().event, 'OPEN')
		check.eq (env.lastSent ().data.url, 'steam://open/settings')
	end)

	it ('media keys still use MEDIA_CONTROL in pad mode', function ()
		local env = padMode ()
		env.ReceivedFromProxy (5001, 'PLAY', {})
		check.eq (env.lastSent ().event, 'MEDIA_CONTROL')
	end)

	it ('SBPad returns false for commands it does not own', function ()
		local env = padMode ()
		check.eq (env.SBPad ('PLAY'), false)
		check.eq (#env.g_ws.sent, 0)
	end)
end)

describe ('EC: Send Keyboard Key (input sanitization)', function ()
	it ('accepts real robotgo tokens, lowercased', function ()
		for input, expected in pairs ({ A = 'a', ['F1'] = 'f1', Enter = 'enter', audio_vol_up = 'audio_vol_up',
			['num.'] = 'num.', ['num+'] = 'num+', lights_kbd_toggle = 'lights_kbd_toggle', ['  space '] = 'space' }) do
			local env = online ()
			env.ExecuteCommand ('Send Keyboard Key', { KEY = input })
			check.eq (env.lastSent () and env.lastSent ().data.key, expected, input)
		end
	end)

	it ('rejects anything with shell/JSON metacharacters, spaces or newlines', function ()
		for _, bad in ipairs ({ 'a;b', '$(reboot)', 'a b', '"x"', "a'b", 'a\nb', '`id`', 'a|b', 'a&&b',
			'<script>', 'a\\b', 'key=1', '' }) do
			local env = online ()
			env.ExecuteCommand ('Send Keyboard Key', { KEY = bad })
			check.eq (#env.g_ws.sent, 0, string.format ('%q', bad))
		end
	end)

	it ('rejects tokens longer than 24 characters', function ()
		local env = online ()
		env.ExecuteCommand ('Send Keyboard Key', { KEY = string.rep ('a', 25) })
		check.eq (#env.g_ws.sent, 0)
		env.ExecuteCommand ('Send Keyboard Key', { KEY = string.rep ('a', 24) })
		check.eq (#env.g_ws.sent, 1)
	end)

	it ('a missing KEY param is harmless', function ()
		local env = online ()
		env.ExecuteCommand ('Send Keyboard Key', {})
		check.eq (#env.g_ws.sent, 0)
	end)
end)

describe ('EC: programming commands', function ()
	it ('power commands map to the System Bridge power events', function ()
		local expected = { Sleep = 'POWER_SLEEP', ['Shut Down'] = 'POWER_SHUTDOWN', Restart = 'POWER_RESTART',
			Lock = 'POWER_LOCK' }
		for cmd, event in pairs (expected) do
			local env = online ()
			env.ExecuteCommand (cmd)
			check.eq (env.lastSent ().event, event, cmd)
		end
	end)

	it ('media commands map to MEDIA_CONTROL actions', function ()
		local expected = { ['Media Play Pause'] = 'PLAY', ['Media Next'] = 'NEXT', ['Media Previous'] = 'PREVIOUS',
			['Media Stop'] = 'STOP', ['Media Volume Up'] = 'VOLUME_UP', ['Media Volume Down'] = 'VOLUME_DOWN',
			['Media Mute'] = 'MUTE' }
		for cmd, action in pairs (expected) do
			local env = online ()
			env.ExecuteCommand (cmd)
			check.eq (env.lastSent ().data.action, action, cmd)
		end
	end)

	it ('LUA_ACTION routes the ACTION name to the same handler', function ()
		local env = online ()
		env.ExecuteCommand ('LUA_ACTION', { ACTION = 'Restart' })
		check.eq (env.lastSent ().event, 'POWER_RESTART')
	end)

	it ('spaces in command names are normalized to underscores', function ()
		local env = online ()
		env.ExecuteCommand ('Send Test Notification')
		check.eq (env.lastSent ().event, 'NOTIFICATION')
		check.eq (env.lastSent ().data.title, 'Control4')
	end)

	it ('an unknown command does nothing and does not throw', function ()
		local env = online ()
		env.ExecuteCommand ('Definitely Not A Command')
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('Send Notification defaults the title and mirrors it into an empty message', function ()
		local env = online ()
		env.ExecuteCommand ('Send Notification', { TITLE = '', MESSAGE = '' })
		check.deep_eq (env.lastSent ().data, { title = 'Control4', message = 'Control4' })
		env.ExecuteCommand ('Send Notification', { TITLE = ' Hi ', MESSAGE = '' })
		check.deep_eq (env.lastSent ().data, { title = 'Hi', message = 'Hi' })
		env.ExecuteCommand ('Send Notification', { TITLE = 'T', MESSAGE = ' body ' })
		check.deep_eq (env.lastSent ().data, { title = 'T', message = 'body' })
	end)

	it ('Launch Big Picture goes through the allowlisted LaunchURI', function ()
		local env = online ()
		env.ExecuteCommand ('Launch Big Picture')
		check.eq (env.lastSent ().data.url, 'steam://open/bigpicture')
	end)

	it ('Launch Steam Game: numeric app id becomes steam://rungameid/<id>', function ()
		local env = online ()
		env.ExecuteCommand ('Launch Steam Game', { APP_ID = ' 620 ' })
		check.eq (env.lastSent ().data.url, 'steam://rungameid/620')
	end)

	it ('Launch Steam Game: a full steam:// URI is accepted', function ()
		local env = online ()
		env.ExecuteCommand ('Launch Steam Game', { APP_ID = 'steam://nav/games' })
		check.eq (env.lastSent ().data.url, 'steam://nav/games')
	end)

	it ('Launch Steam Game / Open URI: non-steam URIs and junk never reach System Bridge', function ()
		for _, bad in ipairs ({ 'file:///etc/passwd', 'https://example.com', 'abc', '620; rm -rf /', '12 34', '../x' }) do
			local env = online ()
			env.ExecuteCommand ('Launch Steam Game', { APP_ID = bad })
			env.ExecuteCommand ('Open URI', { URI = bad })
			check.eq (#env.g_ws.sent, 0, bad)
		end
	end)

	it ('Open URI forwards a steam:// URI', function ()
		local env = online ()
		env.ExecuteCommand ('Open URI', { URI = 'steam://open/settings' })
		check.eq (env.lastSent ().data.url, 'steam://open/settings')
	end)

	it ('empty or missing APP_ID is a no-op', function ()
		local env = online ()
		env.ExecuteCommand ('Launch Steam Game', { APP_ID = '' })
		env.ExecuteCommand ('Launch Steam Game', {})
		check.eq (#env.g_ws.sent, 0)
	end)
end)

describe ('EC: Press Gamepad Button', function ()
	local BUTTONS = { ['A'] = 'a', ['B'] = 'b', ['X'] = 'x', ['Y'] = 'y', ['D-Pad Up'] = 'up',
		['D-Pad Down'] = 'down', ['D-Pad Left'] = 'left', ['D-Pad Right'] = 'right', ['LB'] = 'lb',
		['RB'] = 'rb', ['Start'] = 'start', ['Select'] = 'select', ['Guide (Steam)'] = 'guide' }

	it ('every dropdown button maps to its c4pad_press_<token> command', function ()
		for button, token in pairs (BUTTONS) do
			local env = online ()
			env.ExecuteCommand ('Press Gamepad Button', { BUTTON = button })
			check.eq (env.lastSent ().data.commandID, 'c4pad_press_' .. token, button)
		end
	end)

	it ('an unknown button name sends nothing (no injection into the commandID)', function ()
		local env = online ()
		env.ExecuteCommand ('Press Gamepad Button', { BUTTON = 'a; reboot' })
		env.ExecuteCommand ('Press Gamepad Button', { BUTTON = '../../x' })
		env.ExecuteCommand ('Press Gamepad Button', {})
		check.eq (#env.g_ws.sent, 0)
	end)
end)

describe ('colored (RGBY) buttons -> Steam actions', function ()
	local ACTION_TO_PAD = {
		['Steam Menu'] = 'c4pad_steam', ['Quick Access Menu'] = 'c4pad_qam',
		['Toggle On-Screen Keyboard'] = 'c4pad_osk', ['Screenshot'] = 'c4pad_screenshot',
		['Toggle Magnifier'] = 'c4pad_magnifier', ['Force Quit Game'] = 'c4pad_forcequit',
	}

	it ('ship with the documented defaults', function ()
		local expected = { Red = 'c4pad_steam', Green = 'c4pad_qam', Yellow = 'c4pad_osk', Blue = 'c4pad_screenshot' }
		for color, id in pairs (expected) do
			local env = online ()
			env.ExecuteCommand (color .. ' Button')
			check.eq (env.lastSent ().event, 'COMMAND_EXECUTE', color)
			check.eq (env.lastSent ().data.commandID, id, color)
		end
	end)

	it ('every pad-backed action works on every color', function ()
		for _, color in ipairs ({ 'Red', 'Green', 'Yellow', 'Blue' }) do
			for action, id in pairs (ACTION_TO_PAD) do
				local env = online ()
				env.Properties [color .. ' Button Action'] = action
				env.ExecuteCommand (color .. ' Button')
				check.eq (env.lastSent ().data.commandID, id, color .. '/' .. action)
			end
		end
	end)

	it ('Launch Big Picture and Media Play/Pause go straight over System Bridge', function ()
		local env = online ()
		env.Properties ['Red Button Action'] = 'Launch Big Picture'
		env.ExecuteCommand ('Red Button')
		check.eq (env.lastSent ().event, 'OPEN')
		check.eq (env.lastSent ().data.url, 'steam://open/bigpicture')
		env.Properties ['Blue Button Action'] = 'Media Play/Pause'
		env.ExecuteCommand ('Blue Button')
		check.eq (env.lastSent ().event, 'MEDIA_CONTROL')
		check.eq (env.lastSent ().data.action, 'PLAY')
	end)

	it ('None does nothing', function ()
		local env = online ()
		env.Properties ['Green Button Action'] = 'None'
		env.ExecuteCommand ('Green Button')
		check.eq (#env.g_ws.sent, 0)
		check.deep_eq (eventsFired (env), {})
	end)

	it ('Fire Programming Event raises "<Color> Button Pressed" and sends nothing', function ()
		for _, color in ipairs ({ 'Red', 'Green', 'Yellow', 'Blue' }) do
			local env = online ()
			env.Properties [color .. ' Button Action'] = 'Fire Programming Event'
			env.ExecuteCommand (color .. ' Button')
			check.deep_eq (eventsFired (env), { color .. ' Button Pressed' }, color)
			check.eq (#env.g_ws.sent, 0, color)
		end
	end)

	it ('an unrecognized action value is logged, not sent', function ()
		local env = online ()
		env.Properties ['Red Button Action'] = 'Format C:'
		env.ExecuteCommand ('Red Button')
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('standalone Steam action commands map to the same c4pad ids', function ()
		local cmds = { ['Steam Menu'] = 'c4pad_steam', ['Quick Access Menu'] = 'c4pad_qam',
			['Toggle On-Screen Keyboard'] = 'c4pad_osk', ['Screenshot'] = 'c4pad_screenshot',
			['Toggle Magnifier'] = 'c4pad_magnifier', ['Force Quit Game'] = 'c4pad_forcequit' }
		for cmd, id in pairs (cmds) do
			local env = online ()
			env.ExecuteCommand (cmd)
			check.eq (env.lastSent ().data.commandID, id, cmd)
		end
	end)

	it ('the c4pad chord requests are tracked for the missing-entry fallback', function ()
		local env = online ()
		env.ExecuteCommand ('Steam Menu')
		check.truthy (env.g_pendingPad [env.lastSent ().id])
	end)
end)

describe ('mini app launch via the switcher (SET_INPUT)', function ()
	-- topology: our switcher proxy (binding 5002) is consumed by proxy device 200;
	-- 200's input 3101 is provided by mini proxy 300, whose protocol device is 301
	local function wire (env, vars, opts)
		opts = opts or {}
		env.c4.override ('GetBoundConsumerDevices', function (_, deviceId, binding)
			if (deviceId == 100 and binding == 5002) then return { [200] = 'proxy' } end
			return {}
		end)
		env.c4.override ('GetBoundProviderDevice', function (_, deviceId, binding)
			if (deviceId == 200 and binding == 3101) then return opts.noApp and 0 or 300 end
			if (deviceId == 300 and binding == 5001) then return opts.noProtocol and 0 or 301 end
			return 0
		end)
		env.c4.override ('GetDeviceVariables', function (_, deviceId)
			if (deviceId == 301 or (opts.noProtocol and deviceId == 300)) then return vars end
			return {}
		end)
	end

	it ('launches the steam:// URI the mini published and shows its name', function ()
		local env = online ()
		wire (env, { { name = 'APP_NAME', value = 'Portal 2' }, { name = 'UM_STEAM_MACHINE', value = 'steam://rungameid/620' } })
		env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '3101' })
		check.eq (env.lastSent ().data.url, 'steam://rungameid/620')
		check.eq (env.Variables.CURRENT_GAME, 'Portal 2')
	end)

	it ('a hostile mini publishing file:// or https:// is blocked by the allowlist', function ()
		for _, evil in ipairs ({ 'file:///etc/passwd', 'https://evil.example', 'smb://x/y' }) do
			local env = online ()
			wire (env, { { name = 'APP_NAME', value = 'Evil' }, { name = 'UM_STEAM_MACHINE', value = evil } })
			env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '3101' })
			check.eq (#env.g_ws.sent, 0, evil)
			check.eq (env.Variables.CURRENT_GAME, '', evil)
		end
	end)

	it ('falls back to APP_ID when UM_STEAM_MACHINE is absent', function ()
		local env = online ()
		wire (env, { { name = 'APP_ID', value = 'steam://rungameid/70' } })
		env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '3101' })
		check.eq (env.lastSent ().data.url, 'steam://rungameid/70')
	end)

	it ('does nothing when the mini has not published a URI', function ()
		local env = online ()
		wire (env, { { name = 'APP_NAME', value = 'Blank' }, { name = 'UM_STEAM_MACHINE', value = '  ' } })
		env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '3101' })
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('does nothing when no mini is bound to that input', function ()
		local env = online ()
		wire (env, {}, { noApp = true })
		env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '3101' })
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('uses the mini proxy itself when it has no protocol-device binding', function ()
		local env = online ()
		wire (env, { { name = 'UM_STEAM_MACHINE', value = 'steam://open/games' } }, { noProtocol = true })
		env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '3101' })
		check.eq (env.lastSent ().data.url, 'steam://open/games')
	end)

	it ('only inputs 3101..3125 are mini-app inputs', function ()
		local env = online ()
		wire (env, { { name = 'UM_STEAM_MACHINE', value = 'steam://open/games' } })
		for _, input in ipairs ({ '3100', '3126', '0', 'abc', '' }) do
			env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = input })
		end
		check.eq (#env.g_ws.sent, 0)
		env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '3125' })
		-- 3125 is in range, but nothing is bound there in this topology -> still nothing
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('launching while asleep queues the URI and wakes the machine', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('MAC Address', 'AA:BB:CC:DD:EE:FF')
		wire (env, { { name = 'UM_STEAM_MACHINE', value = 'steam://rungameid/620' } })
		env.reset ()
		env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '3101' })
		check.eq (env.g_pendingLaunch, 'steam://rungameid/620')
		check.eq (env.c4.count ('SendWOL'), 1)
	end)
end)
