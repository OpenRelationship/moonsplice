-- Moonsplice's claims, run with tablua's Robot engine and kept in tablua's ledger format
-- (submodules/tablua/.robot/README.md: kill numbers written first, a red proof per claim, verdicts
-- holds / KILLED / BROKEN / BLIND / unproven / unknown, runs locked to a commit).
--
--   luajit .robot/run.lua [word ...]     every claims/*.robot, or those whose path holds a word
--   luajit .robot/run.lua reds           each red proof: does it fail at an assertion?
--   luajit .robot/run.lua history        every claim's verdicts, run by run
--   luajit .robot/run.lua trials [job]   the trial rows core/host/run.lua wrote
local here = arg[0]:match("^(.*)/[^/]+$") or "."
local H = dofile(here .. "/../core/host/host.lua")
local root = H.root .. "/.robot"

local robot = require("robot")
local tablua = require("tablua")
local sqlite = require("ports.sqlite")
local ledger = require("ledger")
local ms = require("mskeywords")

local t = tablua.open(sqlite.open(root .. "/ledger.sqlite"))
ledger.open(t.db)
ms.open(t.db)

local cmd = arg[1]
if cmd == "history" then
  for _, r in ipairs(ledger.history(t.db)) do print(("%-22s %-58s %s"):format(r.todo, r.name, r.runs)) end
  local c = ledger.calibration(t.db)
  print(("predictions: %d of %d right"):format(c.right, c.predicted))
  if c.brier then print(("  Brier %.3f, log loss %.3f"):format(c.brier, c.log_loss)) end
  return
elseif cmd == "trials" then
  local q = "select job, trial, gate, critic, critic_low, stable, steps, versions, cost, seconds, ended from ms_trial"
  local rows = arg[2] and t.db:exec(q .. " where job = ? order by trial", { arg[2] }) or t.db:exec(q .. " order by job, trial")
  for _, r in ipairs(rows) do
    print(("%-10s %-46s gate=%s critic=%s low=%s stable=%s steps=%s v=%s $%.3f %4.0fs %s"):format(r.job, r.trial,
      tostring(r.gate), r.critic and ("%.2f"):format(r.critic) or "-", tostring(r.critic_low or "-"), tostring(r.stable),
      tostring(r.steps), tostring(r.versions), r.cost or 0, r.seconds or 0, r.ended or ""))
  end
  return
end

local function lock(path)
  local rel = path:sub(#H.root + 2)
  local id = H.sh(("git -C %s log -1 --format=%%h -- %s"):format(H.q(H.root), H.q(rel))):gsub("%s+", "")
  local _, changed = H.sh(("git -C %s diff --quiet HEAD -- %s"):format(H.q(H.root), H.q(rel)))
  local tracked = H.sh(("git -C %s ls-files -- %s"):format(H.q(H.root), H.q(rel))):gsub("%s+", "") ~= ""
  return id, (id == "" or not tracked or changed ~= 0)
end

local function deepest(node)
  for _, c in ipairs(node.children or node.body or {}) do if c.status == "FAIL" then return deepest(c) end end
  return node
end

local files = {}
local p = io.popen('ls "' .. root .. '"/claims/*.robot 2>/dev/null')
for path in p:lines() do
  local want = #arg == 0 or (#arg == 1 and arg[1] == "reds")
  for k, w in ipairs(arg) do if not (k == 1 and w == "reds") and path:find(w, 1, true) then want = true end end
  if want then files[#files + 1] = path end
end
p:close()

local lib = ms.library(root)

if cmd == "reds" then
  local bad = 0
  for _, path in ipairs(files) do
    local f = assert(io.open(path))
    local res = robot.run(robot.parse(f:read("*a")), { libraries = { lib } })
    f:close()
    print(path:match("(claims/.*)%.robot$"))
    for _, c in ipairs(res.tests) do
      if c.name:find(" %(red%)$") then
        local ok = c.status == "FAIL" and ledger.assertion(c)
        if not ok then bad = bad + 1 end
        print(("  %s  %-62s fails at %s"):format(ok and "red " or "BAD ", c.name,
          c.status == "FAIL" and tostring(deepest(c).name) or ("nothing: " .. c.status)))
        if not ok and c.message then print("        " .. c.message:gsub("\n", " "):sub(1, 160)) end
      end
    end
  end
  print(bad == 0 and "every red proof fails at an assertion" or (bad .. " red proofs show nothing"))
  os.exit(bad == 0 and 0 or 1)
end

local MARK = { holds = "holds   ", KILLED = "KILLED  ", broken = "BROKEN  ", BLIND = "BLIND   ", unproven = "unproven",
  unknown = "unknown " }
local totals = {}
for _, path in ipairs(files) do
  local f = assert(io.open(path))
  local text = f:read("*a")
  f:close()
  local todo = path:match("(claims/.*)%.robot$")
  local commit, draft = lock(path)
  local res = robot.run(robot.parse(text), { libraries = { lib }, clock = os.clock })
  local n = (t.db:exec("select coalesce(max(n), 0) + 1 as n from claims_run where todo = ?", { todo })[1]).n
  t:results(todo, n, res, todo)
  local verdicts = ledger.verdicts(res)
  local flags = ledger.record(t.db, todo, n, commit, draft, verdicts, ledger.hashes(text))
  print(("%s  run %d  %s"):format(todo, n, draft and "DRAFT: the file is not committed as it ran, so this run does not count"
    or ("locked at " .. commit)))
  for _, v in ipairs(verdicts) do
    totals[v.verdict] = (totals[v.verdict] or 0) + 1
    print(("  %s  %-60s %s"):format(MARK[v.verdict] or v.verdict, v.name, table.concat(v.tags, " ")))
    if v.verdict ~= "holds" then print("            " .. (v.message ~= "" and v.message or ("red proof: " .. v.red))
      :gsub("\n", " "):sub(1, 170)) end
    if v.predict ~= "" then
      print(("            predicted %s%s: %s"):format(v.predict, v.p and ("@" .. v.p) or "",
        v.predict == v.verdict and "right" or (v.verdict == "unknown" and "pending" or "WRONG")))
    end
    if flags[v.name] then print("            ! " .. flags[v.name]) end
  end
end
print(("%d hold, %d killed, %d broken, %d blind, %d unproven, %d unknown"):format(totals.holds or 0,
  totals.KILLED or 0, totals.broken or 0, totals.BLIND or 0, totals.unproven or 0, totals.unknown or 0))
