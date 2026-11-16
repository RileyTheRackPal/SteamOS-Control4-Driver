-- steam-machine: lifecycle + OPC property handlers (token, MAC, TLS settings, debug)
local H = require ('c4_mock')

local MAC_IN_TOKEN_TESTS = 'AA:BB:CC:DD:EE:FF'

describe ('lifecycle', function ()
	it ('OnDriverInit creates the 12 variables in a stable order', function ()
		local env = H.machine ()
		env.OnDriverInit ()
		local names = {}
		for _, a in ipairs (env.c4.of ('AddVariable')) do names [#names + 1] = a [1] end
		check.deep_eq (names, { 'ONLINE', 'UPTIME_SECONDS', 'UPTIME_TEXT', 'HOSTNAME', 'CPU_TEMPERATURE',
			'GPU_TEMPERATURE', 'CPU_USAGE', 'MEMORY_USED_PERCENT', 'BATTERY_PERCENT', 'NOW_PLAYING',
			'MEDIA_STATUS', 'CURRENT_GAME' })
	end)

	it ('OnDriverInit restores the token from encrypted PersistData', function ()
		local env = H.machine ()
		env.c4.persist.sb_token = { value = 'persisted-secret', encrypted = true }
		env.OnDriverInit ()
		check.eq (env.g_token, 'persisted-secret')
		local reads = env.c4.of ('PersistGetValue')
		check.eq (reads [1] [1], 'sb_token')
		check.eq (reads [1] [2], true, 'token must be read from the ENCRYPTED store')
	end)

	it ('OnDriverInit survives PersistGetValue throwing', function ()
		local env = H.machine ()
		env.c4.override ('PersistGetValue', function () error ('boom') end)
		env.OnDriverInit ()
		check.eq (env.g_token, '')
	end)

	it ('OnDriverLateInit publishes version and token status, arms the stale timer', function ()
		local env = H.machine ()
		env.boot ('')
		check.eq (env.Properties ['Driver Version'], '1.0.0')
		check.eq (env.Properties ['Token Status'], 'Not set')
		check.contains (env.Properties ['Director Connection'], 'v1.0.0')
		local t = env.timer ('StaleCheck')
		check.truthy (t)
		check.eq (t.delay, 60000)
		check.eq (t.repeating, true)
	end)

	it ('OnDriverLateInit reports a stored token as encrypted at rest', function ()
		local env = H.machine ()
		env.c4.persist.sb_token = { value = 'x', encrypted = true }
		env.boot ('')
		check.contains (env.Properties ['Token Status'], 'encrypted')
	end)

	it ('with no network address it reports that and opens no socket', function ()
		local env = H.machine ()
		env.boot ('')
		check.contains (env.Properties ['Network Connection'], 'No address entered')
		check.eq (#env.c4.sockets, 0)
	end)

	it ('OnDriverDestroyed deletes the socket and kills all timers', function ()
		local env = H.machine ()
		env.boot ('10.0.0.5')
		local ws = env.g_ws
		env.OnDriverDestroyed ()
		check.truthy (ws.deleted)
		check.is_nil (env.g_ws)
		check.is_nil (env.Timer ['StaleCheck'])
	end)
end)

describe ('System Bridge Token property', function ()
	it ('moves a new token into the ENCRYPTED PersistData store', function ()
		local env = H.machine ()
		env.boot ('')
		env.setProperty ('System Bridge Token', 'abc123')
		local p = env.c4.persist.sb_token
		check.eq (p.value, 'abc123')
		check.eq (p.encrypted, true)
		check.eq (env.g_token, 'abc123')
	end)

	it ('trims whitespace around the token', function ()
		local env = H.machine ()
		env.boot ('')
		env.setProperty ('System Bridge Token', '   spaced-token \n')
		check.eq (env.g_token, 'spaced-token')
		check.eq (env.c4.persist.sb_token.value, 'spaced-token')
	end)

	it ('blanks the cleartext property so the secret is never persisted in the project', function ()
		local env = H.machine ()
		env.boot ('')
		env.setProperty ('System Bridge Token', 'super-secret')
		check.eq (env.Properties ['System Bridge Token'], '')
		check.contains (env.Properties ['Token Status'], 'Stored')
	end)

	it ('never writes the token into any property, variable, event, log or non-encrypted store', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('System Bridge Token', 'LEAKCANARY-9f8e7d')
		-- debug logging switched on AFTER entry: runtime traffic (which carries the token on the wire)
		-- must never be echoed into logs
		env.setProperty ('Debug Mode', 'Print')
		env.g_ws:establish ()
		env.rx ({ type = 'DATA_UPDATE', module = 'cpu', data = { temperature = 50 } })
		env.rx ({ type = 'ERROR', subtype = 'BAD_TOKEN' })
		env.ExecuteCommand ('Sleep')
		env.ExecuteCommand ('Send Test Notification')
		env.ExecuteCommand ('Test Connection')
		-- the only legitimate home is the encrypted persist call + the websocket frames themselves
		check.not_contains (env.observableText ({ PersistSetValue = true }), 'LEAKCANARY-9f8e7d')
		check.eq (env.c4.of ('PersistSetValue') [1] [3], true)
	end)

	-- Regression: the vendored OnPropertyChanged -> HandlerDebug used to log the pasted
	-- token in cleartext when Debug Mode = Print was on before the token was entered.
	it ('does not log the cleartext token when it is entered with Debug Mode = Print', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('Debug Mode', 'Print')
		env.setProperty ('System Bridge Token', 'LEAKCANARY-debugon')
		check.eq (env.g_token, 'LEAKCANARY-debugon')
		check.not_contains (env.observableText ({ PersistSetValue = true }), 'LEAKCANARY-debugon')
		-- the property change itself is still traced, just redacted
		check.contains (table.concat (env.c4.printed, '\n'), '<redacted>')
	end)

	it ('does not print the token when the token handler throws', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.c4.overrides.PersistSetValue = function () error ('persist store unavailable') end
		env.setProperty ('System Bridge Token', 'LEAKCANARY-handlererr')
		-- logs only (print + C4:DebugLog): the property itself was never blanked because
		-- the handler aborted before that step
		local logs = { table.concat (env.c4.printed, '\n') }
		for _, args in ipairs (env.c4.of ('DebugLog')) do logs [#logs + 1] = tostring (args [1]) end
		check.not_contains (table.concat (logs, '\n'), 'LEAKCANARY-handlererr')
		check.contains (logs [1], 'handler failed')
	end)

	it ('still routes other properties through the common handler', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('Debug Mode', 'Print')
		env.setProperty ('Off Mode', 'Power Off')
		check.contains (table.concat (env.c4.printed, '\n'), 'Power Off')
	end)

	it ('ignores the empty replay so an already-stored token survives OnDriverLateInit', function ()
		local env = H.machine ()
		env.c4.persist.sb_token = { value = 'kept', encrypted = true }
		env.boot ('')
		-- LateInit replays every property (token field is blank) - token must stay
		check.eq (env.g_token, 'kept')
		env.setProperty ('System Bridge Token', '')
		check.eq (env.g_token, 'kept')
	end)

	it ('re-subscribes when a token is entered while the socket is up', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.g_ws.running = true
		env.setProperty ('System Bridge Token', 'newtok')
		local ev = env.sentEvents ()
		check.deep_eq (ev, { 'UNREGISTER_DATA_LISTENER', 'REGISTER_DATA_LISTENER', 'GET_DATA' })
	end)

	it ('Clear Stored Token wipes memory and the encrypted store', function ()
		local env = H.machine ()
		env.boot ('')
		env.setProperty ('System Bridge Token', 'to-be-cleared')
		env.ExecuteCommand ('Clear Stored Token')
		check.eq (env.g_token, '')
		check.eq (env.c4.persist.sb_token.value, '')
		check.eq (env.c4.persist.sb_token.encrypted, true)
		check.eq (env.Properties ['Token Status'], 'Not set')
		check.contains (env.Properties ['System Bridge Connection'], 'No token')
	end)

	it ('DEBUG_WEBSOCKET stays off even in Print debug mode (frames carry the token)', function ()
		local env = H.machine ()
		env.boot ('')
		env.DEBUG_WEBSOCKET = true
		env.setProperty ('Debug Mode', 'Print')
		check.eq (env.DEBUGPRINT, true)
		check.eq (env.DEBUG_WEBSOCKET, false)
		check.eq (env.DEBUG_RFN, false)
		env.setProperty ('Debug Mode', 'Off')
		check.eq (env.DEBUGPRINT, false)
	end)
end)

describe ('MAC Address property', function ()
	it ('normalizes dashes, dots and lowercase to AA:BB:CC:DD:EE:FF', function ()
		for _, input in ipairs ({ 'aa-bb-cc-dd-ee-ff', 'aabb.ccdd.eeff', ' aabbccddeeff ', 'aa:bb:cc:dd:ee:ff' }) do
			local env = H.machine ()
			env.boot ('')
			env.setProperty ('MAC Address', input)
			check.eq (env.g_mac, MAC_IN_TOKEN_TESTS, input)
		end
	end)

	it ('writes the normalized form back to the property', function ()
		local env = H.machine ()
		env.boot ('')
		env.setProperty ('MAC Address', 'aa-bb-cc-dd-ee-ff')
		check.eq (env.Properties ['MAC Address'], MAC_IN_TOKEN_TESTS)
	end)

	it ('rejects malformed input, clears it and disables WOL', function ()
		for _, bad in ipairs ({ 'not-a-mac', 'AA:BB:CC:DD:EE', 'AA:BB:CC:DD:EE:FF:00', 'GG:HH:II:JJ:KK:LL', '12345' }) do
			local env = H.machine ()
			env.boot ('')
			env.setProperty ('MAC Address', bad)
			check.eq (env.g_mac, '', bad)
			check.eq (env.Properties ['MAC Address'], '', bad)
		end
	end)

	it ('blank stays blank without error (re-enables auto-fill)', function ()
		local env = H.machine ()
		env.boot ('')
		env.setProperty ('MAC Address', '')
		check.eq (env.g_mac, '')
		check.eq (env.Properties ['MAC Address'], '')
	end)
end)

describe ('Connection Security / TLS properties', function ()
	it ('Connection Security change rebuilds the socket with the new scheme', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		local first = env.g_ws
		check.eq (first.url, 'ws://192.168.1.50:9170/api/websocket')
		env.setProperty ('Connection Security', 'TLS encrypt-only (wss://)')
		check.truthy (first.deleted)
		check.ne (env.g_ws, first)
		check.eq (env.g_ws.url, 'wss://192.168.1.50:9171/api/websocket')
		check.eq (env.g_secMode, 'TLS encrypt-only (wss://)')
	end)

	it ('TLS Port accepts a valid port and reconnects in TLS mode', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		env.setProperty ('Connection Security', 'TLS encrypt-only (wss://)')
		env.setProperty ('TLS Port', ' 9443 ')
		check.eq (env.g_tlsPort, 9443)
		check.eq (env.g_ws.url, 'wss://192.168.1.50:9443/api/websocket')
	end)

	it ('TLS Port falls back to 9171 for junk or out-of-range values', function ()
		for _, bad in ipairs ({ 'abc', '0', '-5', '65536', '' }) do
			local env = H.machine ()
			env.boot ('')
			env.setProperty ('TLS Port', '8443')
			env.setProperty ('TLS Port', bad)
			check.eq (env.g_tlsPort, 9171, 'value ' .. bad)
		end
	end)

	it ('TLS Port change does not reconnect while in plaintext mode', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		local ws = env.g_ws
		env.setProperty ('TLS Port', '9443')
		check.eq (env.g_ws, ws)
		check.falsy (ws.deleted)
	end)

	it ('Server Certificate: pasted raw PEM is written to the sandbox', function ()
		local env = H.machine ()
		env.boot ('')
		local pem = '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----'
		env.setProperty ('Server Certificate', pem)
		check.eq (env.c4.files ['c4tls_ca.pem'], pem)
		check.eq (env.g_caReady, true)
	end)

	it ('Server Certificate: single-line base64 PEM is decoded', function ()
		local env = H.machine ()
		env.boot ('')
		local pem = '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n'
		env.setProperty ('Server Certificate', H.b64encode (pem))
		check.eq (env.c4.files ['c4tls_ca.pem'], pem)
		check.eq (env.g_caReady, true)
	end)

	it ('Server Certificate: garbage is rejected and nothing is written', function ()
		local env = H.machine ()
		env.boot ('')
		env.setProperty ('Server Certificate', 'this is not a certificate')
		check.is_nil (env.c4.files ['c4tls_ca.pem'])
		check.eq (env.g_caReady, false)
	end)

	it ('Server Certificate: clearing it un-readies the pinned cert', function ()
		local env = H.machine ()
		env.boot ('')
		env.setProperty ('Server Certificate', '-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----')
		check.eq (env.g_caReady, true)
		env.setProperty ('Server Certificate', '')
		check.eq (env.g_caReady, false)
	end)

	it ('Server Certificate change reconnects only in TLS modes', function ()
		local env = H.machine ()
		env.boot ('192.168.1.50')
		local plain = env.g_ws
		env.setProperty ('Server Certificate', '-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----')
		check.eq (env.g_ws, plain)
		env.setProperty ('Connection Security', 'TLS pinned (wss://)')
		local tls = env.g_ws
		env.setProperty ('Server Certificate', '-----BEGIN CERTIFICATE-----\ny\n-----END CERTIFICATE-----')
		check.ne (env.g_ws, tls)
	end)
end)
