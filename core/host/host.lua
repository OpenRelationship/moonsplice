-- The agent's host: where tablua is, how to reach the network, the keys, and the shell.
-- tablua (the harness, ~/tablua or $TABLUA) is pure Lua; this is the LuaJIT host it asks for:
-- fetch over libcurl (tablua's ports.curl), SQLite over the FFI (ports.sqlite), keys from the
-- environment or the macOS keychain. A key is never printed, logged or written to a row.
local H = {}

local function abs(p)
  if p:sub(1, 1) == "/" then return p end
  local h = io.popen("pwd"); local cwd = h:read("*l"); h:close()
  return p == "." and cwd or (cwd .. "/" .. p)
end
-- the repository: the folder holding core/host/ (from the script's path), else $MOONSPLICE_ROOT, else here
local script = arg and arg[0] or ""
H.root = abs(script:match("^(.*)/core/host/[^/]+$") or (script:match("^core/host/") and ".")
  or script:match("^(.*)/%.robot/[^/]+$") or (script:match("^%.robot/") and ".") or os.getenv("MOONSPLICE_ROOT") or ".")
H.tablua = os.getenv("TABLUA") or (H.root .. "/submodules/tablua")

package.path = table.concat({
  H.root .. "/core/host/?.lua", H.root .. "/.robot/?.lua",
  H.tablua .. "/core/?.lua", H.tablua .. "/core/?/init.lua",
  H.tablua .. "/.robot/?.lua",
  package.path,
}, ";")

-- a command's output and its exit code (read from the output: not every popen gives the code)
function H.sh(cmd)
  local p = assert(io.popen(cmd .. ' 2>&1; echo "@rc $?"'))
  local s = p:read("*a")
  p:close()
  local out, code = s:match("^(.-)@rc (%d+)%s*$")
  return out or s, tonumber(code) or 1
end

function H.q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

function H.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

function H.write(path, s)
  local f = assert(io.open(path, "wb"))
  f:write(s); f:close()
end

function H.mkdir(path) H.sh("mkdir -p " .. H.q(path)) end

-- keys: the environment first, then the keychain (service com.moonsplice.studio, account = name)
local cache = {}
function H.key(name, env)
  if cache[name] ~= nil then return cache[name] or nil end
  local v = env and os.getenv(env)
  if not v or v == "" then
    local p = io.popen("security find-generic-password -s com.moonsplice.studio -a " .. name .. " -w 2>/dev/null")
    v = p and p:read("*l") or nil
    if p then p:close() end
  end
  cache[name] = (v and v ~= "") and v or false
  return cache[name] or nil
end

local fetch = require("ports.curl").fetch
H.net = { fetch = fetch, now = os.time, sleep = function(s) H.sh("sleep " .. tonumber(s)) end }

function H.now()
  local p = io.popen("perl -MTime::HiRes=time -e 'printf \"%.3f\", time' 2>/dev/null")
  local s = p and tonumber(p:read("*l"))
  if p then p:close() end
  return s or os.time()
end

package.loaded.host = H
return H
