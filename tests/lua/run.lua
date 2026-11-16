--[[
	Dependency-free test runner for the Control4 drivers.

	Run from the repository root:
		lua tests/lua/run.lua            -- all specs
		lua tests/lua/run.lua miniapp    -- only specs whose name contains "miniapp"

	Spec files are plain Lua scripts that use the globals defined here:
		describe (name, fn)
		it (name, fn)
		pending (name, reason)           -- known bug / not yet testable: reported as SKIP
		check.eq / ne / truthy / falsy / is_nil / contains / not_contains / matches / deep_eq
	Each spec builds its own fresh driver environment via c4_mock (so no state leaks).
	Set TEST_VERBOSE=1 to echo everything the drivers print().
]]

local script = ((arg and arg [0]) or 'tests/lua/run.lua'):gsub ('\\', '/')
local dir = script:match ('^(.*)/[^/]*$') or '.'
package.path = dir .. '/?.lua;' .. package.path

-- explicit spec list (no shell-specific directory listing needed)
local SPECS = {
	'machine_properties_spec',
	'machine_connection_spec',
	'machine_messages_spec',
	'machine_launch_power_spec',
	'machine_commands_spec',
	'miniapp_spec',
	'driver_xml_spec',
}

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------

local stats = { pass = 0, fail = 0, skip = 0, assertions = 0 }
local failures, skips = {}, {}
local suiteStack, currentSpec = {}, ''

local function fullName (name)
	local parts = { currentSpec }
	for _, s in ipairs (suiteStack) do parts [#parts + 1] = s end
	parts [#parts + 1] = name
	return table.concat (parts, ' > ')
end

---------------------------------------------------------------------------
-- assertions
---------------------------------------------------------------------------

local function show (v)
	if (type (v) == 'string') then return string.format ('%q', v) end
	if (type (v) == 'table') then
		local keys = {}
		for k in pairs (v) do keys [#keys + 1] = k end
		table.sort (keys, function (a, b) return tostring (a) < tostring (b) end)
		local parts = {}
		for _, k in ipairs (keys) do parts [#parts + 1] = tostring (k) .. '=' .. show (v [k]) end
		return '{' .. table.concat (parts, ', ') .. '}'
	end
	return tostring (v)
end

local function fail (msg, extra)
	error ((extra and (extra .. ': ') or '') .. msg, 3)
end

local function deepEq (a, b)
	if (type (a) ~= type (b)) then return false end
	if (type (a) ~= 'table') then return a == b end
	for k, v in pairs (a) do if (not deepEq (v, b [k])) then return false end end
	for k in pairs (b) do if (a [k] == nil) then return false end end
	return true
end

check = {}
local function count () stats.assertions = stats.assertions + 1 end

function check.eq (actual, expected, msg)
	count ()
	if (actual ~= expected) then fail ('expected ' .. show (expected) .. ' but got ' .. show (actual), msg) end
end
function check.ne (actual, unexpected, msg)
	count ()
	if (actual == unexpected) then fail ('did not expect ' .. show (actual), msg) end
end
function check.truthy (v, msg)
	count ()
	if (not v) then fail ('expected a truthy value but got ' .. show (v), msg) end
end
function check.falsy (v, msg)
	count ()
	if (v) then fail ('expected a falsy value but got ' .. show (v), msg) end
end
function check.is_nil (v, msg)
	count ()
	if (v ~= nil) then fail ('expected nil but got ' .. show (v), msg) end
end
function check.contains (s, sub, msg)
	count ()
	if (type (s) ~= 'string' or not s:find (sub, 1, true)) then
		fail ('expected ' .. show (s) .. ' to contain ' .. show (sub), msg)
	end
end
function check.not_contains (s, sub, msg)
	count ()
	if (type (s) == 'string' and s:find (sub, 1, true)) then
		fail ('expected text NOT to contain ' .. show (sub), msg)
	end
end
function check.matches (s, pattern, msg)
	count ()
	if (type (s) ~= 'string' or not s:find (pattern)) then
		fail ('expected ' .. show (s) .. ' to match pattern ' .. show (pattern), msg)
	end
end
function check.deep_eq (actual, expected, msg)
	count ()
	if (not deepEq (actual, expected)) then
		fail ('expected ' .. show (expected) .. ' but got ' .. show (actual), msg)
	end
end

---------------------------------------------------------------------------
-- structure
---------------------------------------------------------------------------

function describe (name, fn)
	table.insert (suiteStack, name)
	fn ()
	table.remove (suiteStack)
end

function it (name, fn)
	local label = fullName (name)
	local ok, err = xpcall (fn, function (e)
		local tb = debug.traceback (tostring (e), 2)
		-- keep the trace short: message + the first few frames inside spec files
		local lines, kept = {}, 0
		for line in tb:gmatch ('[^\n]+') do
			if (kept == 0 or line:find ('_spec%.lua')) then
				lines [#lines + 1] = line
				kept = kept + 1
				if (kept >= 4) then break end
			end
		end
		return table.concat (lines, '\n')
	end)
	if (ok) then
		stats.pass = stats.pass + 1
	else
		stats.fail = stats.fail + 1
		table.insert (failures, { label = label, err = err })
		io.write ('F')
		return
	end
	io.write ('.')
end

function pending (name, reason)
	stats.skip = stats.skip + 1
	table.insert (skips, { label = fullName (name), reason = reason or 'pending' })
	io.write ('S')
end

---------------------------------------------------------------------------
-- go
---------------------------------------------------------------------------

local filter = arg and arg [1]
local started = os.clock ()

for _, spec in ipairs (SPECS) do
	if (not filter or spec:find (filter, 1, true)) then
		currentSpec = spec:gsub ('_spec$', '')
		suiteStack = {}
		local ok, err = pcall (dofile, dir .. '/' .. spec .. '.lua')
		if (not ok) then
			stats.fail = stats.fail + 1
			table.insert (failures, { label = spec .. ' (load error)', err = tostring (err) })
			io.write ('E')
		end
	end
end

print ('\n')
if (#skips > 0) then
	print ('Skipped:')
	for _, s in ipairs (skips) do print ('  SKIP ' .. s.label .. '\n       ' .. s.reason) end
	print ('')
end
if (#failures > 0) then
	print ('Failures:')
	for i, f in ipairs (failures) do print (string.format ('  %d) %s\n%s\n', i, f.label, f.err:gsub ('^', '     '))) end
end

print (string.format ('%d passed, %d failed, %d skipped (%d tests, %d assertions, %.2fs)',
	stats.pass, stats.fail, stats.skip, stats.pass + stats.fail + stats.skip, stats.assertions, os.clock () - started))

if (stats.fail > 0) then
	os.exit (1)
end
os.exit (0)
