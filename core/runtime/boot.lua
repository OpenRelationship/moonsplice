-- What LÖVE's boot does with a game directory, for `core/runtime/`.
--
-- Three things, in LÖVE's order: make the directory's files requirable under the names LÖVE
-- gives them, run `main.lua`, then call `love.run` and keep calling the function it returns
-- until that returns an exit code. Errors go to the runtime's own `love.errorhandler`, called
-- where the error happened so its traceback is the real one, exactly as LÖVE calls it.

local runtime, argv = ...

-- Held before the comp sandbox replaces `io.open` with a refusal. LÖVE's own loader is C and
-- never sees the sandbox; this one is Lua and would.
local open, loadstring = io.open, loadstring

arg = { [0] = runtime }
for i = 1, #argv do arg[i] = argv[i] end

-- LÖVE loads a game's files with chunk names relative to the game ("painter.lua"), not absolute
-- paths, and an error message carries the chunk name. Loading them the same way keeps every
-- message -- including the ones `--json` puts in an error envelope -- the same on either host.
local function load_game_file(rel)
  local path = runtime .. "/" .. rel
  local f = open(path, "rb")
  if not f then return nil end
  local src = f:read("*a")
  f:close()
  return assert(loadstring(src, "@" .. rel))
end

-- Second in line, after `package.preload`, where LÖVE puts its own searcher.
table.insert(package.loaders, 2, function(name)
  local rel = name:gsub("%.", "/")
  local chunk = load_game_file(rel .. ".lua") or load_game_file(rel .. "/init.lua")
  if not chunk then return ("\n\tno file '%s/%s.lua' in the runtime"):format(runtime, rel) end
  return chunk
end)

local main = load_game_file("main.lua")
if not main then error("moonsplice-engine: no main.lua in " .. runtime) end

-- In another process (engine/src/session.rs, the Studio) `os.exit` would end that process, so
-- the host makes it throw an ENGINE_EXIT instead, and here it unwinds to the end of the boot.
local Exit = ENGINE_EXIT
local function exit_code(e)
  if Exit and type(e) == "table" and getmetatable(e) == Exit then return e.code end
end

local function on_error(msg)
  if exit_code(msg) then return msg end
  if love.errorhandler then
    if Exit then
      -- the handler is called, not raised through: an exit from inside a message handler would
      -- be "error in error handling"
      local ok, e = pcall(love.errorhandler, msg)
      if not ok and exit_code(e) then return e end
    else
      love.errorhandler(msg) -- the runtime's prints and exits
    end
  end
  io.stderr:write("moonsplice-engine: " .. tostring(msg) .. "\n" .. debug.traceback() .. "\n")
  io.stderr:flush()
  if Exit then return setmetatable({ code = 1 }, Exit) end
  os.exit(1)
end

do
  local ok, e = xpcall(main, on_error)
  if not ok and exit_code(e) then return exit_code(e) end
end

-- `serve` is long-lived, and the app talking to it never restarts it. While it runs, a feature
-- the engine has not ported fails the one request that reached it (core/runtime/love.lua) instead
-- of ending the session: the outline, the timeline and every frame that does not use it go on.
package.preload["serve"] = function()
  local S = load_game_file("serve/init.lua")()
  local run = S.run
  S.run = function(...)
    ENGINE_SERVING = true
    return run(...)
  end
  return S
end

local ok, step = xpcall(love.run, on_error)
if not ok and exit_code(step) then return exit_code(step) end
local code
while code == nil do
  ok, code = xpcall(step, on_error)
  if not ok and exit_code(code) then return exit_code(code) end
end
io.stdout:flush()
io.stderr:flush()
return tonumber(code) or 0
