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
local script = ensure(arg[1], "missing script name")

-- help string display
if script == "-h" or script == "--help" then
	HELP:expand_to(io.stderr, { prog = app.NAME })
	os.exit(false)
end

-- expressions
while arg[1] == "-e" do
	table.remove(arg, 1) -- '-e'
	ensure(load(ensure(table.remove(arg, 1), "missing script")))() -- execute expression
end

-- script
script = arg[1]

if script then
	-- load
	local fn

	if script == "-" then
		fn = ensure(loadfile())
		table.remove(arg, 1) -- dash
	else
		fn = ensure(loadfile(script))
		app.NAME = script:match("[^/]+$")

		-- arguments:
		--   -2      -1      0       1...
		--   lua5.4  ./luax  script  args...
		table.move(arg, -1, #arg, -2)[#arg] = nil
	end

	-- execute
	os.exit(not fn())
end
