-- steam-machine: connection config (ws vs wss), reconnect/backoff, staleness, SBSend message shape
local H = require ('c4_mock')

local PEM = '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----'

describe ('ConnectionConfig', function ()
	it ('plaintext mode -> ws://ip:9170, no TLS options', function ()
		local env = H.machine ()
		env.g_ip = '10.1.2.3'
		local url, opts = env.ConnectionConfig ()
		check.eq (url, 'ws://10.1.2.3:9170/api/websocket')
		check.is_nil (opts)
		check.is_nil (env.g_effectiveVerify)
	end)

	it ('TLS encrypt-only -> wss on the TLS port with VERIFY_MODE none', function ()
		local env = H.machine ()
		env.g_ip = '10.1.2.3'
		env.g_secMode = 'TLS encrypt-only (wss://)'
		local url, opts = env.ConnectionConfig ()
		check.eq (url, 'wss://10.1.2.3:9171/api/websocket')
		check.deep_eq (opts, { VERIFY_MODE = 'none' })
		check.eq (env.g_effectiveVerify, 'none')
	end)

	it ('TLS pinned with a cert -> VERIFY_MODE peer + CACERTFILE', function ()
		local env = H.machine ()
		env.g_ip = '10.1.2.3'
		env.g_secMode = 'TLS pinned (wss://)'
		env.g_caReady = true
		local url, opts = env.ConnectionConfig ()
		check.eq (url, 'wss://10.1.2.3:9171/api/websocket')
		check.deep_eq (opts, { VERIFY_MODE = 'peer', CACERTFILE = './c4tls_ca.pem' })
		check.eq (env.g_effectiveVerify, 'peer')
	end)

	it ('TLS pinned without a cert downgrades visibly (none-fallback), not silently', function ()
		local env = H.machine ()
		env.g_ip = '10.1.2.3'
		env.g_secMode = 'TLS pinned (wss://)'
		env.g_caReady = false
		local _, opts = env.ConnectionConfig ()
		check.deep_eq (opts, { VERIFY_MODE = 'none' })
		check.eq (env.g_effectiveVerify, 'none-fallback')
	end)

	it ('an unknown security value fails to plaintext config', function ()
		local env = H.machine ()
		env.g_ip = '10.1.2.3'
		env.g_secMode = 'something else'
		local url = env.ConnectionConfig ()
		check.matches (url, '^ws://')
	end)

	it ('Connect passes the TLS options to WebSocket:new and starts the socket', function ()
		local env = H.machine ()
		env.c4.addr [6001] = '10.9.8.7'
		env.Properties ['Connection Security'] = 'TLS pinned (wss://)'
		env.boot ('10.9.8.7')
		env.setProperty ('Server Certificate', PEM)
		check.eq (env.g_ws.url, 'wss://10.9.8.7:9171/api/websocket')
		check.eq (env.g_ws.options.VERIFY_MODE, 'peer')
		check.eq (env.g_ws.options.CACERTFILE, './c4tls_ca.pem')
		check.eq (env.g_ws.starts, 1)
		check.contains (env.Properties ['Network Connection'], 'Connecting to 10.9.8.7')
	end)

	it ('the REAL websocket lib opens an SSL connection with the verify options for wss', function ()
		local env = H.machine ({ realWebSocket = true })
		env.boot ('')
		env.c4.addr [6001] = '10.0.0.5'
		env.setProperty ('Connection Security', 'TLS encrypt-only (wss://)')
		-- RefreshAddress is what picks the address up
		env.RefreshAddress ()
		local created = env.c4.of ('CreateNetworkConnection') [1]
		check.truthy (created, 'no network connection created')
		check.eq (created [2], '10.0.0.5')
		check.eq (created [3], 'SSL')
		local opts = env.c4.of ('NetPortOptions') [1]
		check.eq (opts [2], 9171)
		check.eq (opts [3], 'SSL')
		check.eq (opts [4].VERIFY_MODE, 'none')
	end)

	it ('the REAL websocket lib uses a plain TCP connection (no SSL) for ws', function ()
		local env = H.machine ({ realWebSocket = true })
		env.boot ('')
		env.c4.addr [6001] = '10.0.0.5'
		env.RefreshAddress ()
		local created = env.c4.of ('CreateNetworkConnection') [1]
		check.eq (created [2], '10.0.0.5')
		check.is_nil (created [3])
		check.eq (env.c4.count ('NetPortOptions'), 0)
	end)
end)

