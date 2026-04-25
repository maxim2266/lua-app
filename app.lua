-- [global] trim whitespace from both ends of the string
function string.trim(s) --> string
	-- see trim12 from http://lua-users.org/wiki/StringTrim
	local i <const> = s:match("^%s*()")
	return i > #s and "" or s:match(".*%S", i)
end

-- regex for string expansion
local _exp_re <const> = "%$%$?{[%a_][%w_]*}"

-- [global] string expansion
function string:expand(map) --> string
	local fn <const> = type(map) == "table" and function(s) return map[s] end
					or map

	return (self:gsub(_exp_re, function(s)
		return s:byte(2) == 36 and s:sub(2) or fn(s:sub(3, #s - 1))
	end))
end

-- [global] string expansion to a stream
function string:expand_to(dest, map) --> ok or (fail, ...)
	-- mapper function
	local fn <const> = type(map) == "table" and function(s) return map[s] end
					or map

	-- writer loop
	local function loop(b, ok, ...)
		-- previous write
		if not ok then
			return false, ...
		end

		-- end of string
		if b > #self - 3 then	-- the shortest valid pattern is 4 bytes long
			return dest:write(self:sub(b))
		end

		-- match
		local i, j = self:find(_exp_re, b)

		if not i then
			return dest:write(self:sub(b))
		end

		-- substitution
		local s <const> = self:byte(i + 1) == 36
						  and self:sub(i + 1, j)		-- $$
						  or fn(self:sub(i + 2, j - 1))	-- map

		-- loop
		if not s then
			return loop(j + 1, dest:write(self:sub(b, j)))
		end

		return loop(j + 1, dest:write(self:sub(b, i - 1), s))
	end

	return loop(1, true)
end

-- original os.exit
local _real_exit <const> = os.exit

-- exit code
local _exit_code = 0

-- [global] os.exit replacement to make sure Lua state is closed upon exit
function os.exit(code)
	_exit_code = not code and 1 or code == true and 0 or code
	_real_exit(_exit_code, true)
end

-- exit handlers table
_G["~ exit handlers ~"] = setmetatable({}, {
	__gc = function(handlers)
		for _, fn in ipairs(handlers) do
			pcall(fn, _exit_code)
		end
	end
})

-- [global] register exit handler
function atexit(fn, ...)
	-- check parameter now to avoid surprises when the program terminates
	local t <const> = type(fn)

	if t ~= "function" then
		error('invalid argument type "' .. t .. '" in a call to atexit function', 2)
	end

	-- add handler
	local arg <const> = select("#", ...) > 0 and table.pack(...)

	table.insert(
		_G["~ exit handlers ~"],
		1,
		arg and function() fn(table.unpack(arg)) end or fn
	)
end

-- write message to STDERR
local function _write_msg(name, kind, msg, ...)
	local _ = io.stderr:write(
		name,
		": [", kind, "] ",
		(select("#", ...) > 0 and msg:format(...) or msg):trim(),
		"\n"
	) or os.exit(125) -- STDERR is dead
end

-- [global] application object
app = {
	-- application name
	NAME = arg[0]:match("[^/]+$"),
}

-- application-level logging
function app:log(msg, ...)	_write_msg(self.NAME, "info", msg, ...) end
function app:warn(msg, ...)	_write_msg(self.NAME, "warn", msg, ...) end

function app:fail(msg, ...) --> never
	_write_msg(self.NAME, "error", msg, ...)
	os.exit(false)
end

-- application runner
function app:run(fn, ...) --> never
	-- disallow recursive calls
	self.run = function()
		error("recursive call to app:run", 2)
	end

	-- make STDERR line-buffered
	io.stderr:setvbuf("line")

	-- invoke the function
	local ok, err = xpcall(fn, function(e)
		-- see if the error message is from a SIGINT interrupt
		if type(e) == "string" and e:find("%f[^%s\0]interrupted!$") then
			_write_msg(self.NAME, "error", "terminated.")
			os.exit(128 + 2) -- SIGINT exit code
		end

		-- pass the error object through
		return debug.traceback(e, 2)
	end, ...)

	if not ok then
		io.stderr:write(tostring(err):trim(), "\n")
	end

	os.exit(ok)
end

-- context metatable
local _ctx_mt <const> = {}

-- context invocation as a function
function _ctx_mt:__call(ok, ...) --> all arguments
	if ok then
		return ok, ...
	end

	-- got an error
	local err, code = ...

	if math.type(code) == "integer" then
		if err == "exit" then -- error from os.execute or similar
			-- just exit with this code, assuming an error message has already been
			-- produced by an external program
			os.exit(code)
		end

		if err == "signal" then
			-- exit as if terminated by this signal
			os.exit(code + 128)
		end
	end

	-- terminate
	self:fail(tostring(err))
end

-- context methods
function _ctx_mt:fail(msg, ...)	self._parent:fail(self._prefix .. msg, ...) end
function _ctx_mt:warn(msg, ...)	self._parent:warn(self._prefix .. msg, ...) end
function _ctx_mt:log(msg, ...)	self._parent:log(self._prefix .. msg, ...) end

-- context method resolver
_ctx_mt.__index = _ctx_mt

-- [global] error context constructor
function context(prefix, parent) --> context object
	return setmetatable({
		_prefix = prefix:trim() .. ": ",
		_parent = parent or app,
	}, _ctx_mt)
end

-- [global] shell
shell = {
	-- shell quoting (bash or sh)
	quote = function(s) --> quoted string
		s = "'" .. s:gsub("'", "'\\''") .. "'"
		s = s:gsub("''\\'", "\\'"):gsub("''$", "")	-- not strictly necessary

		return s
	end,

	-- read command output
	read = function(cmd, ctx) --> string
		local src <const> = io.popen(type(cmd) == "table" and table.concat(cmd, " ") or cmd)
		local data <const> = src:read("a")

		context("shell", ctx)(src:close())
		return data
	end,
}

-- [global] create automatically removed temporary directory
function os.tmpdir(ctx) --> directory name
	local tmp <const> = shell.read("mktemp -d", ctx):trim()

	atexit(os.execute, "rm -rf '" .. tmp .. "'")
	return tmp
end

-- [global] create automatically removed temporary file
function os.tmpfile() --> file name
	local tmp <const> = os.tmpname()

	atexit(os.remove, tmp)
	return tmp
end

-- 'stat' result metatable
local _stat_mt <const> = {
	__tostring = function(t)
		return table.concat({
			"name:     " .. t.name,
			"type:     " .. t.type,
			"owner:    " .. t.owner,
			"perm.:    " .. t.perm,
			"size:     " .. t.size,
			"created:  " .. os.date("%F %T", t.created),
			"modified: " .. os.date("%F %T", t.modified),
		}, "\n")
	end
}

-- [global] stat
function os.stat(pathname) --> table or (fail, error)
	-- read stats
	local s = "perm=%A\tsize=%s\tcreated=%W\tmodified=%Y\towner=%U\ttype=%F"
	local src <const> = io.popen(("stat -c '%s' %s 2>&1"):format(s, shell.quote(pathname)))

	s = src:read("a")

	-- error check
	local ok, err, code = src:close()

	if not ok then
		if err == "exit" then
			assert(s:find("^stat:%s+"), "stat: unexpected error message")
			return nil, ("%q: %s"):format(pathname, s:match(":%s*([^:]-)%s*$"))
		end

		assert(err == "signal", "stat: unexpected error status")
		os.exit(code + 128) -- exit as if terminated by this signal
	end

	-- parse result
	local data <const> = { name = pathname }

	for k, v in s:gmatch("(%a+)=([^\t\n]+)") do
		if k == "size" or k == "created" or k == "modified" then
			data[k] = math.tointeger(v)
		elseif k == "type" then
			data[k] = v:gsub(" empty ", " ")
		else
			data[k] = v
		end
	end

	return setmetatable(data, _stat_mt)
end

-- [global] remove file if it exists
function os.remove_if_exists(fname) --> true or (fail, msg, errno)
	local ok, msg, errno = os.remove(fname)

	if ok or errno == 2 then -- ENOENT 2 No such file or directory
		return true
	end

	return nil, msg, errno
end

-- [global] iterate source file producing lines separated by the given one byte delimiter
-- Note: functions io.lines and file:lines both skip the nearest
-- pcall when interrupted by SIGINT, this one does not.
-- (see https://groups.google.com/g/lua-l/c/mmNZs5Fjt20)
function io.lines_from(src, delim)
	-- trivial case
	if not delim or delim == "\n" then
		return function() return (src:read()) end
	end

	-- delimiter must be a single byte
	if #delim ~= 1 then
		error(("invalid delimiter %q in io.lines_from"):format(delim), 2)
	end

	-- buffer size
	local N <const> = 8 * 1024

	-- state
	local i = 1
	local buff = src:read(N)

	-- filler
	local function fill(acc)
		-- read next buffer
		buff = src:read(N)

		if not buff then
			return #acc > 0 and acc or nil	-- last line
		end

		-- search for delimiter
		local j <const> = buff:find(delim, 1, true)

		if j then
			-- compose and return the line
			i = j + 1
			return acc .. buff:sub(1, j - 1)
		end

		return fill(acc .. buff)
	end

	-- iterator
	return function()
		if buff then
			-- find next delimiter
			local j <const> = buff:find(delim, i, true)

			if j then
				-- return the line
				local tmp <const> = buff:sub(i, j - 1)

				i = j + 1
				return tmp
			end

			-- read from source
			return fill(buff:sub(i))
		end
	end
end
