-- The keywords Moonsplice's claims measure with. Same names and rules as tablua's (.robot in ~/tablua):
-- each measures, none decides; a measure with too few rows skips, so a claim with no evidence is unknown.
--
--   Use Runs    job ...                 every ms_trial row of these jobs (core/host/run.lua writes them), and the
--                                        tablua arm's step rows from each trial's sheet, todo named trial:todo
--   Use Fixture    sql    ...           a fresh in-memory file with the same tables: a red proof's rows
--   Brier Held Out By Trial    glob    min=n    tablua's studio step rows from each trial sheet matching glob,
--                                        each trial held out in turn: [tabicl, logistic, base rate, rows, trials]
--   Use TabICL Parity    dir            ms_parity rows: the Candle TabICL (tabicl/) against tablua-local's
--                                        fixtures in dir, measured now by moonsplice-tabicl parity --json
--   Needs At Least    count    min    what
--   Value Of    sql    |    Count Of    sql    |    Mean Of    sql    min=n
--   AUROC Against Shuffled    sql    min=n     rows (score, label): [auc, null, p]
--   Gap Against Shuffled    sql    min=n       rows (value, group 0|1): [gap, null, p]
local robot = require("robot")
local sqlite = require("ports.sqlite")
local tablua = require("tablua")
local stats = require("stats")
local json = require("ports.json")

local M = {}

M.ddl = [[
create table if not exists ms_trial (
  job text not null, trial text not null, task text not null default '', kind text not null default '',
  arm text not null default '', writer text not null default '', decider text not null default '',
  seed integer, gate integer, errors integer, critic real, critic_low real, stable integer,
  steps integer, ended text not null default '', versions integer, looks integer,
  cost real, oracle_cost real, seconds real, sheet text not null default '', scores text not null default '',
  notes text not null default '', decisions text not null default '', at text not null default '',
  primary key (job, trial));
create table if not exists ms_parity (
  fixture text primary key, level1 real, encoded real, member_x real, matched integer, members integer,
  level3 real);
]]

function M.open(db) db:exec(M.ddl) end

M.pooled = { "tablua_state", "tablua_candidate", "tablua_decision", "tablua_outcome", "tablua_prediction" }

local function skip(why) error({ robot = true, skip = true, message = why }, 0) end

local function min_of(arg, default)
  return tonumber(tostring(arg or ""):match("^min=(%d+)$") or "") or default
end