describe ('RefreshAddress', function ()
	it ('connects to the address entered in the Network binding', function ()
		local env = H.machine ()
		env.boot ('  192.168.1.50 ')
		check.eq (env.g_ip, '192.168.1.50')
		check.eq (env.g_ws.url, 'ws://192.168.1.50:9170/api/websocket')
	end)

	it ('is idempotent for an unchanged address', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.RefreshAddress ()
		check.eq (#env.c4.sockets, 1)
	end)

	it ('re-targets when the address changes and discards the old socket', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		local old = env.g_ws
		env.c4.addr [6001] = '192.168.1.99'
		env.OnNetworkBindingChanged (6001, true)
		check.truthy (old.deleted)
		check.eq (env.g_ws.url, 'ws://192.168.1.99:9170/api/websocket')
	end)

	it ('ignores other bindings changing', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.c4.addr [6001] = '1.1.1.1'
		env.OnNetworkBindingChanged (5001, true)
		check.eq (env.g_ip, '192.168.1.50')
	end)

	it ('clearing the address tears the connection down', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.c4.addr [6001] = ''
		env.OnNetworkBindingChanged (6001, false)
		check.is_nil (env.g_ws)
		check.contains (env.Properties ['Network Connection'], 'No address')
	end)

	it ('an invalid WebSocket URL is reported, not thrown', function ()
		local env = H.machine ()
		env.g_ip = 'x'
		env.WebSocket.new = function () return nil, 'bad url' end
		env.Connect ()
		check.contains (env.Properties ['Network Connection'], 'Error: bad url')
	end)
end)

describe ('socket lifecycle', function ()
	it ('establishing reports the encryption mode in the status', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.g_ws:establish ()
		check.contains (env.Properties ['Network Connection'], 'Online (192.168.1.50:9170, plaintext)')
		check.truthy (env.g_tcpUp)
	end)

	it ('pinned-without-cert is flagged loudly in the status', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('Connection Security', 'TLS pinned (wss://)')
		env.g_ws:establish ()
		check.contains (env.Properties ['Network Connection'], 'PINNED SELECTED BUT NO CERTIFICATE')
		check.contains (env.Properties ['Network Connection'], ':9171')
	end)

	it ('pinned with a cert reports TLS pinned', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('Server Certificate', PEM)
		env.setProperty ('Connection Security', 'TLS pinned (wss://)')
		env.g_ws:establish ()
		check.contains (env.Properties ['Network Connection'], 'TLS pinned')
	end)

	it ('going offline schedules a reconnect with exponential backoff capped at 60s', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.g_ws:establish ()
		local delays = {}
		for _ = 1, 6 do
			env.g_ws:dropOffline ()
			delays [#delays + 1] = env.timer ('Reconnect').delay
			env.fireTimer ('Reconnect')
		end
		check.deep_eq (delays, { 5000, 10000, 20000, 40000, 60000, 60000 })
	end)

	it ('reconnect timer restarts the existing socket', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.g_ws:establish ()
		env.g_ws:dropRemote ()
		local before = env.g_ws.starts
		env.fireTimer ('Reconnect')
		check.eq (env.g_ws.starts, before + 1)
	end)

	it ('a successful (re)connect resets the backoff', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.g_ws:establish ()
		env.g_ws:dropOffline ()
		env.fireTimer ('Reconnect')
		check.eq (env.g_reconnectDelay, 10)
		env.g_ws:establish ()
		check.eq (env.g_reconnectDelay, 5)
		check.is_nil (env.timer ('Reconnect'))
	end)

	it ('going down clears pending pad requests and holds', function ()
		local env = H.machine ()
		env.goOnline ()
		env.g_pendingPad ['x'] = { cmd = 'UP', ts = os.time () }
		env.g_activeHolds.up = 'c4pad_hold_up'
		env.g_ws:dropRemote ()
		check.is_nil (next (env.g_pendingPad))
		check.is_nil (next (env.g_activeHolds))
		check.is_nil (env.timer ('PadHoldRefresh'))
	end)

	it ('goes offline: variable, property, event', function ()
		local env = H.machine ()
		env.goOnline ()
		env.g_ws:dropOffline ()
		check.eq (env.Variables.ONLINE, '0')
		check.eq (env.Properties ['System Bridge Connection'], 'Not connected')
		check.eq (env.c4.of ('FireEvent') [1] [1], 'Went Offline')
		check.contains (env.Properties ['Network Connection'], 'Offline (Offline)')
	end)

	it ('does not claim online before an authenticated response arrives', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('System Bridge Token', 't')
		env.g_ws:establish ()
		check.falsy (env.g_online)
		check.eq (env.Variables.ONLINE, '0')
	end)

	it ('CheckStale restarts a socket that has been silent for > 180s', function ()
		local env = H.machine ()
		env.goOnline ()
		env.g_lastRx = os.time () - 400
		env.CheckStale ()
		check.eq (env.g_ws.starts, 1)
	end)

	it ('CheckStale leaves a recently-active socket alone', function ()
		local env = H.machine ()
		env.goOnline ()
		env.g_lastRx = os.time ()
		env.CheckStale ()
		check.eq (env.g_ws.starts, 0)
	end)

	it ('CheckStale expires pad requests older than 60s', function ()
		local env = H.machine ()
		env.goOnline ()
		env.g_pendingPad.old = { cmd = 'UP', ts = os.time () - 120 }
		env.g_pendingPad.new = { cmd = 'UP', ts = os.time () }
		env.CheckStale ()
		check.is_nil (env.g_pendingPad.old)
		check.truthy (env.g_pendingPad.new)
	end)

	it ('Test Connection restarts the socket and resets backoff', function ()
		local env = H.machine ()
		env.goOnline ()
		env.g_reconnectDelay = 40
		env.ExecuteCommand ('Test Connection')
		check.eq (env.g_reconnectDelay, 5)
		check.eq (env.g_ws.starts, 1)
	end)
end)

describe ('SBSend message shape', function ()
	it ('puts the token in EVERY message', function ()
		local env = H.machine ()
		env.goOnline ('tok-ABC')
		env.ExecuteCommand ('Sleep')
		env.ExecuteCommand ('Media Next')
		env.ExecuteCommand ('Send Test Notification')
		env.ExecuteCommand ('Press Gamepad Button', { BUTTON = 'A' })
		local msgs = env.sent ()
		check.eq (#msgs, 4)
		for _, m in ipairs (msgs) do
			check.eq (m.token, 'tok-ABC', m.event)
		end
	end)

	it ('uses a monotonically increasing id embedding the event name', function ()
		local env = H.machine ()
		env.goOnline ()
		env.ExecuteCommand ('Sleep')
		env.ExecuteCommand ('Restart')
		local m = env.sent ()
		check.matches (m [1].id, '^c4%-%d+%-POWER_SLEEP$')
		check.matches (m [2].id, '^c4%-%d+%-POWER_RESTART$')
		local n1 = tonumber (m [1].id:match ('^c4%-(%d+)%-'))
		local n2 = tonumber (m [2].id:match ('^c4%-(%d+)%-'))
		check.eq (n2, n1 + 1)
		check.eq (m [1].event, 'POWER_SLEEP')
	end)

	it ('SBSend returns the message id on success', function ()
		local env = H.machine ()
		env.goOnline ()
		local id = env.SBSend ('GET_DATA', { modules = { 'cpu' } })
		check.matches (id, '^c4%-%d+%-GET_DATA$')
		check.deep_eq (env.lastSent ().data.modules, { 'cpu' })
	end)

	it ('refuses to send without a token and says so', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.g_ws.running = true
		check.eq (env.SBSend ('POWER_SLEEP', {}), false)
		check.eq (#env.g_ws.sent, 0)
		check.contains (env.Properties ['System Bridge Connection'], 'No token')
	end)

	it ('refuses to send when the socket is not up', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.g_token = 'abc'
		check.eq (env.SBSend ('POWER_SLEEP', {}), false)
		check.eq (#env.g_ws.sent, 0)
	end)

	it ('SBSubscribe re-registers the listeners for all modules on connect', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('System Bridge Token', 'tk')
		env.g_ws:establish ()
		local m = env.sent ()
		check.deep_eq (env.sentEvents (), { 'UNREGISTER_DATA_LISTENER', 'REGISTER_DATA_LISTENER', 'GET_DATA' })
		check.deep_eq (m [2].data.modules, { 'system', 'cpu', 'memory', 'gpus', 'media', 'battery' })
		check.deep_eq (m [3].data.modules, { 'system', 'cpu', 'memory', 'gpus', 'media', 'battery' })
	end)
end)
