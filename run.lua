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

-- result check
local function ensure(res, err) --> fn
	return res or app:fail(err)
end

-- script name
local script <const> = ensure(arg[1], "missing script name")

-- help string display
if script == "-h" or script == "--help" then
	HELP:expand_to(io.stderr, { prog = app.NAME })
	os.exit(false)
end

-- load and compile script
local fn

if script == "-e" then
	-- Lua expression
	local expr <const> = ensure(arg[2], "missing script")

	-- shift arguments
	table.move(arg, 3, #arg, 1)
	arg[#arg], arg[#arg - 1] = nil, nil

	-- load expression
	fn = ensure(load(expr))
else
	-- shift arguments
	table.move(arg, 1, #arg, 0)
	arg[#arg] = nil

	-- load script
	if script == "-" then
		fn = ensure(loadfile())
	else
		fn = ensure(loadfile(script))
		app.NAME = script:match("[^/]+$")
	end
end

-- run
os.exit(not fn())
