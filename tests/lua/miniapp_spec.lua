-- steam-game-miniapp: publishes its steam:// URI to the parent; passes commands through
local H = require ('c4_mock')

local function mini ()
	local env = H.miniapp ()
	env.OnDriverInit ()
	return env
end

local function configure (env, name, raw)
	env.Properties ['Game Name'] = name
	env.Properties ['Steam App ID or URI'] = raw
	env.OnPropertyChanged ('Steam App ID or URI')
end

describe ('mini app: lifecycle', function ()
	it ('creates APP_NAME then UM_STEAM_MACHINE in a stable order', function ()
		local env = mini ()
		local names = {}
		for _, a in ipairs (env.c4.of ('AddVariable')) do names [#names + 1] = a [1] end
		check.deep_eq (names, { 'APP_NAME', 'UM_STEAM_MACHINE' })
		check.eq (env.MINIAPP_TYPE, 'UM_STEAM_MACHINE')
	end)

	it ('registers for the OnPIP system event and unregisters on destroy', function ()
		local env = mini ()
		check.eq (env.c4.count ('RegisterSystemEvent'), 1)
		env.OnDriverDestroyed ()
		check.eq (env.c4.count ('UnregisterSystemEvent'), 1)
	end)

	it ('OnDriverLateInit publishes app data (defaults to "Steam Game" with no URI)', function ()
		local env = mini ()
		env.OnDriverLateInit ()
		check.eq (env.Variables.APP_NAME, 'Steam Game')
		check.eq (env.Variables.UM_STEAM_MACHINE, '')
	end)
end)

describe ('mini app: URI publishing', function ()
	it ('a numeric App ID becomes steam://rungameid/<id>', function ()
		local env = mini ()
		configure (env, 'Portal 2', ' 620 ')
		check.eq (env.Properties ['Launch URI'], 'steam://rungameid/620')
		check.eq (env.Variables.UM_STEAM_MACHINE, 'steam://rungameid/620')
		check.eq (env.Variables.APP_NAME, 'Portal 2')
	end)

	it ('accepts well-formed steam:// URIs (any scheme case)', function ()
		for _, uri in ipairs ({ 'steam://rungameid/620', 'steam://open/bigpicture', 'STEAM://run/1',
			'steam://nav/games?x=1&y=2', 'steam://a/b.c_d-e%20f:1' }) do
			local env = mini ()
			configure (env, 'G', uri)
			check.eq (env.Variables.UM_STEAM_MACHINE, uri, uri)
			check.eq (env.Properties ['Launch URI'], uri, uri)
		end
	end)

	it ('rejects file://, https://, shell metacharacters, spaces and newlines', function ()
		for _, bad in ipairs ({ 'file:///etc/passwd', 'https://example.com', 'javascript:alert(1)', 'steam:/x',
			'steam://x y', 'steam://a;b', 'steam://$(x)', "steam://x'y", 'steam://a|b', 'steam://<x>',
			'steam://x#y', 'steam://x\\y', 'steam://open/\nfile:///etc/passwd', '620abc', '-1', 'abc' }) do
			local env = mini ()
			configure (env, 'Evil', bad)
			check.eq (env.Variables.UM_STEAM_MACHINE, '', string.format ('%q', bad))
			check.contains (env.Properties ['Launch URI'], 'Rejected', string.format ('%q', bad))
			check.eq (env.Variables.APP_NAME, 'Evil')
		end
	end)

	it ('a rejected value after a good one retracts the published URI', function ()
		local env = mini ()
		configure (env, 'G', '620')
		check.eq (env.Variables.UM_STEAM_MACHINE, 'steam://rungameid/620')
		configure (env, 'G', 'file:///x')
		check.eq (env.Variables.UM_STEAM_MACHINE, '')
	end)

	it ('clearing the field clears the published URI', function ()
		local env = mini ()
		configure (env, 'G', '620')
		configure (env, 'G', '')
		check.eq (env.Properties ['Launch URI'], '')
		check.eq (env.Variables.UM_STEAM_MACHINE, '')
	end)

	it ('sanitizes and caps the game name', function ()
		local env = mini ()
		configure (env, ' Half\nLife ', '70')
		check.eq (env.Variables.APP_NAME, 'Half Life')
		configure (env, string.rep ('N', 500), '70')
		check.eq (#env.Variables.APP_NAME, 128)
	end)

	it ('any property change re-publishes (name edits alone)', function ()
		local env = mini ()
		configure (env, 'One', '10')
		env.Properties ['Game Name'] = 'Two'
		env.OnPropertyChanged ('Game Name')
		check.eq (env.Variables.APP_NAME, 'Two')
		check.eq (env.Variables.UM_STEAM_MACHINE, 'steam://rungameid/10')
	end)
end)

describe ('mini app: room routing and passthrough', function ()
	local function wired ()
		local env = mini ()
		env.c4.override ('GetDevicesByC4iName', function () return { [10] = 'Living Room' } end)
		env.c4.override ('GetDeviceVariable', function (_, id, var)
			if (id == 10 and var == 1000) then return '5' end
			if (id == 10 and var == 1007) then return '<id>77</id><id>88</id>' end
		end)
		env.c4.override ('GetBoundConsumerDevices', function () return { [88] = true } end)
		env.RegisterRooms ()
		return env
	end

	it ('RegisterRooms picks the first routed device that is bound to this mini', function ()
		local env = wired ()
		check.eq (env.RoomIDTargets [10], 88)
		check.eq (env.RoomIDSources [10], 5)
		check.eq (env.c4.count ('RegisterVariableListener'), 2)
	end)

	it ('forwards proxy commands to the room target as PASSTHROUGH', function ()
		local env = wired ()
		env.ReceivedFromProxy (5001, 'PLAY', { ROOMID = '10' })
		local sent = env.c4.of ('SendToDevice') [1]
		check.eq (sent [1], 88)
		check.eq (sent [2], 'PASSTHROUGH')
		check.eq (sent [3].PASSTHROUGH_COMMAND, 'PLAY')
	end)

	it ('accepts ROOM_ID as an alias', function ()
		local env = wired ()
		env.ReceivedFromProxy (5001, 'UP', { ROOM_ID = '10' })
		check.eq (env.c4.of ('SendToDevice') [1] [3].PASSTHROUGH_COMMAND, 'UP')
	end)

	it ('drops commands with no room, an unknown room, or a nil command', function ()
		local env = wired ()
		env.ReceivedFromProxy (5001, 'PLAY', {})
		env.ReceivedFromProxy (5001, 'PLAY', { ROOMID = '99' })
		env.ReceivedFromProxy (5001, nil, nil)
		check.eq (env.c4.count ('SendToDevice'), 0)
	end)

	it ('audio-path changes retarget the room; unrouted rooms get no target', function ()
		local env = wired ()
		env.OnWatchedVariableChanged (10, 1007, '<id>77</id>')
		check.is_nil (env.RoomIDTargets [10])
		env.OnWatchedVariableChanged (10, 1007, '<id>77</id><id>88</id>')
		check.eq (env.RoomIDTargets [10], 88)
	end)

	it ('tracks the selected source and ignores unwatched rooms', function ()
		local env = wired ()
		env.OnWatchedVariableChanged (10, 1000, '7')
		check.eq (env.RoomIDSources [10], 7)
		env.OnWatchedVariableChanged (55, 1000, '9')
		check.is_nil (env.RoomIDSources [55])
	end)

	it ('OnPIP system event re-registers rooms', function ()
		local env = wired ()
		local before = env.c4.count ('GetDevicesByC4iName')
		env.OnSystemEvent ('<event name="OnPIP"/>')
		check.eq (env.c4.count ('GetDevicesByC4iName'), before + 1)
	end)
end)
