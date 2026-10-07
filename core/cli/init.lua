-- Moonsplice's command line, run by ./moonsplice as `luajit core/cli/init.lua ROOT COMMAND ...`. Most commands are
-- the engine's (native/engine running core/runtime): render, hash, lint, check, rows, patch, gate, expect, tabicl,
-- serve. sheet renders and tiles a contact sheet (cli/sheet.lua); play runs a game in Bevy's window; connect reaches
-- other people's apps (cli/connect.lua); studio runs Tablua's agent on a comp (cli/studio.lua).
local root = assert(arg[1], "usage: luajit core/cli/init.lua ROOT COMMAND ...")
local args = {}
for i = 3, #arg do args[#args + 1] = arg[i] end
local cmd = arg[2]

-- core, then the submodules: connectory as connectory.lua.*, and Tablua's core (its ports and the harness)
package.path = root .. "/core/?.lua;" .. root .. "/core/?/init.lua;" .. root .. "/submodules/?.lua;" .. root
  .. "/submodules/tablua/core/?.lua;" .. root .. "/submodules/tablua/core/?/init.lua;" .. package.path

local M = {}

function M.q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function die(msg, code)
  io.stderr:write("moonsplice: " .. msg .. "\n")
  os.exit(code or 1)
end

-- os.execute's status as an exit code, on Lua 5.1 (LuaJIT) and 5.2+ alike
local function status(a, _, c)
  if type(a) == "number" then return a >= 256 and math.floor(a / 256) or a end
  return a and 0 or (c or 1)
end

-- the engine binary: $MOONSPLICE_ENGINE, else native/target/release, built once if missing
function M.engine()
  local env = os.getenv("MOONSPLICE_ENGINE")
  if env and env ~= "" and exists(env) then return env end
  local bin = root .. "/native/target/release/moonsplice-engine"
  if exists(bin) then return bin end
  io.stderr:write("moonsplice: building the engine once (cargo build --release -p moonsplice-engine)\n")
  local rc = status(os.execute(("cd %s && CARGO_INCREMENTAL=0 cargo build --release -q -p moonsplice-engine >&2")
    :format(M.q(root .. "/native"))))
  if rc ~= 0 or not exists(bin) then die("moonsplice-engine is not built and cargo could not build it") end
  return bin
end

-- run the engine on core/runtime with these arguments; stdin, stdout and stderr are the caller's unless `redirect`
-- (a shell redirection such as "> log 2>&1") says otherwise
function M.run_engine(list, redirect)
  local parts = {}
  for _, a in ipairs(list) do parts[#parts + 1] = M.q(a) end
  local cwd = os.getenv("PWD") or "."
  local line = ("MOONSPLICE_HEADLESS=1 MOONSPLICE_CWD=%s MOONSPLICE_ROOT=%s %s %s %s"):format(M.q(cwd),
    M.q(os.getenv("MOONSPLICE_ROOT") or root), M.q(M.engine()), M.q(root .. "/core/runtime"), table.concat(parts, " "))
    .. (redirect and (" " .. redirect) or "")
  return status(os.execute(line))
end

local function need(n, usage)
  for i = 1, n do if not args[i] then die("usage: moonsplice " .. usage) end end
end

local function rest(from)
  local out = {}
  for i = from, #args do out[#out + 1] = args[i] end
  return out
end

local function flag(first, list)
  local out = { first }
  for _, a in ipairs(list) do out[#out + 1] = a end
  return out
end

local ENGINE = { render = true, hash = true, lint = true, check = true, rows = true, gate = true, tabicl = true }

local USAGE = [[usage: moonsplice COMMAND [args]
  render COMP -o OUT.mp4        hash COMP        lint COMP [--json]        check COMP [--json]
  rows COMP [--json] [--brief] [-o NEW.lua]      the comp as rows (.robot/docs/rows.robot)
  patch COMP PATCHES.json [--json]               expect COMP ROWS.json [--json]       gate COMP [--json]
  sheet COMP OUT.png [--json] [--n 6]            a contact sheet: picks, seconds, labelled
  tabicl                        one JSON body per line on stdin, one {probas, ms} per line out
  serve                         the editor's frame server (MOONSPLICE_SERVE_DIR)
  play COMP                     a game in a window (Bevy)
  connect SERVICE | --list | --asks | --find WORDS | --calls SERVICE | --approve SERVICE OP | --call OP [ARGS.json]
                                other people's apps through connectory (.robot/docs/connect.robot)
  studio --comp COMP --ask TEXT [--kind video|game]   a Tablua run on a comp, with connect]]

M.root, M.args = root, args

if cmd == nil or cmd == "help" or cmd == "-h" or cmd == "--help" then
  print(USAGE)
  os.exit(cmd == nil and 1 or 0)
elseif ENGINE[cmd] then
  os.exit(M.run_engine(flag("--" .. cmd, args)))
elseif cmd == "patch" then
  need(2, "patch COMP PATCHES.json [--json]")
  os.exit(M.run_engine(flag("--patch", { args[2], args[1], (table.unpack or unpack)(rest(3)) })))
elseif cmd == "expect" then
  need(2, "expect COMP ROWS.json [--json]")
  os.exit(M.run_engine(flag("--expect", { args[2], args[1], (table.unpack or unpack)(rest(3)) })))
elseif cmd == "serve" then
  if not os.getenv("MOONSPLICE_SERVE_DIR") then die("serve: set MOONSPLICE_SERVE_DIR to a writable directory") end
  os.exit(M.run_engine(flag("--serve", args)))
elseif cmd == "sheet" then
  need(2, "sheet COMP OUT.png [--json] [--n 6]")
  os.exit(require("cli.sheet").run(M, args))
elseif cmd == "connect" then
  os.exit(require("cli.connect").run(M, args))
elseif cmd == "studio" then
  os.exit(require("cli.studio").run(M, args))
elseif cmd == "play" then
  local bin = os.getenv("MOONSPLICE_PLAY") or (root .. "/native/target/release/moonsplice-play")
  if not exists(bin) then die("moonsplice-play is not built (cargo build --release -p moonsplice-play in native/)", 2) end
  local parts = {}
  for _, a in ipairs(args) do parts[#parts + 1] = M.q(a) end
  os.exit(status(os.execute(("MOONSPLICE_ROOT=%s %s %s"):format(M.q(root), M.q(bin), table.concat(parts, " ")))))
elseif cmd == "preview" then
  die("use 'moonsplice play' for games, or open the comp in the editor (editor/)")
else
  -- doctor, verify, feedback, agent, tts and the rest were Node, Python or bash wrappers; port/done lists them
  die(("'%s' is not ported yet (see luajit .robot/run.lua port, What Is Rewritten By Hand)"):format(cmd), 3)
end
