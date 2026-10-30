#! ./luax

assert(app, 'missing "app.lua"')

local function ensure(cond, msg, ...)
	if not cond then
		app:fail(msg, ...)
	end
end

local function test_trim()
	local tests <const> = {
		"xxx",
		"  xxx ",
		"\txxx",
		"xxx\t\n",
	}

	for i, s in ipairs(tests) do
		local r <const> = s:trim()

		ensure(r == "xxx", "(%d) unexpected result: %q", i, r)
	end
end

local string_expand_tests <const> = {
	{ "__${a}__", "__42__" },
	{ "${a}__", "42__" },
	{ "${a}", "42" },
	{ "__$${a}__", "__${a}__" },
	{ "$${a}__", "${a}__" },
	{ "$${abc}", "${abc}" },
	{ "${a}_${abc}", "42_xxx" },
	{ "${a}${abc}", "42xxx" },
	{ "${a}_${x}", "42_${x}" },
	{ "$(a}", "$(a}" },
	{ "{a}", "{a}" },
	{ "${5}", "${5}" },
}

local string_expand_map <const> = {
	a = 42,
	abc = "xxx",
}

local function test_expand()
	for i, t in ipairs(string_expand_tests) do
		local r <const> = t[1]:expand(string_expand_map)

		ensure(r == t[2], "(%d) unexpected result: %q", i, r)
	end

	local user <const> = os.getenv("USER")

	if user then	-- $USER might be undefined
		local user2 <const> = ("${USER}"):expand(os.getenv)

		ensure(user == user2, "unexpected result: %q instead of %q", user2, user)
	else
		app:warn("environment variable $USER is not defined")
	end
end

local function test_expand_to()
	local function new_dest(ok)
		return {
			value = "",
			write = function(t, ...)
				for i = 1, select("#", ...) do
					t.value = t.value .. select(i, ...)
				end

				return ok, not ok and "failure" or nil
			end
		}
	end

	local m <const> = {
		a = 42,
		abc = "xxx",
	}

	for i, t in ipairs(string_expand_tests) do
		local dest = new_dest(true)
		local ok, err = t[1]:expand_to(dest, string_expand_map)

		ensure(ok, "(%d) unexpected error flag", i)
		ensure(not err, "(%d) unexpected error message: %q", i, err)
		ensure(dest.value == t[2], "(%d) unexpected result: %q", i, dest.value)
	end

	local ok, err = string_expand_tests[1][1]:expand_to(new_dest(false), string_expand_map)

	ensure(not ok, "missing error flag")
	ensure(err == "failure")
end

local function test_shell_quote()
	local tests <const> = {
		"'",
		"rock'n'roll",
		"one\ntwo\n",
		"'xxx'",
		"'''x'x'x'''\n'''",
		"$PATH",
	}

	for i, t in ipairs(tests) do
		local s <const> = shell.read_all("echo -n " .. shell.quote(t))

		ensure(s == t, "(%d) unexpected result: %q", i, s)
	end
end

local function test_shell_name()
	local name <const> = shell.NAME

	if name ~= "<unknown>" then
		app:log("shell: " .. name)
	else
		app:warn("unknown shell")
	end
end

