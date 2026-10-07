-- One trial: an arm (tablua | plain) works one ask, then the oracle judges what it handed in.
--
--   luajit core/host/run.lua --arm tablua --task harbour-minute [--seed 1] [--job j1] [--writer m3]
--                        [--decider jev] [--critic m3] [--budget 10]
--   luajit core/host/run.lua --list
--
-- The oracle is independent of the arm: the gate again (lint + check), a render, a critic blind to the
-- arm and the treatment, and the per-frame hashes twice. Its row goes to .robot/ledger.sqlite (ms_trial);
-- the tablua arm's step rows go to the trial's own sheet, .robot/runs/<job>/<trial>.sqlite.
local H = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/host.lua")
local json = require("ports.json")

local o = { arm = "tablua", seed = 1, job = "dev", writer = "m3", decider = "jev", critic = "m3", budget = 10 }
local i = 1
while i <= #arg do
  local k = arg[i]:match("^%-%-(.+)$")
  if k == "list" then o.list = true; i = i + 1
  elseif k then o[k] = arg[i + 1]; i = i + 2
  else i = i + 1 end
end
o.seed, o.budget = tonumber(o.seed), tonumber(o.budget)

local asks = require("asks")
if o.list then for _, a in ipairs(asks) do print(a.id, a.kind, a.ask) end return end
local task
for _, a in ipairs(asks) do if a.id == o.task then task = a end end
assert(task, "no task " .. tostring(o.task) .. " (--list)")

local models = require("models")
local W = require("work")
local T = require("tools")
local P = require("prompts")
local sqlite = require("ports.sqlite")
local tablua = require("tablua")
local ledger = require("ledger")

local trial = ("%s-%s-%s-%d"):format(o.arm, o.writer:gsub("[^%w]", ""), task.id, o.seed)
local dir = H.root .. "/agent/runs/" .. o.job .. "/" .. trial
H.sh("rm -rf " .. H.q(dir))
local robot = H.root .. "/.robot"
H.mkdir(robot .. "/runs/" .. o.job)
local sheet_rel = "runs/" .. o.job .. "/" .. trial .. ".sqlite"
os.remove(robot .. "/" .. sheet_rel)
-- rows stamped by a counter, not the wall clock, so the same steps write the same sheet
local tick = 0
local function clock() tick = tick + 1; return ("%s#%06d"):format(trial, tick) end
local t = tablua.open(sqlite.open(robot .. "/" .. sheet_rel), { clock = clock })

-- what the tablua arm learns from: every earlier tablua trial's rows, merged into one history file attached
-- as "past" (SQLite attaches at most ten files, so they are merged rather than attached one by one)
local function history()
  local p = io.popen(("ls %s/runs/*/tablua-*.sqlite 2>/dev/null"):format(H.q(robot)))
  local paths = {}
  for path in p:lines() do if not path:find(trial, 1, true) then paths[#paths + 1] = path end end
  p:close()
  if #paths == 0 then return 0 end
  local hpath = dir .. "/history.sqlite"
  H.mkdir(dir)
  os.remove(hpath)
  local h = tablua.open(sqlite.open(hpath), { clock = clock }).db
  local tables = {}
  for _, r in ipairs(h:exec("select name from sqlite_master where type = 'table' and name like 'tablua_%'")) do
    tables[#tables + 1] = r.name
  end
  for _, path in ipairs(paths) do
    h:exec("attach database ? as s", { path })
    for _, tbl in ipairs(tables) do
      local cols = {}
      for _, c in ipairs(h:exec("pragma s.table_info(" .. tbl .. ")")) do cols[#cols + 1] = c.name end
      if #cols > 0 then
        local mine = {}
        for _, c in ipairs(h:exec("pragma main.table_info(" .. tbl .. ")")) do mine[c.name] = true end
        local both = {}
        for _, c in ipairs(cols) do if mine[c] then both[#both + 1] = c end end
        local list = table.concat(both, ", ")
        pcall(h.exec, h, ("insert or ignore into main.%s (%s) select %s from s.%s"):format(tbl, list, list, tbl))
      end
    end
    h:exec("detach database s")
  end
  t:attach("past", hpath)
  return #paths
end

models.reset()
local writer = models.writer(o.writer, "writer")
local critic = models.writer(o.critic, "critic")
local work = W.new({ ask = task.ask, kind = task.kind, dir = dir, writer = writer, critic = critic })
local t0 = H.now()
local result
local ok, err = pcall(function()
  if o.arm == "tablua" then
    local past = history()
    work:say(("learning from %d earlier tablua trials"):format(past))
    result = require("world").run(work, { budget = o.budget, decider = models.decider(o.decider), writer = writer,
      tablua = t, todo = o.job .. ":" .. trial, rank = o.rank ~= "off",
      log = function(line) work:say(line) end })
  elseif o.arm == "plain" then
    result = require("plain").run(work, { budget = o.budget })
  else
    error("no arm " .. o.arm)
  end
end)
local seconds = H.now() - t0
local agent_cost = models.meter.cost
if not ok then result = { steps = 0, ended = "died: " .. tostring(err), decisions = {} } end

-- the oracle
local final = work.code and work:final()
local gate = final and T.gate(final) or { pass = false, errors = 1, findings = { "no file" } }
local judged, stable, frames = nil, nil, 0
if gate.pass then
  local blind = W.new({ ask = task.ask, kind = task.kind, dir = dir .. "/oracle", writer = writer, critic = critic })
  blind.code, blind.file, blind.gate, blind.version = work.code, final, gate, work.version
  local r = blind:look(models.writer(o.critic, "oracle"), "oracle")
  if type(r) == "table" then judged = r end
  stable, frames = T.stable(final)
end

local row = {
  job = o.job, trial = trial, task = task.id, kind = task.kind, arm = o.arm, writer = o.writer,
  decider = o.arm == "tablua" and o.decider or "", seed = o.seed,
  gate = gate.pass and 1 or 0, errors = gate.errors, critic = judged and judged.mean or false,
  critic_low = judged and judged.low or false, stable = stable == nil and false or (stable and 1 or 0),
  steps = result.steps, ended = result.ended, versions = work.version, looks = work.looks or 0,
  cost = agent_cost, oracle_cost = models.meter.cost - agent_cost, seconds = seconds,
  sheet = sheet_rel, scores = judged and json.encode(judged.scores) or "", notes = judged and tostring(judged.notes or "") or "",
  decisions = json.encode(result.decisions or {}), at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
}
local l = sqlite.open(robot .. "/ledger.sqlite")
ledger.open(l)
require("mskeywords").open(l)
local cols, marks, vals = {}, {}, {}
for k, v in pairs(row) do cols[#cols + 1] = k end
table.sort(cols)
for n, k in ipairs(cols) do marks[n] = "?"; vals[n] = row[k] end
l:exec(("insert or replace into ms_trial (%s) values (%s)"):format(table.concat(cols, ", "), table.concat(marks, ", ")), vals)
H.write(dir .. "/trial.json", json.encode(row))
H.write(dir .. "/log.txt", table.concat(work.log, "\n") .. "\n")
print(("%s  gate=%d critic=%s low=%s stable=%s steps=%d versions=%d cost=$%.4f %.0fs  ended=%s"):format(trial, row.gate,
  judged and ("%.2f"):format(judged.mean) or "-", judged and tostring(judged.low) or "-", tostring(stable),
  row.steps, row.versions, agent_cost, seconds, tostring(result.ended)))
