-- non-empty string or nil
local function _str_or_nil(s)
	return #s > 0 and s or nil
end

-- convert each truthy argument via the given function, and collect
-- results into an array
local function _map_args(fn, ...) --> table
	local t <const> = {}

	for i = 1, select("#", ...) do
		local s <const> = select(i, ...)

		if s then
			t[#t + 1] = fn(s)
		end
	end

	return t
end

-- concatenate non-empty strings
local function _cat(...) --> string
	return table.concat(_map_args(_str_or_nil, ...), " ")
end

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
		local i <const>, j <const> = self:find(_exp_re, b)

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

do
	-- original os.exit
	local _real_exit <const> = os.exit

	-- [global] os.exit replacement to make sure Lua state is closed upon exit
	function os.exit(code)
		_real_exit(code, true)
	end
end

-- write message to STDERR
local function _write_msg(name, kind, msg, ...)
	-- prepare message text for single write
	msg = (select("#", ...) > 0 and msg:format(...) or msg):trim()
	msg = name .. ": [" .. kind .. "] " .. msg .. "\n"

	-- write
	if not io.stderr:write(msg) then
		_write_msg = function() end	-- no recursion
		os.exit(125) -- STDERR is dead
	end
end

-- [global] application object
app = setmetatable({
	-- application name
	NAME = arg[0]:match("[^/]+$"),

	-- table of exit handlers
	_exit_handlers = {}
}, {
	__gc = function(a)
		os.exit = function() end	-- no more exits

		for _, fn in ipairs(a._exit_handlers) do
			pcall(fn)
		end
	end
})

-- register exit handler
function app:atexit(fn, ...)
	-- check parameter now to avoid surprises when the program terminates
	local t <const> = type(fn)

	if t ~= "function" then
		error('invalid argument type "' .. t .. '" in a call to app:atexit function', 2)
	end

	-- add handler
	local arg <const> = select("#", ...) > 0 and table.pack(...)

	table.insert(
		self._exit_handlers,
		1,
		arg and function() fn(table.unpack(arg)) end or fn
	)
end

-- application-level logging
function app:log(msg, ...)	_write_msg(self.NAME, "info", msg, ...) end
function app:warn(msg, ...)	_write_msg(self.NAME, "warn", msg, ...) end

function app:fail(msg, ...) --> never returns
	_write_msg(self.NAME, "error", msg, ...)
	os.exit(false)
end

-- context
do
	-- context metatable
	local _ctx_mt <const> = {}

	-- context invocation as a function
	function _ctx_mt:__call(ok, ...) --> all arguments
		if ok then
			return ok, ...
		end

		-- got an error
		local err <const>, code <const> = ...

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
end

-- [global] shell
shell = {}

-- [global] shell quoting (bash or sh)
function shell.quote(s) --> quoted string
	s = "'" .. s:gsub("'", "'\\''") .. "'"
	s = s:gsub("''\\'", "\\'"):gsub("''$", "")	-- not strictly necessary

	return s
end

do
	-- check result of os.execute or pipe:close(), returning 'x' on success,
	-- or result of fn(x, code) on non-zero exit
	local function _perr(x, fn, ok, err, code)
		if ok then
			return x
		end

		if math.type(code) == "integer" then
			if err == "exit" then
				return fn(x, code)
			end

			if err == "signal" then
				os.exit(128 + code)
			end
		end

		error("_perr: " .. err)	-- should never happen
	end

	-- close pipe from io.popen
	local function _pclose(pipe, x, fn)
		return _perr(x, fn, pipe:close())
	end

	-- error status
	local function _err_status(_, code)
		return nil, "exit", code
	end

	local function _cmd_err(s)
		-- get error message from the command output
		return nil, (s:match(":%s*([^:]-)%s*$") or s)
	end

	-- read all output from pipe
	local function _read_all(pipe)
		return pipe:read("a")
	end

	-- [global] call 'fn' with the pipe from 'cmd'
	function shell.read(cmd, fn)
		local pipe <const> = assert(io.popen(cmd))

		return _pclose(pipe, fn(pipe), _err_status)
	end

	-- [global] read command output
	function shell.read_all(cmd)
		return shell.read(cmd, _read_all)
	end

	-- [global] read command's combined output, assuming the command yields either
	-- valid output, or an error message, but not both
	function shell.read_comb(cmd)
		local pipe <const> = assert(io.popen(cmd .. " 2>&1"))

		return _pclose(pipe, pipe:read("a"):trim(), _cmd_err)
	end

	-- [global] shell name
	setmetatable(shell, {
		__index = function(t, k)
			if k == "NAME" then
				-- see https://stackoverflow.com/questions/3327013/how-to-determine-the-current-interactive-shell-that-im-in-command-line
				local name = t.read_all("ps -q $$ -o 'comm='")

				name = name and name:trim() or "<unknown>"
				rawset(t, k, name)
				return name
			end
		end,
	})
end

-- [global] create automatically removed temporary directory
function os.tmpdir(ctx) --> directory name
	local tmp <const> = (ctx or context("os.tmpdir"))(shell.read_all("mktemp -d")):trim()

	app:atexit(os.execute, "rm -rf '" .. tmp .. "'")
	return tmp
end

-- [global] create automatically removed temporary file
function os.tmpfile() --> file name
	local tmp <const> = os.tmpname()

	app:atexit(os.remove, tmp)
	return tmp
end

-- stat
do
	-- 'stat' result metatable
	local _stat_mt <const> = {
		__tostring = function(t)
			return table.concat({
				"name:     " .. t.name,
				"type:     " .. t.type,
				"owner:    " .. t.owner,
				"perm.:    " .. t.perm,
				"size:     " .. t.size,
				"created:  " .. os.date("%F %T %z", t.created),
				"modified: " .. os.date("%F %T %z", t.modified),
			}, "\n")
		end
	}

	-- file type letters
	local _stat_letters <const> = {
		["regular file"] = 'f',
		["regular empty file"] = 'f',
		["directory"] = 'd',
		["symbolic link"] = 'l',
		["character special file"] = 'c',
		["block special file"] = 'b',
		["fifo"] = 'p',
		["socket"] = 's',
		["door"] = 'D',
	}

	-- [global] stat
	function os.stat(pathname) --> table or (fail, error)
		-- read stats
		local cmd = "perm=%A\tsize=%s\tcreated=%W\tmodified=%Y\towner=%U\ttype=%F"

		cmd = ("stat -c '%s' %s"):format(cmd, shell.quote(pathname))

		local s <const>, err <const> = shell.read_comb(cmd)

		if not s then
			return nil, err
		end

		-- parse result
		local data <const> = { name = pathname }

		for k, v in s:gmatch("(%a+)=([^\t]+)") do
			if k == "size" or k == "created" or k == "modified" then
				data[k] = math.tointeger(v)
			elseif k == "type" then
				data[k] = _stat_letters[v] or '?'
			else
				data[k] = v
			end
		end

		return setmetatable(data, _stat_mt)
	end

	-- [global] realpath
	function os.realpath(pathname) --> real path or (fail, error)
		return shell.read_comb("realpath -e " .. shell.quote(pathname))
	end
end

-- [global] like os.remove, but does not fail for nonexistent files
function os.unlink(fname) --> true or (fail, msg, errno)
	local ok <const>, msg <const>, errno <const> = os.remove(fname)

	if ok or errno == 2 then -- ENOENT 2 No such file or directory
		return true
	end

	return nil, msg, errno
end

-- [global] iterate source file producing lines separated by the given one byte delimiter
-- Note: in Lua5.4 functions io.lines and file:lines both skip the nearest
-- pcall when interrupted by SIGINT, this one does not.
-- (see https://groups.google.com/g/lua-l/c/mmNZs5Fjt20)
function io.lines_from(src, delim)
	-- trivial case
	if not delim or delim == "\n" then
		return function() return (src:read()) end
	end

	-- delimiter must be a single byte
	if type(delim) ~= "string" or #delim ~= 1 then
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

-- [global] directory scanner
os.scan = {}

do
	-- "find" option renderer
	local function _opt2str(opt, values) --> string or nil
		if #values == 1 then
			return "-" .. opt .. " " .. values[1]
		elseif #values > 1 then
			return "\\( -" .. opt .. " " .. table.concat(values, " -o -" .. opt .. " ") .. " \\)"
		end
	end

	local function _quote_or_nil(s)
		return #s > 0 and shell.quote(s) or nil
	end

	-- "find" options we want to implement
	local _opts <const> = {
		"name", "iname",
		"path", "ipath",
		"lname", "ilname",
		"regex", "iregex",
	}

	-- [global] add any_* functions to os.scan
	for _, opt in pairs(_opts) do
		os.scan["any_" .. opt] = function(...) --> string or nil
			return _opt2str(opt, _map_args(_quote_or_nil, ...))
		end
	end

	-- [global] special case for -type option
	function os.scan.any_type(letters) --> string
		if letters and #letters > 0 then
			-- validate
			if letters:find("[^bcdpflsD]") then
				error(("invalid type in os.scan.any_type: %q"):format(letters))
			end

			-- CSV list of letters is a GNU extension, so here we compose a portable
			-- form, with letter deduplication
			local seen <const>, res <const> = {}, {}

			for i = 1, #letters do
				local b <const> = letters:byte(i)

				if not seen[b] then
					seen[b] = true
					res[#res + 1] = string.char(b)
				end
			end

			-- result
			return _opt2str("type", res)
		end
	end

	-- os.scan(dir, ...):for_each(fn) --> ok or (fail, error)
	local function _for_each(sc, fn)
		return shell.read(sc._cmd, function(src)
			for s in io.lines_from(src, "\0") do
				if fn(s) then
					break
				end
			end

			return true
		end)
	end

	-- os.scan(dir, ...):all() --> table or (fail, error)
	local function _all(sc)
		return shell.read(sc._cmd, function(src)
			local t <const> = {}

			for s in io.lines_from(src, "\0") do
				t[#t + 1] = s
			end

			return t
		end)
	end

	-- [global] os.scan(dir, ...opts) --> scan object
	setmetatable(os.scan, {
		__call = function(_, dir, ...)
			return {
				_cmd = _cat("find", shell.quote(dir), "-mindepth 1", _cat(...), "-print0"),
				all = _all,
				for_each = _for_each,
			}
		end
	})
end
