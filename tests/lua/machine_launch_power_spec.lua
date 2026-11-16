-- steam-machine: LaunchURI allowlist, QueueLaunch while asleep, PowerOn / PowerOff
local H = require ('c4_mock')

local function online ()
	local env = H.machine ()
	env.goOnline ()
	return env
end

-- machine that is configured but asleep (socket never authenticated)
local function asleep (mac)
	local env = H.machine ()
	env.boot ('192.168.1.50')
	env.setProperty ('System Bridge Token', 'tk')
	if (mac) then env.setProperty ('MAC Address', mac) end
	env.reset ()
	return env
end

local function wolCalls (env)
	return env.c4.of ('SendWOL')
end

local function eventsFired (env)
	local out = {}
	for _, a in ipairs (env.c4.of ('FireEvent')) do out [#out + 1] = a [1] end
	return out
end

describe ('LaunchURI: steam:// allowlist', function ()
	local REJECTED = {
		'file:///home/deck/.config/systembridge/token',
		'FILE:///etc/passwd',
		'https://evil.example/steam://x',
		'http://example.com',
		'javascript:alert(1)',
		'/etc/passwd',
		'steam:/open/bigpicture',
		'steam//open/games',
		'steam+evil://run',
		'ssh://attacker/x',
		'smb://share/payload.desktop',
		'x-scheme-handler/steam',
		'://nothing',
		'  \t ',
	}

	it ('rejects every non-steam scheme and malformed URI: nothing is sent or changed', function ()
		for _, uri in ipairs (REJECTED) do
			local env = online ()
			env.LaunchURI (uri, 'Evil Game')
			check.eq (#env.g_ws.sent, 0, 'sent for ' .. uri)
			check.eq (env.Variables.CURRENT_GAME, '', uri)
			check.is_nil (env.g_pendingLaunch, uri)
			check.eq (env.c4.count ('SendWOL'), 0, uri)
		end
	end)

	it ('rejected URIs while offline neither queue nor wake the machine', function ()
		local env = asleep ('AA:BB:CC:DD:EE:FF')
		env.LaunchURI ('file:///etc/shadow')
		check.is_nil (env.g_pendingLaunch)
		check.eq (#wolCalls (env), 0)
		check.deep_eq (eventsFired (env), {})
	end)

	it ('accepts steam:// and sends OPEN with the url', function ()
		local env = online ()
		env.LaunchURI ('steam://rungameid/620', 'Portal 2')
		local m = env.lastSent ()
		check.eq (m.event, 'OPEN')
		check.eq (m.data.url, 'steam://rungameid/620')
		check.eq (env.Variables.CURRENT_GAME, 'Portal 2')
	end)

	it ('scheme match is case-insensitive', function ()
		local env = online ()
		env.LaunchURI ('STEAM://open/games')
		check.eq (env.lastSent ().event, 'OPEN')
	end)

	it ('trims surrounding whitespace before checking', function ()
		local env = online ()
		env.LaunchURI ('  steam://open/settings\n')
		check.eq (env.lastSent ().data.url, 'steam://open/settings')
	end)

	it ('empty URI is a no-op', function ()
		local env = online ()
		env.LaunchURI ('')
		env.LaunchURI (nil)
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('CURRENT_GAME falls back to the URI and is sanitized', function ()
		local env = online ()
		env.LaunchURI ('steam://rungameid/10')
		check.eq (env.Variables.CURRENT_GAME, 'steam://rungameid/10')
		env.LaunchURI ('steam://rungameid/10', 'Evil\nName\0')
		check.eq (env.Variables.CURRENT_GAME, 'Evil Name ')
		env.LaunchURI ('steam://rungameid/10', string.rep ('N', 999))
		check.eq (#env.Variables.CURRENT_GAME, 256)
	end)

	it ('a game launch cancels a pending deferred sleep', function ()
		local env = online ()
		env.PowerOff ()
		check.truthy (env.timer ('DeferredOff'))
		env.LaunchURI ('steam://rungameid/620')
		check.is_nil (env.timer ('DeferredOff'))
	end)
end)

describe ('LaunchURI while the machine is asleep', function ()
	it ('queues the launch, wakes via WOL and turns the machine on', function ()
		local env = asleep ('AA:BB:CC:DD:EE:FF')
		env.LaunchURI ('steam://rungameid/620', 'Portal 2')
		check.eq (env.g_pendingLaunch, 'steam://rungameid/620')
		check.eq (#wolCalls (env), 1)
		check.eq (wolCalls (env) [1] [1], 'AA:BB:CC:DD:EE:FF')
		check.eq (#env.g_ws.sent, 0)
		check.deep_eq (eventsFired (env), { 'Turned On' })
	end)

	it ('flushes the queued launch exactly once when System Bridge authenticates', function ()
		local env = asleep ('AA:BB:CC:DD:EE:FF')
		env.LaunchURI ('steam://rungameid/620')
		env.g_ws:establish ()
		env.reset ()
		env.rx ({ type = 'DATA_UPDATE', module = 'cpu', data = {} })
		local sent = env.sent ()
		check.eq (#sent, 1)
		check.eq (sent [1].event, 'OPEN')
		check.eq (sent [1].data.url, 'steam://rungameid/620')
		check.is_nil (env.g_pendingLaunch)
		check.is_nil (env.timer ('PendingLaunch'))
		env.rx ({ type = 'DATA_UPDATE', module = 'cpu', data = {} })
		check.eq (#env.sent (), 1)
	end)

	it ('the queued launch expires after 120s (resume from sleep)', function ()
		local env = asleep ()
		env.QueueLaunch ('steam://open/games')
		check.eq (env.timer ('PendingLaunch').delay, 120000)
		env.fireTimer ('PendingLaunch')
		check.is_nil (env.g_pendingLaunch)
	end)

	it ('the queue window is 300s when Off Mode is Power Off (cold boot)', function ()
		local env = asleep ()
		env.Properties ['Off Mode'] = 'Power Off'
		env.QueueLaunch ('steam://open/games')
		check.eq (env.timer ('PendingLaunch').delay, 300000)
	end)

	it ('a newer queued launch replaces the older one', function ()
		local env = asleep ()
		env.QueueLaunch ('steam://rungameid/1')
		env.QueueLaunch ('steam://rungameid/2')
		check.eq (env.g_pendingLaunch, 'steam://rungameid/2')
	end)

	it ('PowerOff discards a queued launch', function ()
		local env = asleep ()
		env.QueueLaunch ('steam://rungameid/1')
		env.PowerOff ()
		check.is_nil (env.g_pendingLaunch)
		check.is_nil (env.timer ('PendingLaunch'))
	end)
end)

describe ('PowerOn', function ()
	it ('sends WOL immediately and re-sends at 2s and 5s', function ()
		local env = asleep ('AA:BB:CC:DD:EE:FF')
		env.PowerOn (false)
		check.eq (#wolCalls (env), 1)
		check.eq (env.timer ('WOL2').delay, 2000)
		check.eq (env.timer ('WOL3').delay, 5000)
		env.fireTimer ('WOL2')
		env.fireTimer ('WOL3')
		check.eq (#wolCalls (env), 3)
		for _, c in ipairs (wolCalls (env)) do check.eq (c [1], 'AA:BB:CC:DD:EE:FF') end
	end)

	it ('without a MAC there is no WOL and no WOL timers', function ()
		local env = asleep ()
		env.PowerOn (false)
		check.eq (#wolCalls (env), 0)
		check.is_nil (env.timer ('WOL2'))
	end)

	it ('fires Turned On and notifies the proxy ON exactly once', function ()
		local env = asleep ()
		env.PowerOn (false)
		env.PowerOn (false)
		check.deep_eq (eventsFired (env), { 'Turned On', 'Turned On' })
		local n = env.c4.of ('SendToProxy')
		check.eq (#n, 1)
		check.eq (n [1] [2], 'ON')
		check.eq (n [1] [4], 'NOTIFY')
	end)

	it ('cancels a pending deferred off', function ()
		local env = online ()
		env.PowerOff ()
		env.PowerOn (false)
		check.is_nil (env.timer ('DeferredOff'))
	end)

	it ('resets the reconnect backoff so it re-attaches promptly', function ()
		local env = asleep ()
		env.g_reconnectDelay = 60
		env.PowerOn (false)
		check.eq (env.g_reconnectDelay, 5)
		check.eq (env.timer ('Reconnect').delay, 5000)
	end)

	it ('opens Big Picture right away when online and enabled', function ()
		local env = online ()
		env.Properties ['Launch Into Big Picture'] = 'On'
		env.PowerOn (true)
		check.eq (env.lastSent ().event, 'OPEN')
		check.eq (env.lastSent ().data.url, 'steam://open/bigpicture')
	end)

	it ('queues Big Picture when offline and enabled', function ()
		local env = asleep ()
		env.Properties ['Launch Into Big Picture'] = 'On'
		env.PowerOn (true)
		check.eq (env.g_pendingLaunch, 'steam://open/bigpicture')
	end)

	it ('does nothing extra when Launch Into Big Picture is Off', function ()
		local env = online ()
		env.Properties ['Launch Into Big Picture'] = 'Off'
		env.PowerOn (true)
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('allowBigPicture=false never launches Big Picture', function ()
		local env = online ()
		env.PowerOn (false)
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('suppresses Big Picture within 15s of a game launch', function ()
		local env = online ()
		env.LaunchURI ('steam://rungameid/620')
		env.reset ()
		env.PowerOn (true)
		check.eq (#env.g_ws.sent, 0)
		env.g_lastGameLaunch = os.time () - 60
		env.PowerOn (true)
		check.eq (env.lastSent ().data.url, 'steam://open/bigpicture')
	end)

	it ('the ON proxy command powers on and launches Big Picture', function ()
		local env = online ()
		env.ReceivedFromProxy (5001, 'ON', {})
		check.eq (env.lastSent ().data.url, 'steam://open/bigpicture')
	end)

	it ('the Power On programming command also honours Big Picture', function ()
		local env = online ()
		env.ExecuteCommand ('Power On')
		check.eq (env.lastSent ().data.url, 'steam://open/bigpicture')
	end)
end)

describe ('PowerOff / Off Mode', function ()
	it ('is debounced: nothing is sent until the 5s timer fires', function ()
		local env = online ()
		env.PowerOff ()
		check.eq (#env.g_ws.sent, 0)
		check.eq (env.timer ('DeferredOff').delay, 5000)
		env.fireTimer ('DeferredOff')
		check.eq (env.lastSent ().event, 'POWER_SLEEP')
	end)

	it ('Off Mode = Power Off sends POWER_SHUTDOWN', function ()
		local env = online ()
		env.Properties ['Off Mode'] = 'Power Off'
		env.PowerOff (true)
		check.eq (env.lastSent ().event, 'POWER_SHUTDOWN')
	end)

	it ('Off Mode = Do Nothing sends nothing', function ()
		local env = online ()
		env.Properties ['Off Mode'] = 'Do Nothing'
		env.PowerOff (true)
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('immediate mode sends straight away and fires Turned Off + proxy OFF', function ()
		local env = online ()
		env.PowerOff (true)
		check.eq (env.lastSent ().event, 'POWER_SLEEP')
		check.deep_eq (eventsFired (env), { 'Turned Off' })
		check.eq (env.c4.of ('SendToProxy') [1] [2], 'OFF')
	end)

	it ('a SET_INPUT arriving inside the window cancels the pending sleep', function ()
		local env = online ()
		env.ReceivedFromProxy (5001, 'OFF', {})
		check.truthy (env.timer ('DeferredOff'))
		env.ReceivedFromProxy (5002, 'SET_INPUT', { INPUT = '9999' })
		check.is_nil (env.timer ('DeferredOff'))
	end)

	it ('the EC Power Off command is immediate (no debounce)', function ()
		local env = online ()
		env.ExecuteCommand ('Power Off')
		check.eq (env.lastSent ().event, 'POWER_SLEEP')
		check.is_nil (env.timer ('DeferredOff'))
	end)

	it ('while disconnected the deferred off sends nothing (and does not throw)', function ()
		local env = asleep ()
		env.PowerOff ()
		env.fireTimer ('DeferredOff')
		check.eq (#env.g_ws.sent, 0)
	end)
end)
