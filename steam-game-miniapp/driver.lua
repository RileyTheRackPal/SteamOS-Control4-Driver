--[[
	Steam Game (Mini App) - Control4 DriverWorks mini driver

	A per-game "mini app" that binds to the Steam Machine (System Bridge) parent
	driver via an RF_MINI_APP connection. Selecting it in a room's Watch list
	makes the parent launch the configured steam:// URI; all remote commands are
	passed through to the parent.

	Runtime mechanics follow Control4's official Universal Minidriver pattern
	(um_netflix.c4z): the mini publishes APP_NAME and UM_STEAM_MACHINE device
	variables, and forwards proxy commands to the parent with SendToDevice
	('PASSTHROUGH'). Unlike the official minis, the app data here is set by the
	installer through Composer properties instead of embedded JSON, so one
	driver template works for any game.
]]

APP_BINDING = 3101
CURRENT_SELECTED_DEVICE = 1000	-- room variable: currently selected device
CURRENT_AUDIO_PATH = 1007		-- room variable: current audio path

MINIAPP_TYPE = 'UM_STEAM_MACHINE'

function OnDriverInit ()
	C4:RegisterSystemEvent (C4SystemEvents.OnPIP, 0)
	-- stable creation order so ids never shift between loads
	C4:AddVariable ('APP_NAME', '', 'STRING', true, false)
	C4:AddVariable (MINIAPP_TYPE, '', 'STRING', true, false)
end

function OnDriverDestroyed ()
	C4:UnregisterSystemEvent (C4SystemEvents.OnPIP, 0)
end

function OnDriverLateInit ()
	UpdateAppData ()
	RegisterRooms ()
end

function OnPropertyChanged (strProperty)
	UpdateAppData ()
end

local function trim (s)
	return (tostring (s or ''):gsub ('^%s+', ''):gsub ('%s+$', ''))
end

function UpdateAppData ()
	local name = trim (Properties ['Game Name'])
	if (name == '') then
		name = 'Steam Game'
	end

	local raw = trim (Properties ['Steam App ID or URI'])
	local uri = ''
	if (raw:find ('^%d+$')) then
		uri = 'steam://rungameid/' .. raw
	elseif (raw ~= '') then
		uri = raw
	end

	if (Properties ['Launch URI'] ~= uri) then
		C4:UpdateProperty ('Launch URI', uri)
	end

	C4:SetVariable ('APP_NAME', name)
	C4:SetVariable (MINIAPP_TYPE, uri)
end

function OnSystemEvent (event)
	local eventname = string.match (event, '.-name="(.-)"')
	if (eventname == 'OnPIP') then
		ConnectedDevices = (C4:GetBoundConsumerDevices (C4:GetProxyDevices (), APP_BINDING))
		RegisterRooms ()
	end
end

function OnWatchedVariableChanged (idDevice, idVariable, strValue)
	if (RoomIDs and RoomIDs [idDevice]) then
		local roomId = tonumber (idDevice)

		if (idVariable == CURRENT_SELECTED_DEVICE) then
			local deviceId = tonumber (strValue) or 0
			RoomIDSources [roomId] = deviceId

		elseif (idVariable == CURRENT_AUDIO_PATH) then
			RoomIDRoutes [roomId] = {}
			for id in string.gmatch (strValue or '', '<id>(.-)</id>') do
				table.insert (RoomIDRoutes [roomId], tonumber (id))
			end
			UpdateRoomTarget (roomId)
		end
	end
end

function UpdateRoomTarget (roomId)
	RoomIDTargets = RoomIDTargets or {}
	RoomIDTargets [roomId] = nil

	ConnectedDevices = ConnectedDevices or (C4:GetBoundConsumerDevices (C4:GetProxyDevices (), APP_BINDING))

	if (ConnectedDevices) then
		for _, id in ipairs (RoomIDRoutes [roomId] or {}) do
			if (ConnectedDevices [id]) then
				RoomIDTargets [roomId] = id
				break
			end
		end
	end
end

function RegisterRooms ()
	RoomIDs = C4:GetDevicesByC4iName ('roomdevice.c4i')
	RoomIDSources = {}
	RoomIDRoutes = {}
	RoomIDTargets = {}

	for roomId, _ in pairs (RoomIDs or {}) do
		RoomIDSources [roomId] = tonumber (C4:GetDeviceVariable (roomId, CURRENT_SELECTED_DEVICE)) or 0

		RoomIDRoutes [roomId] = {}
		for id in string.gmatch (C4:GetDeviceVariable (roomId, CURRENT_AUDIO_PATH) or '', '<id>(.-)</id>') do
			table.insert (RoomIDRoutes [roomId], tonumber (id))
		end
		UpdateRoomTarget (roomId)

		C4:UnregisterVariableListener (roomId, CURRENT_SELECTED_DEVICE)
		C4:RegisterVariableListener (roomId, CURRENT_SELECTED_DEVICE)

		C4:UnregisterVariableListener (roomId, CURRENT_AUDIO_PATH)
		C4:RegisterVariableListener (roomId, CURRENT_AUDIO_PATH)
	end
end

function ReceivedFromProxy (idBinding, strCommand, tParams)
	strCommand = strCommand or ''
	tParams = tParams or {}

	local roomId = tonumber (tParams.ROOMID) or tonumber (tParams.ROOM_ID)

	if (roomId and RoomIDTargets and RoomIDTargets [roomId]) then
		tParams.PASSTHROUGH_COMMAND = strCommand
		C4:SendToDevice (RoomIDTargets [roomId], 'PASSTHROUGH', tParams)
	end
end
