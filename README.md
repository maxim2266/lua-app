## lua-app: runtime and API for writing Linux utilities in Lua.

This is an ongoing project, and one day I may even write some documentation for it.

Requires Lua version 5.4.

### Usage
First, the file `app.lua` can simply be included into a project, where it must be the first amongst
all other source files. The following Makefile fragment gives an idea of how to compile such a project
into a single binary:
```make
# Lua version
LUA_VER := 5.4

# compilation
your-binary: path/to/app.lua one.lua two.lua three.lua
	luac$(LUA_VER) -o $@ $^
	sed -i '1s|^|\#!/usr/bin/env lua$(LUA_VER)\n|' $@
	chmod 0755 $@

```

Second, running `make` in this project produces a binary called `luax`, which has all the
runtime pre-compiled in it, and an external script can be invoked like `luax your-file.lua`.
_Hint_: shebang like `#!luax` works as well, assuming `luax` is located somewhere on the $PATH.