local function test_lines_from(just)
	local tests <const> = {
		{ "", "" },
		{ "x", "x" },
		{ "_", "" },
		{ "___", "__" },
		{ "xx_xxx", "xx_xxx" },
		{ "xx____xxx", "xx____xxx" },
		{ "_xx_xxx", "_xx_xxx" },
		{ "___xx_xxx", "___xx_xxx" },
		{ "xx_xxx_", "xx_xxx" },
		{ "xx_xxx___", "xx_xxx__" },
		{ string.rep("x", 8 * 1024), string.rep("x", 8 * 1024) },
		{ string.rep("x", 8 * 1024 + 1), string.rep("x", 8 * 1024 + 1) },
		{ string.rep("x", 8 * 1024) .. "_", string.rep("x", 8 * 1024) },
		{ string.rep("x", 8 * 1024 - 1) .. "_", string.rep("x", 8 * 1024 - 1) },
		{ string.rep("x", 8 * 1024 - 1) .. "___", string.rep("x", 8 * 1024 - 1) .. "__" },
		{ string.rep("x", 32 * 1024 - 1) .. "___x", string.rep("x", 32 * 1024 - 1) .. "___x" },
	}

	local tmp <const> = os.tmpfile()

	for i, t in ipairs(tests) do
		local f <const> = just(io.open(tmp, "w+"))

		just(f:write(t[1]))
		just(f:seek("set", 0))

		local res = {}

		for s in io.lines_from(f, "_") do
			res[#res + 1] = s
		end

		just(f:close())

		res = table.concat(res, "_")

		ensure(res == t[2], "(%d) unexpected result: %q", i, res)
	end
end

local function test_lines_from_2(just)
	local temp_name <const> = os.tmpfile()
	local tmp <const> = just(io.open(temp_name, "w+"))

	just(tmp:write("xxx\nyyy\nzzz\n"))
	just(tmp:seek("set"))

	local res = {}

	for s in io.lines_from(tmp) do
		res[#res + 1] = s
	end

	just(tmp:close())

	res = table.concat(res, "_")

	if res ~= "xxx_yyy_zzz" then
		just:fail("unexpected result: %q", res)
	end
end

local function test_tmp_dir(just)
	local name <const> = just(shell.read_all("./luax -e 'print(os.tmpdir())'")):trim()

	if os.execute(("[ -e '%s' ]"):format(name)) then
		just:fail("directory %s is still there", name)
	end
end

local function test_unlink(just)
	just(os.unlink("does-not-exist"))
end

local function test_stat(just)
	local info, err = os.stat("./luax")

	if not info then
		just:fail("could not stat ./luax: " .. err)
	end

	if info.name ~= "./luax" then
		just:fail("unexpected file name: '%q'", info.name)
	end

	if info.type ~= "f" then
		just:fail("unexpected file type: '%q'", info.type)
	end

-- 	print(info)

	info, err = os.stat("./does-not-exist")

	if info then
		just:fail("nonexistent file info:\n" .. info)
	end

	-- LC_MESSAGES='C.UTF-8' ??
	if err ~= "No such file or directory" then
		just:fail("unexpected error: %q", err)
	end
end

local function test_realpath(just)
	local rp <const> = just(os.realpath("./luax"))

	if rp ~= (os.getenv("PWD") .. "/luax") then
		just:fail("unexpected path: %q", rp)
	end
end

local function test_scan_options(just)
	local cases <const> = {
		{ os.scan.any_name(nil), nil },
		{ os.scan.any_name(""), nil },
		{ os.scan.any_name("zzz"), "-name 'zzz'" },
		{ os.scan.any_name("aaa", "bbb"), "\\( -name 'aaa' -o -name 'bbb' \\)" },
		{ os.scan.any_name("aaa", nil, "bbb"), "\\( -name 'aaa' -o -name 'bbb' \\)" },
		{ os.scan.any_name("aaa", "", "bbb", nil), "\\( -name 'aaa' -o -name 'bbb' \\)" },
		{ os.scan.any_name(nil, "zzz"), "-name 'zzz'" },
		{ os.scan.any_name("", "zzz"), "-name 'zzz'" },
		{ os.scan.any_iname("zzz"), "-iname 'zzz'" },
		{ os.scan.any_path("zzz"), "-path 'zzz'" },
		{ os.scan.any_ipath("zzz"), "-ipath 'zzz'" },
		{ os.scan.any_lname("zzz"), "-lname 'zzz'" },
		{ os.scan.any_ilname("zzz"), "-ilname 'zzz'" },
		{ os.scan.any_regex("zzz"), "-regex 'zzz'" },
		{ os.scan.any_iregex("zzz"), "-iregex 'zzz'" },

		{ os.scan.any_type(nil), nil },
		{ os.scan.any_type(""), nil },
		{ os.scan.any_type("f"), "-type f" },
		{ os.scan.any_type("fd"), "\\( -type f -o -type d \\)" },
		{ os.scan.any_type("fdffdddffpp"), "\\( -type f -o -type d -o -type p \\)" },
	}

	for i, c in ipairs(cases) do
		if c[1] ~= c[2] then
			just:fail("(%d) unexpected result: %q instead of %q", i, c[1], c[2])
		end
	end
end

local function test_scan_all(just)
	local src <const> = os.scan(".", "-maxdepth 1", os.scan.any_name("luax", "not-there"))
	local t <const> = just(src:all())

	if #t ~= 1 then
		just:fail("got %d records instead of 1", #t)
	end

	if t[1] ~= "./luax" then
		just:fail("unexpected result: %q", t[1])
	end
end

local function test_scan_for_each(just)
	local src <const> = os.scan(".", "-maxdepth 1", os.scan.any_name("luax", "not-there"))
	local t <const> = {}

	just(src:for_each(function(s) t[#t + 1] = s end))

	if #t ~= 1 then
		just:fail("got %d records instead of 1", #t)
	end

	if t[1] ~= "./luax" then
		just:fail("unexpected result: %q", t[1])
	end
end

-- test runner
local function run_tests(tests)
	for i, t in ipairs(tests) do
		local name <const>, test <const> = t[1], t[2]

		print("# test " .. i .. ":", name)
		test(context(name))
		print("+ passed")
	end

	print("OK: " .. #tests .. " tests passed.")
end

run_tests {
	{ "string.trim", test_trim },
	{ "string.expand", test_expand },
	{ "string.expand_to", test_expand_to },
	{ "shell.quote", test_shell_quote },
	{ "shell.NAME", test_shell_name },
	{ "io.lines_from", test_lines_from },
	{ "io.lines_from (default)", test_lines_from_2 },
	{ "os.tmpdir", test_tmp_dir },
	{ "os.unlink", test_unlink },
	{ "os.stat", test_stat },
	{ "os.realpath", test_realpath },
	{ "os.scan options", test_scan_options },
	{ "os.scan:all", test_scan_all },
	{ "os.scan:for_each", test_scan_for_each },
}
