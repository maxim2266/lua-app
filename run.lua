-- help string
local HELP <const> = [=[Usage:
  ${prog} [OPTIONS] [SCRIPT [ARGS...]]

where SCRIPT is either a file name, or "-" for STDIN.

Options:
  -e EXPR     Execute string EXPR.
  -h, --help  Display this help and exit.

]=]

-- result check
local function ensure(res, err) --> fn
	return res or app:fail(err)
end

-- script name
local opt = ensure(arg[1], "missing script file name")

-- help string display
if opt == "-h" or opt == "--help" then
	HELP:expand_to(io.stderr, { prog = app.NAME })
	os.exit(false)
end

-- expressions
while opt == "-e" do
	table.remove(arg, 1) -- '-e'
	ensure(load(ensure(table.remove(arg, 1), "missing script")))() -- execute expression
	opt = arg[1]
end

-- script
if opt then
	-- load
	local fn

	if opt == "-" then
		fn = ensure(loadfile())
		table.remove(arg, 1) -- dash
	else
		fn = ensure(loadfile(opt))
		app.NAME = opt:match("[^/]+$")

		-- arguments:
		--   -1      0       1...
		--   lua5.4  script  args...
		table.move(arg, 1, #arg, 0)[#arg] = nil
	end

	-- execute
	os.exit(not fn())
end
