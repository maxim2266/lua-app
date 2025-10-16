-- help string
local HELP <const> = [=[Usage:
 ${prog} script [args...]
    Run Lua script with app.lua runtime included. Script name "-" instructs
    to read the script from STDIN.

 ${prog} -e script [args...]
    Execute string "script" with app.lua runtime included.

 ${prog} -h
 ${prog} --help
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
		HELP:expand_to(io.stderr, { prog = app.NAME })
		os.exit(false)
	end

	if script == "-e" then
		-- Lua expression
		local expr <const> = arg[2]

		if not expr then
			app:fail("missing script")
		end

		-- shift arguments
		table.move(arg, 3, #arg, 1)
		arg[#arg], arg[#arg - 1] = nil, nil

		-- load expression
		local fn, err = load(expr)

		if not fn then
			io.stderr:write(app.NAME, ": ", err, "\n")
			os.exit(false)
		end

		-- execute expression
		return fn()
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
