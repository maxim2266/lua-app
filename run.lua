-- help string
local HELP <const> = [=[Usage:
 ]=] .. app.NAME .. [=[ script [args...]
    Run Lua script with app.lua runtime included. Script name "-" instructs
    to read the script from STDIN.
 ]=] .. app.NAME .. [=[ -h/--help
    Display this help and exit.
]=]

app:run(function()
	-- script name
	local script <const> = arg[1]

	-- parameter check
	if not script then
		app:fail("missing script name")
	end

	if script == "-h" or script == "--help" then
		io.stderr:write(HELP)
		os.exit(false)
	end

	-- shift arguments
	table.move(arg, 1, #arg, 0)
	arg[#arg] = nil

	-- STDIN
	if script == "-" then
		return dofile()
	end

	-- update application name
	app.NAME = script:match("[^/]+$")

	-- run
	return dofile(script)
end)
