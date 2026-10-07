-- The connect suite's end-to-end check (.robot/suites/connect.robot): a Tablua run, an agent driving the command
-- line and the person, against a real HTTP service (server.py on 127.0.0.1) with a real keychain (a throwaway file,
-- never the login keychain) and the person's typing through a pseudo-terminal (`script`). Only the model is a
-- script. Each step asserts; the last line is "connect e2e: ok".
--
--   luajit .robot/fixtures/connect/e2e.lua      (from the repository's root)
local root = os.getenv("PWD")
package.path = root .. "/core/?.lua;" .. root .. "/core/?/init.lua;" .. root .. "/submodules/?.lua;" .. root
  .. "/submodules/tablua/core/?.lua;" .. root .. "/submodules/tablua/core/?/init.lua;" .. package.path
local json = require("ports.json")

local here = root .. "/.robot/fixtures/connect"
local tmp = io.popen("mktemp -d"):read("*l")
local KEY = "acme-" .. tostring(os.time()) .. "-s3cret"
local PORT = 18000 + os.time() % 1000
local kc, log = tmp .. "/test.keychain", tmp .. "/server.log"

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
-- the directory: index.json, acme.lua and acme.index.json here, laid out as connectory lays them out
local dir = tmp .. "/connectory"
os.execute(("mkdir -p %s/providers/acme && cp %s/index.json %s/ && cp %s/acme.lua %s/providers/acme/ && "
  .. "cp %s/acme.index.json %s/providers/acme/index.json"):format(q(dir), q(here), q(dir), q(here), q(dir), q(here), q(dir)))
local env = ("MOONSPLICE_KEYCHAIN=%s MOONSPLICE_STATE=%s MOONSPLICE_CONNECTORY=%s"):format(q(kc), q(tmp .. "/state"),
  q(dir))
local function sh(cmd)
  local p = io.popen(cmd .. " 2>&1; echo \"rc=$?\"")
  local out = p:read("*a")
  p:close()
  local rc = tonumber(out:match("rc=(%d+)%s*$"))
  return rc, out:gsub("rc=%d+%s*$", "")
end
local function check(ok, what, detail)
  if not ok then
    io.stderr:write("FAILED: " .. what .. "\n" .. tostring(detail or "") .. "\n")
    os.exit(1)
  end
  print("  ok  " .. what)
end
local function read(path)
  local f = io.open(path)
  local s = f and f:read("*a") or ""
  if f then f:close() end
  return s
end

-- the keychain and the service
os.execute(("security create-keychain -p pw %s && security unlock-keychain -p pw %s && security set-keychain-settings %s")
  :format(q(kc), q(kc), q(kc)))
os.execute(("python3 %s %d %s %s >/dev/null 2>&1 & echo $! > %s"):format(q(here .. "/server.py"), PORT, q(KEY), q(log),
  q(tmp .. "/pid")))
for _ = 1, 50 do
  if os.execute(("curl -s -o /dev/null http://127.0.0.1:%d/ready"):format(PORT)) == 0 then break end
  os.execute("sleep 0.1")
end
local function cleanup()
  os.execute("kill $(cat " .. q(tmp .. "/pid") .. ") 2>/dev/null")
  os.execute("security delete-keychain " .. q(kc) .. " 2>/dev/null")
end

-- a Tablua run whose model makes the given connect calls, then hands in; Moonsplice's real hooks behind connect
local store = require("connect.store").new{ keychain = kc }
local state = require("connect.state").open(tmp .. "/state")
local function run(calls)
  local hooks = require("connect").new(root, { store = store, state = state, connectory = dir }).hooks
  local t = require("tablua").open(require("ports.sqlite").open(":memory:"), { clock = function() return "T" end })
  local script = {}
  for _, c in ipairs(calls) do script[#script + 1] = { calls = { { "connect", c } } } end
  script[#script + 1] = { text = "Handing in; what waits on the person is listed." }
  script[#script + 1] = { text = "Still waiting on the person." }
  local results = {}
  local m = { chat = function(_, _)
    local r = assert(table.remove(script, 1), "the model was asked more than its script")
    local tc
    for i, c in ipairs(r.calls or {}) do
      tc = tc or {}
      tc[i] = { id = "c" .. #script .. i, type = "function", ["function"] = { name = c[1], arguments = json.encode(c[2]) } }
    end
    return r.text or "", { tool_calls = tc or {}, finish = tc and "tool_calls" or "stop" }
  end }
  local engine = { rows = function() return { schema = "msr/1", digest = "d0", tables = { comp = {} } } end,
    brief = function() return "comp" end, lint = function() return {} end, check = function() return {} end }
  local s = require("studio.session").new{ engine = engine, model = m, tablua = t, comp = tmp .. "/c.lua",
    sheet = tmp .. "/s.png", ask = "a ticket wall", todo = "r", exec = function() return { code = 0, stdout = "" } end,
    connect = hooks }
  local out = s:run()
  for _, r in ipairs(t.db:exec("select content from tablua_message where role = 'tool' order by i")) do
    results[#results + 1] = r.content
  end
  local seen = {}
  for _, r in ipairs(t.db:exec("select content from tablua_message")) do seen[#seen + 1] = r.content or "" end
  for _, tbl in ipairs({ "tablua_connect", "tablua_ask" }) do
    for _, r in ipairs(t.db:exec("select * from " .. tbl)) do
      for _, v in pairs(r) do seen[#seen + 1] = tostring(v) end
    end
  end
  return out, results, table.concat(seen, "\n")
end

print("connect e2e")
-- 1. the agent needs Acme, which is not connected: the person is asked, the model is told how, and never the key
local out, results, all = run({ { action = "call", op = "acme.tickets_list", args = { state = "open" }, why = "the wall" } })
check(results[1]:find("Acme is not connected", 1, true), "an unconnected service becomes an ask", results[1])
check(results[1]:find("./moonsplice connect acme", 1, true), "the model is told how the person connects it")
check(#out.asks == 1 and out.asks[1].service == "acme", "the run's result lists the ask for its driver")

-- 2. an agent driving the command line cannot connect it, and sees the open ask
local rc, text = sh(env .. " ./moonsplice connect acme </dev/null")
check(rc == 3 and text:find("needs the person at their own terminal", 1, true), "an agent cannot connect a service", text)
rc, text = sh(env .. " ./moonsplice connect --asks --json")
check(rc == 0 and json.decode(text)[1].kind == "connect", "the ask is a row the app and the command line read", text)

-- 3. the person connects it at a terminal: the key goes to the keychain without echo, the host as plain text
local typing = ("(sleep 1; printf '%%s\\n' %s; sleep 0.5; printf '127.0.0.1:%d\\n'; sleep 2)"):format(q(KEY), PORT)
rc, text = sh(typing .. " | script -q /dev/null env " .. env .. " ./moonsplice connect acme")
check(rc == 0 and text:find("Acme is connected (the test call passed)", 1, true), "the person connects Acme", text)
check(not text:find(KEY, 1, true), "the key is never echoed", text)
check(store:get("ACME_TOKEN") == KEY, "the key is in the keychain")
rc, text = sh(env .. " ./moonsplice connect --asks --json")
check(text:match("^%s*%[%]") or text:match("^%s*{}"), "the ask is settled", text)

-- 4. the agent's call now runs, signed by the host
out, results, all = run({ { action = "call", op = "acme.tickets_list", args = { state = "open" } } })
check(results[1]:find("Acme answered 200", 1, true) and results[1]:find("the lamp flickers", 1, true),
  "the run's call is signed and answered", results[1])
check(not all:find(KEY, 1, true), "the key is in no message, call row or ask row")
check(not read(tmp .. "/state/connect.json"):find(KEY, 1, true), "the key is in no connect row")

-- 5. a call that changes something waits for the person; an agent cannot approve it; the person can
out, results = run({ { action = "call", op = "acme.tickets_create", args = { title = "from the agent" } } })
check(results[1]:find("waits for the person to approve it", 1, true), "a write waits for approval", results[1])
rc, text = sh(env .. " ./moonsplice connect --approve acme acme.tickets_create --always </dev/null")
check(rc == 3, "an agent cannot approve its own call", text)
rc, text = sh("(sleep 1; printf 'o\\n'; sleep 1) | script -q /dev/null env " .. env
  .. " ./moonsplice connect --approve acme acme.tickets_create")
check(rc == 0 and text:find("acme.tickets_create: once", 1, true), "the person approves it once", text)
out, results = run({ { action = "call", op = "acme.tickets_create", args = { title = "from the agent" } },
  { action = "call", op = "acme.tickets_create", args = { title = "again" } } })
check(results[1]:find("Acme answered 201", 1, true), "the approved call runs", results[1])
check(results[2]:find("waits for the person to approve it", 1, true), "a once is used up", results[2])

-- 6. an agent driving the command line gets the same rules
rc, text = sh(env .. " ./moonsplice connect --call acme.tickets_list --json")
check(rc == 0 and text:find("the lamp flickers", 1, true), "the command line's call is signed", text)
rc, text = sh(env .. " ./moonsplice connect --call acme.tickets_create --json")
check(rc == 4 and json.decode(text).waiting == "approve", "the command line's write waits too", text)

local lines = {}
for l in read(log):gmatch("[^\n]+") do lines[#lines + 1] = json.decode(l) end
local posts, bad = 0, 0
for _, l in ipairs(lines) do
  if l.method == "POST" then posts = posts + 1 end
  if not l.key_ok and l.path ~= "/ready" then bad = bad + 1 end
end
check(posts == 1 and bad == 0, "the service saw one write, and every request carried the key", read(log))
cleanup()
check(os.execute("security find-generic-password -s moonsplice -a ACME_TOKEN >/dev/null 2>&1") ~= 0,
  "the login keychain was never touched")
print("connect e2e: ok")
