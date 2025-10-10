-- parameter check
if not arg[1] then
	app:fail("missing script to run")
end

-- shift arguments
table.move(arg, 1, #arg, 0)
arg[#arg] = nil

-- update application name
app.NAME = arg[0]:match("[^/]+$")

-- run the script
app:run(dofile, arg[0])
