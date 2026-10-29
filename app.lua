-- [global] trim whitespace from both ends of the string
function string.trim(s) --> string
	-- see trim12 from http://lua-users.org/wiki/StringTrim
	local i <const> = s:match("^%s*()")
	return i > #s and "" or s:match(".*%S", i)
end

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

-- check result of os.execute or pipe:close(), returning 'x' on success,
-- or result of fn(x, code) on non-zero exit
local function _perr(x, fn, ok, ...)
	if ok then
		return x
	end

	local err <const>, code <const> = ...

	if math.type(code) == "integer" then
		if err == "exit" then
			return fn(x, code)
		end

		if err == "signal" then
			os.exit(128 + code)
		end
	end

	error(tostring(err))	-- should never happen
end

-- close pipe from io.popen
local function _pclose(pipe, x, fn)
	return _perr(x, fn, pipe:close())
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

-- original os.exit
local _real_exit <const> = os.exit

-- [global] os.exit replacement to make sure Lua state is closed upon exit
function os.exit(code)
	_real_exit(code, true)
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
app = {
	-- application name
	NAME = arg[0]:match("[^/]+$"),

	-- table of exit handlers
	_exit_handlers = setmetatable({}, {
		__gc = function(handlers)
			for _, fn in ipairs(handlers) do
				pcall(fn)
			end
		end
	}),
}

-- register exit handler
-- Note: any handler calling os.exit will terminate the application without
-- invoking the remaining exit handlers
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
		local just <const> = context("shell", ctx)
		local src <const> = just(io.popen(type(cmd) == "table" and table.concat(cmd, " ") or cmd))
		local data <const> = src:read("a")

		just(src:close())
		return data
	end,
}

-- [global] create automatically removed temporary directory
function os.tmpdir(ctx) --> directory name
	local tmp <const> = shell.read("mktemp -d", ctx):trim()

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
	local function _popen(cmd)
		local src <const>, err <const> = io.popen(cmd .. " 2>&1")

		if err then
			-- should never happen
			error(("failed to start command %q: %s"):format(cmd, err))
		end

		return src
	end

	local function _on_err(s)
		-- get error message from the command output
		return nil, (s:match(":%s*([^:]-)%s*$") or s)
	end

	-- read command output, assuming the command yields either valid output,
	-- or an error message, but not both
	local function _read_all_cmd(cmd) --> string or (fail, error)
		local src <const> = _popen(cmd)

		return _pclose(src, src:read("a"):trim(), _on_err)
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

		local s <const>, err <const> = _read_all_cmd(cmd)

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
		return _read_all_cmd("realpath -e " .. shell.quote(pathname))
	end
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

-- [global] directory scanner
os.scan = {}

do
	-- create substitution object for scanner
	local function _scanner(src, ...)
		if not src then
			return src, ...
		end

		local function _close()
			return src:close()
		end

		return setmetatable({
			close = _close,
		}, {
			__call = io.lines_from(src, "\0"),
			__close = _close,
		})
	end

	-- [global] start directory scan
	function os.scan.start(dir, ...)	--> iterator, or (fail, error, ...)
		local cmd <const> = _cat("find", shell.quote(dir), "-mindepth 1", _cat(...), "-print0")

		return _scanner(io.popen(cmd))
	end

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

			-- CSV list of letters is a GNU extension, so here we compose a portable form
			local seen <const>, res <const> = {}, {}	-- deduplication

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

	local function _on_err(t, code)
		-- "find" errors like "Permission denied" may still be ok for some applications
		return t, code
	end

	-- [global] scan and collect results
	function os.scan.all(dir, ...) --> table or (fail, ...)
		local src <const>, err <const> = os.scan.start(dir, ...)

		if not src then
			return nil, err
		end

		local t <const> = {}

		for s in src do
			t[#t + 1] = s
		end

		return _pclose(src, t, _on_err)
	end
end
