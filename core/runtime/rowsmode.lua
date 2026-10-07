-- `moonsplice rows` and `moonsplice patch` (.robot/docs/rows.robot §6): the comp as rows, and typed
-- patches applied to a comp authored as rows. JSON on stdout and exit 0 whenever the command ran;
-- a rejected patch is data.
local R = require("moonsplice.rows")
local M = {}

local function sha1(s)
  return love.data.encode("string", "hex", love.data.hash("sha1", s))
end

local function root()
  return os.getenv("MOONSPLICE_ROOT")
    or (love.filesystem and love.filesystem.getSource and love.filesystem.getSource():gsub("/core/runtime/?$", "")) or "."
end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- the source text of a function the object API was given (a view), for showing it as a system
local function source_of(fn)
  local info = debug.getinfo(fn, "S")
  if not info or not info.source or info.source:sub(1, 1) ~= "@" then return "-- (no source)" end
  local f = _MOONSPLICE_IOOPEN(info.source:sub(2), "r")
  if not f then return "-- (no source)" end
  local lines, n = {}, 0
  for line in f:lines() do
    n = n + 1
    if n >= info.linedefined and n <= info.lastlinedefined then lines[#lines + 1] = line end
  end
  f:close()
  return table.concat(lines, "\n")
end

local function tables(rows)
  local t = {}
  for _, name in ipairs(R.TABLES) do t[name] = rows[name] end
  t.comp = next(t.comp) and t.comp or setmetatable({}, R.OBJECT)
  t.game = next(t.game) and t.game or setmetatable({}, R.OBJECT)
  return t
end

function M.dump(comp)
  local views = {}
  if not comp.rows then for i, fn in ipairs(comp._views or {}) do views[i] = source_of(fn) end end
  return R.dump(comp, { nodes = comp.nodes, views = views, defaults = require("moonsplice").NODE_DEFAULTS,
    source_of = source_of })
end

function M.digest(rows) return sha1(R.json(tables(rows))) end

-- `moonsplice rows COMP --brief`: the comp as a model should read it. The rows tables are the right
-- form for a sheet and a learner and the wrong one for a language model, which has to join 190 prop rows
-- to know what t4 is. This is one line per node, in draw order with children indented, its keys with
-- fact references resolved, what systems set on it; then the systems by what they write and spawn, the
-- expectations held or failing, and the open errors and warnings. Read from the evaluated comp, so it
-- says what the code does, not what anyone declared.
local findings_of -- below; check's findings for the brief
local function brief(comp, rows, path)
  local lint = require("moonsplice.lint")
  local fs = lint.run(comp, { fps = comp.fps or 30 })
  -- and check's, measured on rendered frames (contrast, overflow): about a second, and the writer
  -- reads no other findings
  local checked = 0
  if path then
    local ok, more = pcall(findings_of, path, "check")
    if ok then
      for _, f in ipairs(more) do
        f.node = f.node or (f.id ~= "" and f.id or nil)
        fs[#fs + 1] = f
        checked = checked + 1
      end
    end
  end
  local o = {}
  local function w(x) o[#o + 1] = x end
  local function val(v)
    if type(v) == "string" then
      if v:match("^/.+/[^/]+$") then v = v:match("([^/]+)$") end
      return ("%q"):format(#v > 60 and (v:sub(1, 57) .. "...") or v)
    elseif type(v) == "number" then return (("%.4g"):format(v))
    elseif type(v) == "table" then local j = R.json(v); return #j > 60 and (j:sub(1, 57) .. "...") or j end
    return tostring(v)
  end
  local facts = {}
  for _, f in ipairs(comp.derived or {}) do
    if (f.t0 or 0) <= comp.duration then
      facts[f.pred] = facts[f.pred] or {}
      table.insert(facts[f.pred], f)
    end
  end
  local function tref(t)
    if type(t) == "number" then return ("%.2fs"):format(t) end
    local ok, v = pcall(R.fact_time, t, comp.derived or {})
    return ok and ("%s(%.2fs)"):format(t, v) or tostring(t)
  end
  w(("comp %dx%d, %gs at %d fps, background %s; digest %s"):format(comp.width, comp.height, comp.duration,
    comp.fps or 30, val(rows.comp.background), M.digest(rows):sub(1, 8)))
  for pred, list in pairs(facts) do
    local parts = {}
    for _, f in ipairs(list) do
      parts[#parts + 1] = (pred == "beat" and (f.args .. "=") or ((f.args or "") .. "@")) .. ("%.2f"):format(f.t0)
    end
    w(("facts %s (asset %s): %s"):format(pred, tostring(list[1].asset), table.concat(parts, " ")))
  end
  for _, a in ipairs(rows.asset) do
    w(("asset %s: %s"):format(a.id, a.solid and "solid" or val(a.src)) .. (a.derive and (" derive " .. val(a.derive)) or ""))
  end
  -- nodes
  local props, keys, motion, setby = {}, {}, {}, {}
  for _, r in ipairs(rows.prop) do props[r.id] = props[r.id] or {}; table.insert(props[r.id], r) end
  for _, k in ipairs(rows.key) do
    local c = k.id .. "." .. k.name
    keys[k.id] = keys[k.id] or {}
    keys[k.id][c] = keys[k.id][c] or { name = k.name }
    table.insert(keys[k.id][c], k)
  end
  for _, m in ipairs(rows.motion) do motion[m.id] = motion[m.id] or {}; table.insert(motion[m.id], m) end
  for sys, ids in pairs(comp.access or {}) do
    for id, ps in pairs(ids) do
      setby[id] = setby[id] or {}
      local names = {}
      for p in pairs(ps) do names[#names + 1] = p end
      table.sort(names)
      setby[id][#setby[id] + 1] = sys .. " sets " .. table.concat(names, ",")
    end
  end
  local depth, parent = {}, {}
  for _, n in ipairs(rows.node) do parent[n.id] = n.parent end
  w("nodes (draw order; children indented):")
  for _, n in ipairs(rows.node) do
    local d = n.parent and ((depth[n.parent] or 0) + 1) or 0
    depth[n.id] = d
    local pad = ("  "):rep(d + 1)
    local ps = {}
    for _, r in ipairs(props[n.id] or {}) do ps[#ps + 1] = r.name .. "=" .. val(r.value) end
    w(pad .. n.id .. " " .. n.kind .. (#ps > 0 and (" " .. table.concat(ps, " ")) or ""))
    for _, c in pairs(keys[n.id] or {}) do
      local parts = {}
      for _, k in ipairs(c) do parts[#parts + 1] = val(k.value) .. "@" .. tref(k.t) .. (k.ease and (" " .. k.ease) or "") end
      w(pad .. "  keys " .. c.name .. ": " .. table.concat(parts, " -> "))
    end
    for _, m in ipairs(motion[n.id] or {}) do
      w(pad .. ("  motion %s %s %s..%s"):format(m.name, m.curve, tref(m.t0), tref(m.t1)))
    end
    for _, line in ipairs(setby[n.id] or {}) do w(pad .. "  " .. line .. " every frame") end
  end
  -- systems
  w("systems (run every frame after the keys, in order):")
  for _, sy in ipairs(rows.system) do
    local spawned = {}
    for id in pairs((comp.spawned or {})[sy.name] or {}) do
      local stem = id:gsub("%d+$", "")
      spawned[stem] = (spawned[stem] or 0) + 1
    end
    local sp = {}
    for stem, c in pairs(spawned) do sp[#sp + 1] = c > 1 and (stem .. "*" .. c) or stem end
    table.sort(sp)
    local ids = {}
    for id in pairs((comp.access or {})[sy.name] or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    w(("  %s (order %s, %d lines)%s%s"):format(sy.name, tostring(sy.order), select(2, sy.source:gsub("\n", "")) + 1,
      #ids > 0 and (": sets " .. table.concat(ids, ", ")) or "",
      #sp > 0 and ("; spawns " .. table.concat(sp, ", ")) or ""))
  end
  -- expectations
  if #(rows.expect or {}) > 0 then
    local failing = {}
    for _, f in ipairs(fs) do
      if f.code == "expect_failed" then failing[f.detail:match("%(expect ([^)]+)%)$") or ""] = f.detail end
    end
    w("expect (the ask; fixed, no move edits them):")
    for _, x in ipairs(rows.expect) do
      local when = x.at and (" at " .. tostring(x.at))
        or (x.t0 or x.t1) and (" over %s..%s%s"):format(tostring(x.t0 or 0), tostring(x.t1 or "end"), x.holds == "ever" and " (ever)" or "")
        or x.prop and " over the whole piece" or ""
      w(failing[x.id] and ("  FAIL " .. failing[x.id]) or ("  ok   " .. x.id .. when .. ": " .. (x.says or "")))
    end
  end
  -- findings: errors, then warnings; info left out
  local errs, warns = {}, {}
  for _, f in ipairs(fs) do
    if f.code ~= "expect_failed" then
      local line = ("  %s %s%s: %s"):format(f.severity, f.code, f.node and (" on " .. f.node) or "", f.detail or "")
      if f.severity == "error" then errs[#errs + 1] = line elseif f.severity == "warn" then warns[#warns + 1] = line end
    end
  end
  w(("findings (lint and check): %d errors, %d warnings"):format(#errs, #warns))
  for _, l in ipairs(errs) do w(l) end
  for _, l in ipairs(warns) do w(l) end
  return table.concat(o, "\n")
end

function M.rows(comp, opts)
  local rows = M.dump(comp)
  if opts.brief then
    if not comp.rows then io.stderr:write("moonsplice rows --brief: the comp is not in rows form\n") return 1 end
    io.write(brief(comp, rows, opts.comp), "\n")
    io.flush()
    return 0
  end
  if opts.out then
    for _, s in ipairs(rows.system) do
      if s.opaque then
        io.stderr:write("moonsplice rows: this comp has code written with the object API (" .. s.name .. "); it holds "
          .. "node handles or draws by hand, so it cannot be written in rows form automatically. Write it as systems.\n")
        return 1
      end
    end
    local f = assert(_MOONSPLICE_IOOPEN(opts.out, "w"))
    f:write(R.lua(rows)); f:close()
  end
  -- derived: facts the assets' derive produced (beats, words), each with its src; not part of the
  -- digest, which covers what was written
  local derived = {}
  for _, f in ipairs(comp.derived or {}) do
    if (f.t0 or 0) <= comp.duration then derived[#derived + 1] = f end -- what the comp's time can reach
  end
  -- solids: each solid asset's measurements (size, volume, parts, watertight), so an agent can check its geometry
  local solids = {}
  for id, m in pairs(comp.solids or {}) do
    local o = {}
    for k, v in pairs(m) do if k ~= "src" then o[k] = v end end
    solids[id] = o
  end
  io.write(R.json({ schema = R.schema, tables = tables(rows), digest = M.digest(rows), derived = derived,
    solids = next(solids) and solids or nil }), "\n")
  io.flush()
  return 0
end

-- a comp built from rows, compiled with no media work and evaluated at three times: what a
-- patch must survive before it lands
local function try(rows)
  local src = R.lua(rows)
  local chunk, err = loadstring(src, "=rows")
  if not chunk then error(err, 0) end
  local comp = chunk()
  -- with the derive step (cached), so keys bound to facts it makes (beats, words) resolve
  -- the same host main.lua gives a comp: a game's world needs the engine's physics
  local E = rawget(_G, "MOONSPLICE_ENGINE")
  comp:compile({ game_host = { physics = E and E.physics_world or nil }, derive = function(src, ops)
    return require("derive").derive(require("resolve").localize(src), ops)
  end, solid = function(tree) return require("solid").build(tree) end })
  for _, t in ipairs({ 0, comp.duration / 2, comp.duration * 0.999 }) do comp:evaluate(t) end
  return comp
end

findings_of = function(path, only)
  local out = {}
  for _, tier in ipairs(only and { only } or { "lint", "check" }) do
    local p = assert(_MOONSPLICE_POPEN(("%s/moonsplice %s %s --json 2>&1"):format(q(root()), tier, q(path)), "r"))
    local text = p:read("*a")
    p:close()
    local body = text:match("(%{\"schema\".*%})")
    local ok, doc = pcall(function() return require("moonsplice.json").decode(body) end)
    if ok and doc then
      for _, f in ipairs(doc.findings or {}) do
        out[#out + 1] = { tier = f.tier ~= "" and f.tier or tier, id = f.id or f.node or "", name = f.name or "",
          code = f.code, severity = f.severity, t0 = f.t0, t1 = f.t1, measured = f.measured,
          threshold = f.threshold, detail = f.detail }
      end
    else
      out[#out + 1] = { tier = tier, id = "", name = "", code = "load_error", severity = "error",
        detail = (text:match("moonsplice error: ([^\n]+)") or text:sub(1, 400)) }
    end
  end
  return out
end
local function findings(path) return findings_of(path) end

-- the engine's one line of truth after a call (ROWS.md, "State"): the digest, the open errors by
-- code and node, the warnings counted, the expectations held of their total and which fail. A
-- harness ends every result with it, so the newest message in an append-only transcript is current.
local function key_of(f) return (f.code or "") .. ":" .. ((f.id ~= "" and f.id) or f.node or "") end

function M.state(rows, fs)
  local errs, warns, failing = {}, 0, {}
  for _, f in ipairs(fs) do
    if f.code == "expect_failed" then
      failing[#failing + 1] = (f.detail or ""):match("%(expect ([^)]+)%)$") or "?"
    elseif f.severity == "error" then errs[#errs + 1] = f.code .. " " .. ((f.id ~= "" and f.id) or f.node or "")
    elseif f.severity == "warn" then warns = warns + 1 end
  end
  local total = #(rows.expect or {})
  local digest = M.digest(rows)
  local line = ("state: digest %s; errors %d%s; warnings %d; expect %d/%d%s"):format(digest:sub(1, 8), #errs,
    #errs > 0 and (" (" .. table.concat(errs, ", ") .. ")") or "", warns, total - #failing, total,
    #failing > 0 and (" (failing: " .. table.concat(failing, ", ") .. ")") or "")
  return { digest = digest, errors = #errs, warnings = warns, expect_held = total - #failing, expect_total = total,
    failing = failing, line = line }
end

-- what a call changed: findings closed and opened (errors and warnings, by code and node)
function M.delta(before, after)
  local b, a = {}, {}
  for _, f in ipairs(before) do if f.severity ~= "info" then b[key_of(f)] = f end end
  for _, f in ipairs(after) do if f.severity ~= "info" then a[key_of(f)] = f end end
  local closed, opened = {}, {}
  for k, f in pairs(b) do if not a[k] then closed[#closed + 1] = f.code .. " " .. ((f.id ~= "" and f.id) or f.node or "") end end
  for k, f in pairs(a) do if not b[k] then opened[#opened + 1] = f.code .. " " .. ((f.id ~= "" and f.id) or f.node or "") end end
  table.sort(closed); table.sort(opened)
  local line = "delta: " .. ((#closed + #opened == 0) and "nothing closed or opened" or
    (("closed %s | opened %s"):format(#closed > 0 and table.concat(closed, ", ") or "none",
      #opened > 0 and table.concat(opened, ", ") or "none")))
  return { closed = closed, opened = opened, line = line }
end

function M.patch(comp, opts)
  local f = _MOONSPLICE_IOOPEN(opts.patch_file, "r")
  if not f then io.stderr:write("moonsplice patch: cannot read " .. tostring(opts.patch_file) .. "\n") return 1 end
  local ok, patches = pcall(require("moonsplice.json").decode, f:read("*a"))
  f:close()
  if not ok or type(patches) ~= "table" then io.stderr:write("moonsplice patch: the patches are not JSON\n") return 1 end
  if patches.move then patches = { patches } end
  if not comp.rows then
    local rejected = {}
    for i, p in ipairs(patches) do
      rejected[i] = { patch = p, why = "the comp is not in rows form; `moonsplice rows COMP -o NEW.lua` converts one" }
    end
    io.write(R.json({ applied = {}, rejected = rejected, touched = {}, findings = findings(opts.comp) }), "\n")
    return 0
  end
  local rows = R.copy(comp.rows)
  local before = M.digest(rows)
  local res = R.apply(rows, patches, try)
  local after = M.digest(rows)
  -- the findings before, only when something will change (a lint and a check: about a second)
  local fs_before = after ~= before and findings(opts.comp) or nil
  if after ~= before then
    local out = assert(_MOONSPLICE_IOOPEN(opts.comp, "w"))
    out:write(R.lua(rows)); out:close()
  end
  res.digest_before, res.digest_after = before, after
  res.findings = findings(opts.comp)
  res.state = M.state(rows, res.findings)
  res.delta = M.delta(fs_before or res.findings, res.findings)
  io.write(R.json(res), "\n")
  io.flush()
  return 0
end

-- `moonsplice expect COMP FILE.json`: the harness writes the ask's expectations (ROWS.md,
-- "Expectations") once, before the first move. Each row is added unless its id exists already;
-- existing rows (a seed's invariants) are never edited. A malformed row is rejected with why.
local EXPECT_FIELDS = { id = true, says = true, node = true, prop = true, op = true, value = true,
  at = true, t0 = true, t1 = true, holds = true }
local EXPECT_OPS = { ["=="] = true, ["~="] = true, [">"] = true, [">="] = true, ["<"] = true, ["<="] = true, has = true }

local function expect_why(x)
  if type(x) ~= "table" then return "an expect row is an object" end
  for k in pairs(x) do
    if not EXPECT_FIELDS[k] then return ("%s is not an expect field (id, says, node, prop, op, value, at, t0, t1, holds)"):format(tostring(k)) end
  end
  if type(x.id) ~= "string" or x.id == "" then return "id needs a string" end
  if type(x.says) ~= "string" or x.says == "" then return "says needs a string: what the ask requires, in words" end
  if type(x.node) ~= "string" or x.node == "" then return "node needs a string: the node id the row is about" end
  if x.prop ~= nil and type(x.prop) ~= "string" then return "prop needs a string" end
  if (x.op ~= nil or x.value ~= nil or x.at ~= nil or x.t0 ~= nil or x.t1 ~= nil or x.holds ~= nil) and not x.prop then
    return "op, value, at, t0, t1 and holds need a prop"
  end
  if x.prop then
    if x.value == nil then return "a row with a prop needs a value" end
    if x.op ~= nil and not EXPECT_OPS[x.op] then return ("op %s is not one of == ~= > >= < <= has"):format(tostring(x.op)) end
    if x.op == "has" and type(x.value) ~= "string" then return "op has needs a string value" end
    if x.op and x.op:match("[<>]") and type(x.value) ~= "number" then return ("op %s needs a number value"):format(x.op) end
    if x.at ~= nil and (x.t0 ~= nil or x.t1 ~= nil) then return "give at, or t0..t1, not both" end
    if x.holds ~= nil and x.holds ~= "ever" and x.holds ~= "always" then return 'holds is "ever" or "always"' end
    if x.holds ~= nil and x.at ~= nil then return "holds needs a window (t0..t1), not at" end
    -- a value checked with no time at all is checked at every frame of the piece; say so, or say when
    if x.at == nil and x.t0 == nil and x.t1 == nil and x.holds == nil and x.op ~= "has" then
      return 'say when: at (one instant), t0..t1 (a window), or holds = "always" for every frame of the piece'
    end
    for _, k in ipairs({ "at", "t0", "t1" }) do
      local v = x[k]
      if v ~= nil and type(v) ~= "number" and type(v) ~= "string" then return k .. " needs seconds or a fact reference" end
    end
  end
  return nil
end

function M.expect(comp, opts)
  local f = _MOONSPLICE_IOOPEN(opts.expect_file, "r")
  if not f then io.stderr:write("moonsplice expect: cannot read " .. tostring(opts.expect_file) .. "\n") return 1 end
  local ok, list = pcall(require("moonsplice.json").decode, f:read("*a"))
  f:close()
  if not ok or type(list) ~= "table" then io.stderr:write("moonsplice expect: the rows are not JSON\n") return 1 end
  if list.id then list = { list } end
  local added, rejected = {}, {}
  if not comp.rows then
    for _, x in ipairs(list) do
      rejected[#rejected + 1] = { row = x, why = "the comp is not in rows form; `moonsplice rows COMP -o NEW.lua` converts one" }
    end
    io.write(R.json({ added = added, rejected = rejected, findings = findings(opts.comp) }), "\n")
    return 0
  end
  local rows = R.copy(comp.rows)
  rows.expect = rows.expect or {}
  local before = M.digest(rows)
  local have = {}
  for _, x in ipairs(rows.expect) do have[x.id] = true end
  for _, x in ipairs(list) do
    local why = expect_why(x)
    if not why and have[x.id] then why = ("expect %s exists already; expectations are never edited"):format(x.id) end
    if not why then
      rows.expect[#rows.expect + 1] = R.copy(x)
      -- it must compile: a fact reference no asset makes is refused here, not at render
      local tried, err = pcall(try, rows)
      if tried then
        -- and its times must fall inside the comp: a predicate it can never reach is no predicate
        for _, e in ipairs(err.expect or {}) do
          if e.id == x.id then
            for _, k in ipairs({ "at", "t0", "t1" }) do
              if type(e[k]) == "number" and (e[k] < 0 or e[k] > err.duration) then
                tried, err = false, ("%s %s is %.2f s, outside the comp (0..%g s)"):format(k, tostring(x[k]), e[k], err.duration)
              end
            end
          end
        end
      end
      if tried then
        have[x.id] = true
        added[#added + 1] = x
      else
        -- by id: emitting the comp sorts the table, so the row just added need not be last
        for i = #rows.expect, 1, -1 do if rows.expect[i].id == x.id then table.remove(rows.expect, i) end end
        why = tostring(err)
      end
    end
    if why then rejected[#rejected + 1] = { row = x, why = why } end
  end
  R.sort(rows)
  local after = M.digest(rows)
  if after ~= before then
    local out = assert(_MOONSPLICE_IOOPEN(opts.comp, "w"))
    out:write(R.lua(rows)); out:close()
  end
  local fs = findings(opts.comp)
  io.write(R.json({ added = added, rejected = rejected, digest_before = before, digest_after = after,
    findings = fs, state = M.state(rows, fs) }), "\n")
  io.flush()
  return 0
end

-- `moonsplice gate COMP --json`: the state line alone, for a harness's hand-in: { state, findings };
-- passed when no error is open and every expectation holds
function M.gate(comp, opts)
  if not comp.rows then io.stderr:write("moonsplice gate: the comp is not in rows form\n") return 1 end
  local rows = R.copy(comp.rows)
  local fs = findings(opts.comp)
  local st = M.state(rows, fs)
  st.passed = st.errors == 0 and #st.failing == 0
  io.write(R.json({ state = st, findings = fs }), "\n")
  io.flush()
  return 0
end

return M