function M.library(root)
  local lib = robot.library()
  local db

  local function fresh()
    db = tablua.open(sqlite.open(":memory:")).db
    M.open(db)
  end
  local function rows(sql)
    assert(db, "Use Runs or Use Fixture first")
    return db:exec(sql)
  end

  lib:add("Use Runs", function(...)
    local jobs = { ... }
    fresh()
    local l = sqlite.open(root .. "/ledger.sqlite")
    M.open(l)
    local marks = ("?, "):rep(#jobs):sub(1, -3)
    local got = l:exec("select * from ms_trial where job in (" .. marks .. ") order by job, trial", jobs)
    if #got == 0 then skip("no trials in " .. table.concat(jobs, ", ")) end
    for _, r in ipairs(got) do
      local cols, ms, vals = {}, {}, {}
      for k, v in pairs(r) do cols[#cols + 1] = k; ms[#ms + 1] = "?"; vals[#vals + 1] = v end
      db:exec(("insert into ms_trial (%s) values (%s)"):format(table.concat(cols, ", "), table.concat(ms, ", ")), vals)
      local path = root .. "/" .. r.sheet
      local f = io.open(path, "rb")
      if f and r.arm == "tablua" then
        f:close()
        db:exec("attach database ? as s", { path })
        for _, tbl in ipairs(M.pooled) do
          local mine, have = {}, {}
          for _, c in ipairs(db:exec("pragma main.table_info(" .. tbl .. ")")) do mine[c.name] = true end
          for _, c in ipairs(db:exec("pragma s.table_info(" .. tbl .. ")")) do if mine[c.name] then have[#have + 1] = c.name end end
          if #have > 0 then
            local sel = {}
            for i, c in ipairs(have) do sel[i] = c == "todo" and "? || ':' || todo" or c end
            db:exec(("insert or ignore into main.%s (%s) select %s from s.%s"):format(tbl, table.concat(have, ", "),
              table.concat(sel, ", "), tbl), { r.trial })
          end
        end
        db:exec("detach database s")
      elseif f then f:close() end
    end
  end)

  lib:add("Use Fixture", function(...)
    fresh()
    for _, sql in ipairs({ ... }) do db:exec(sql) end
  end)

  lib:add("Use TabICL Parity", function(dir)
    fresh()
    dir = tostring(dir):gsub("^~", os.getenv("HOME") or "~")
    local bin = root .. "/../target/release/moonsplice-tabicl"
    local p = io.popen(("'%s' parity --json '%s'/*-e[0-9]*.json 2>&1"):format(bin, dir))
    local out = p:read("*a")
    p:close()
    for line in out:gmatch("[^\n]+") do
      local ok, r = pcall(json.decode, line)
      if not ok or type(r) ~= "table" or not r.fixture then skip("moonsplice-tabicl: " .. line) end
      db:exec("insert into ms_parity values (?, ?, ?, ?, ?, ?, ?)",
        { r.fixture, r.level1, r.encoded, r.member_x, r.matched, r.members, r.level3 })
    end
  end)

  -- one trial's labelled rows, exactly as tablua's ranker sees them (studio.features.learner)
  local function trial_rows(path)
    local t = tablua.open(sqlite.open(path))
    local tbl, labels = require("studio.features").learner(t).training()
    return tbl, labels
  end

  local function tabicl_probs(train, labels, test)
    local body = json.encode({ train = { columns = train.columns, rows = json.array(train.rows) },
      test = { columns = train.columns, rows = json.array(test) }, labels = json.array(labels),
      categorical = json.array(train.categorical) })
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, "wb")); f:write(body, "\n"); f:close()
    local p = io.popen(("'%s/../bin/moonsplice' tabicl < '%s' 2>&1"):format(root, tmp))
    local out = p:read("*a"); p:close(); os.remove(tmp)
    local ok, r = pcall(json.decode, out)
    if not ok or type(r) ~= "table" or not r.probas then error("tabicl: " .. out, 0) end
    local ps = {}
    for i, pr in ipairs(r.probas) do ps[i] = pr[2] end
    return ps
  end

  -- the baseline: L2 logistic regression, categoricals one-hot over the training values, numbers
  -- standardised on the training rows, 2000 steps of full-batch gradient descent
  local function logistic_probs(train, labels, test)
    local cat = {}
    for _, j in ipairs(train.categorical) do cat[j + 1] = true end
    local ncol = #train.columns
    local vocab, mu, sd = {}, {}, {}
    for j = 1, ncol do
      if cat[j] then
        vocab[j] = {}
        for _, r in ipairs(train.rows) do vocab[j][tostring(r[j])] = true end
      else
        local s, s2, n = 0, 0, 0
        for _, r in ipairs(train.rows) do local v = tonumber(r[j]) or -1; s, s2, n = s + v, s2 + v * v, n + 1 end
        mu[j] = s / n; sd[j] = math.sqrt(math.max(s2 / n - mu[j] ^ 2, 0)) + 1e-6
      end
    end
    local function x(r)
      local v = { 1 }
      for j = 1, ncol do
        if cat[j] then
          local keys = {}
          for k in pairs(vocab[j]) do keys[#keys + 1] = k end
          table.sort(keys)
          for _, k in ipairs(keys) do v[#v + 1] = tostring(r[j]) == k and 1 or 0 end
        else
          v[#v + 1] = ((tonumber(r[j]) or -1) - mu[j]) / sd[j]
        end
      end
      return v
    end
    local X = {}
    for i, r in ipairs(train.rows) do X[i] = x(r) end
    local d = #X[1]
    local w = {}
    for k = 1, d do w[k] = 0 end
    local function p(v) local z = 0; for k = 1, d do z = z + w[k] * v[k] end; return 1 / (1 + math.exp(-z)) end
    for _ = 1, 2000 do
      local g = {}
      for k = 1, d do g[k] = (k > 1 and 0.01 * w[k] or 0) end
      for i, v in ipairs(X) do
        local e = p(v) - labels[i]
        for k = 1, d do g[k] = g[k] + e * v[k] / #X end
      end
      for k = 1, d do w[k] = w[k] - 0.5 * g[k] end
    end
    local ps = {}
    for i, r in ipairs(test) do ps[i] = p(x(r)) end
    return ps
  end

  lib:add("Brier Held Out By Trial", function(glob, min)
    local trials = {}
    local p = io.popen("ls " .. tostring(glob):gsub("^~", os.getenv("HOME") or "~") .. " 2>/dev/null")
    for path in p:read("*a"):gmatch("[^\n]+") do
      local ok, tbl, labels = pcall(trial_rows, path)
      if ok and #labels > 0 then trials[#trials + 1] = { tbl = tbl, labels = labels } end
    end
    p:close()
    local total = 0
    for _, tr in ipairs(trials) do total = total + #tr.labels end
    if #trials < 2 then skip(("%d trials with labelled steps, 2 needed"):format(#trials)) end
    if total < min_of(min, 20) then skip(("%d labelled steps, %d needed"):format(total, min_of(min, 20))) end
    local sums, n = { 0, 0, 0 }, 0
    for k, held in ipairs(trials) do
      local train = { columns = held.tbl.columns, categorical = held.tbl.categorical, rows = {} }
      local labels, pos = {}, 0
      for i, tr in ipairs(trials) do
        if i ~= k then
          for j, r in ipairs(tr.tbl.rows) do train.rows[#train.rows + 1] = r; labels[#labels + 1] = tr.labels[j]; pos = pos + tr.labels[j] end
        end
      end
      local base = pos / #labels
      local a = (pos > 0 and pos < #labels) and tabicl_probs(train, labels, held.tbl.rows) or nil
      local b = logistic_probs(train, labels, held.tbl.rows)
      for i, y in ipairs(held.labels) do
        local pa = a and a[i] or base
        sums[1] = sums[1] + (pa - y) ^ 2
        sums[2] = sums[2] + (b[i] - y) ^ 2
        sums[3] = sums[3] + (base - y) ^ 2
        n = n + 1
      end
    end
    return { sums[1] / n, sums[2] / n, sums[3] / n, n, #trials }
  end)

  -- TabICL's margin over the better of logistic and the base rate, as one number for Should Be True:
  -- tablua's expression evaluator substitutes ${b} as text and cannot index it (${b}[0] failed to
  -- evaluate, which read as a kill at run 7)
  lib:add("Brier Scores", function(a, b, c) return { tonumber(a), tonumber(b), tonumber(c), 40, 2 } end)
  lib:add("TabICL Margin", function(b)
    if type(b) ~= "table" or #b < 3 then error({ robot = true, message = "no Brier scores" }, 0) end
    return math.min(b[2], b[3]) - b[1]
  end)

  lib:add("Needs At Least", function(count, min, what)
    if (tonumber(count) or 0) < (tonumber(min) or 0) then
      skip(("%s: %s of %s needed"):format(what or "rows", tostring(count), tostring(min)))
    end
  end)

  lib:add("Value Of", function(sql)
    local row = rows(sql)[1]
    if not row then return nil end
    local _, v = next(row)
    return v == nil and 0 or v
  end)

  lib:add("Count Of", function(sql) return #rows(sql) end)

  lib:add("Mean Of", function(sql, min)
    local xs = {}
    for _, r in ipairs(rows(sql)) do local _, v = next(r); if tonumber(v) then xs[#xs + 1] = tonumber(v) end end
    if #xs < min_of(min, 3) then skip(("%d values, %d needed"):format(#xs, min_of(min, 3))) end
    local s = 0
    for _, x in ipairs(xs) do s = s + x end
    return s / #xs
  end)

  local function two(sql, min, measure)
    local a, b = {}, {}
    local q = rows(sql)
    for _, r in ipairs(q) do
      local keys = {}
      for k in pairs(r) do keys[#keys + 1] = k end
      table.sort(keys)
      -- the query's two columns as named x and y
      a[#a + 1], b[#b + 1] = tonumber(r.x), tonumber(r.y)
    end
    if #a < min_of(min, 10) then skip(("%d rows, %d needed"):format(#a, min_of(min, 10))) end
    local res = stats.shuffled(measure, a, b, 999, 1)
    if not res or not res.observed then skip("both kinds of label are needed") end
    return { res.observed, res.null, res.p }
  end
  lib:add("AUROC Against Shuffled", function(sql, min) return two(sql, min, stats.auroc) end)
  lib:add("Gap Against Shuffled", function(sql, min) return two(sql, min, stats.gap) end)

  return lib
end

return M
