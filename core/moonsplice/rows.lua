-- Rows (.robot/docs/rows.robot, schema msr/1): a composition as plain rows, the one data model Moonsplice,
-- Bevy and tablua share. Host-free like the rest of core/moonsplice.
--
--   e.comp { width, height, duration, nodes = {...}, keys = {...}, motion = {...},
--            systems = {...}, assets = {...}, facts = {...}, game = {...}, input = {...} }
--
--   rows.normalize(def)            -> rows   the authored form as canonical rows (sorted, ids, no functions)
--   rows.scene(rows, M)            -> fn(s)  builds the scene from rows through the ordinary constructors
--   rows.dump(comp, compiled?)     -> rows   any comp (the object API included) as rows
--   rows.apply(rows, patches, ok?) -> { applied, rejected, touched }   typed patches (ROWS.md §6)
--   rows.lua(rows)                 -> text   the comp file in rows form, in a fixed order
--   rows.json(rows)                -> text   canonical JSON (sorted keys, shortest round-trip numbers)
--
-- A system is a pure function `(t, state, q) -> rows`, kept as source text so a comp stays data:
--   { name = "follow", order = 1, source = "return function(t, state, q) return { { id = 'a', y = q.y('b') } } end" }
local R = {}

R.schema = "msr/1"
R.TABLES = { "comp", "node", "prop", "key", "motion", "system", "asset", "fact", "input", "game", "expect" }

-- props that hold a node: an id in rows, the node itself once built
R.REF = { parent = true, clip_node = true, camera = true }
R.REFS = { items = true }

-- the authored form's fields that are tables of rows, not comp settings
local ROW_FIELDS = { nodes = true, keys = true, motion = true, systems = true, assets = true, facts = true,
  input = true, game = true, scene = true, expect = true }

-- ---------- values ----------

-- the shortest decimal that reads back as the same number: canonical, and readable
local function num(v)
  if v ~= v or v == math.huge or v == -math.huge then error("moonsplice rows: not a finite number", 0) end
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  for p = 15, 17 do
    local s = string.format("%." .. p .. "g", v)
    if tonumber(s) == v then return s end
  end
  return string.format("%.17g", v)
end
R.num = num

-- an empty table that is an object, not a list, in JSON ({} rather than [])
R.OBJECT = { __json = "object" }
local function is_array(t)
  if getmetatable(t) == R.OBJECT then return false end
  if next(t) == nil then return true end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end
    n = n + 1
  end
  return n == #t
end

local function sorted_keys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
  return ks
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end
R.copy = copy

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
R.same = same

-- ---------- canonical JSON ----------

local function jstr(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
    return m[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function json(v, out)
  local t = type(v)
  if t == "number" then out[#out + 1] = num(v)
  elseif t == "string" then out[#out + 1] = jstr(v)
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif v == nil then out[#out + 1] = "null"
  elseif t == "table" then
    if is_array(v) then
      out[#out + 1] = "["
      for i, x in ipairs(v) do if i > 1 then out[#out + 1] = "," end json(x, out) end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for _, k in ipairs(sorted_keys(v)) do
        if not first then out[#out + 1] = "," end
        first = false
        out[#out + 1] = jstr(tostring(k)) .. ":"
        json(v[k], out)
      end
      out[#out + 1] = "}"
    end
  else
    error("moonsplice rows: a " .. t .. " is not a value", 0)
  end
end

function R.json(v)
  local out = {}
  json(v, out)
  return table.concat(out)
end

-- ---------- normalize: the authored form -> canonical rows ----------

local function key_row(k)
  if k.id then return { id = k.id, name = k.name, t = k.t, value = k.value, ease = k.ease } end
  return { id = k[1], name = k[2], t = k[3], value = k[4], ease = k[5] }
end

local function cmp_t(a, b)
  -- numbers before fact references, then by value; a reference's index in number order, so beat:9
  -- comes before beat:10 (as strings it would not, and a curve's keys ran backwards in time)
  local na, nb = type(a) == "number", type(b) == "number"
  if na ~= nb then return na end
  if na then return a < b end
  local pa, ia, ra = a:match("^([^:]+):(%d+)(.*)$")
  local pb, ib, rb = b:match("^([^:]+):(%d+)(.*)$")
  if pa and pb and pa == pb and ia ~= ib then return tonumber(ia) < tonumber(ib) end
  if pa and pb and pa == pb and ia == ib and ra ~= rb then return ra < rb end
  return a < b
end

local function sort_rows(list, cols)
  table.sort(list, function(a, b)
    for _, c in ipairs(cols) do
      local x, y = a[c], b[c]
      if x ~= y then
        if x == nil then return true end
        if y == nil then return false end
        if type(x) ~= type(y) then return type(x) < type(y) end
        return x < y
      end
    end
    return false
  end)
end

function R.normalize(def)
  local rows = { schema = R.schema, comp = {}, node = {}, prop = {}, key = {}, motion = {}, system = {},
    asset = {}, fact = {}, input = {}, game = {}, expect = {} }
  for k, v in pairs(def) do
    if not ROW_FIELDS[k] and type(v) ~= "function" then rows.comp[k] = copy(v) end
  end
  local seen = {}
  for i, n in ipairs(def.nodes or {}) do
    assert(type(n.id) == "string" and n.id ~= "", ("moonsplice rows: node %d needs a string id"):format(i))
    assert(not seen[n.id], "moonsplice rows: two nodes have the id " .. n.id)
    assert(type(n.kind) == "string", "moonsplice rows: node " .. n.id .. " needs a kind")
    seen[n.id] = true
    rows.node[#rows.node + 1] = { id = n.id, kind = n.kind, parent = n.parent, order = n.order or i }
    for name, v in pairs(n) do
      if name ~= "id" and name ~= "kind" and name ~= "parent" and name ~= "order" then
        rows.prop[#rows.prop + 1] = { id = n.id, name = name, value = copy(v) }
      end
    end
  end
  for _, k in ipairs(def.keys or {}) do rows.key[#rows.key + 1] = key_row(k) end
  for _, m in ipairs(def.motion or {}) do
    rows.motion[#rows.motion + 1] = { id = m.id or m[1], name = m.name or m[2], t0 = m.t0 or m[3], t1 = m.t1 or m[4],
      curve = m.curve or m[5], params = copy(m.params or m[6] or {}) }
  end
  for i, sys in ipairs(def.systems or {}) do
    assert(type(sys.name) == "string", "moonsplice rows: a system needs a name")
    assert(type(sys.source) == "string", "moonsplice rows: system " .. sys.name .. " needs source text")
    rows.system[#rows.system + 1] = { name = sys.name, order = sys.order or i, source = sys.source }
  end
  for _, a in ipairs(def.assets or {}) do
    rows.asset[#rows.asset + 1] = { id = a.id, src = a.src, derive = copy(a.derive), solid = copy(a.solid), parts = a.parts }
  end
  -- expect: what the ask requires, as predicates lint checks every run (ROWS.md, "Expectations").
  -- The harness writes them; no patch move edits them, so a move cannot satisfy an ask by deleting it.
  for i, x in ipairs(def.expect or {}) do
    assert(type(x.id) == "string", ("moonsplice rows: expect %d needs a string id"):format(i))
    rows.expect[#rows.expect + 1] = copy(x)
  end
  for _, f in ipairs(def.facts or {}) do
    rows.fact[#rows.fact + 1] = { pred = f.pred or f[1], args = f.args or f[2], t0 = f.t0 or f[3], t1 = f.t1 or f[4],
      src = f.src or f[5] or "", conf = f.conf or f[6] }
  end
  for i, e in ipairs(def.input or {}) do
    local r = copy(e)
    r.n = r.n or i
    rows.input[#rows.input + 1] = r
  end
  if def.game then
    for k, v in pairs(def.game) do
      if type(v) ~= "function" and k ~= "script" then rows.game[k] = copy(v) end
    end
  end
  R.sort(rows)
  return rows
end

function R.sort(rows)
  table.sort(rows.node, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.id < b.id end)
  sort_rows(rows.prop, { "id", "name" })
  table.sort(rows.key, function(a, b)
    if a.id ~= b.id then return a.id < b.id end
    if a.name ~= b.name then return a.name < b.name end
    return cmp_t(a.t, b.t)
  end)
  sort_rows(rows.motion, { "id", "name", "t0" })
  table.sort(rows.system, function(a, b)
    if (a.name == "shared") ~= (b.name == "shared") then return a.name == "shared" end
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)
  sort_rows(rows.asset, { "id" })
  sort_rows(rows.expect, { "id" })
  table.sort(rows.fact, function(a, b)
    if a.pred ~= b.pred then return a.pred < b.pred end
    local x, y = tostring(a.args), tostring(b.args)
    if x ~= y then return x < y end
    return (a.t0 or 0) < (b.t0 or 0)
  end)
  table.sort(rows.input, function(a, b) if a.t ~= b.t then return a.t < b.t end return a.n < b.n end)
  return rows
end

-- ---------- the comp, built from rows ----------

-- A system's source becomes its function, in an environment that has no I/O, clocks or randomness.
local SAFE = { "assert", "error", "ipairs", "next", "pairs", "select", "tonumber", "tostring", "type", "unpack" }
function R.load_system(name, source, extra, any_value)
  local env = { math = {}, string = string, table = table }
  for k, v in pairs(math) do if k ~= "random" and k ~= "randomseed" then env.math[k] = v end end
  for _, k in ipairs(SAFE) do env[k] = _G[k] end
  env.unpack = env.unpack or table.unpack
  for k, v in pairs(extra or {}) do env[k] = v end
  local chunk, err
  if setfenv then
    chunk, err = loadstring(source, "=system " .. name)
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(source, "=system " .. name, "t", env)
  end
  if not chunk then error("moonsplice rows: system " .. name .. " does not parse: " .. tostring(err), 0) end
  local ok, fn = pcall(chunk)
  if not ok then error("moonsplice rows: system " .. name .. " failed to load: " .. tostring(fn), 0) end
  if not any_value and type(fn) ~= "function" then error("moonsplice rows: system " .. name .. " must return a function", 0) end
  return fn
end

-- "beat:12", "word:tide", "word:tide#2", "beat:3+0.25": a time from the facts
function R.fact_time(ref, facts)
  local pred, args, off = ref:match("^([%w_]+):([^+]-)([+-][%d%.]+)$")
  if not pred then pred, args = ref:match("^([%w_]+):(.+)$") end
  if not pred then error(("moonsplice rows: %q is not seconds or a fact reference (beat:4, word:tide#2, beat:3+0.25)"):format(ref), 0) end
  local nth = tonumber(args:match("#(%d+)$") or "1")
  args = args:gsub("#%d+$", "")
  local hit = 0
  for _, f in ipairs(facts) do
    if f.pred == pred and tostring(f.args):lower() == args:lower() then
      hit = hit + 1
      if hit == nth then return f.t0 + (tonumber(off or "0") or 0) end
    end
  end
  error(("moonsplice rows: no fact %s"):format(ref), 0)
end

local function derived_facts(asset_id, d, out)
  for i, b in ipairs(d.beats or {}) do
    out[#out + 1] = { pred = "beat", args = tostring(i), t0 = b, src = "librosa/beat_track", asset = asset_id }
  end
  for _, w in ipairs(d.words or {}) do
    out[#out + 1] = { pred = "word", args = (w.word or w.text or ""):lower():gsub("[^%w']", ""), t0 = w.start or w.t0,
      t1 = w["end"] or w.t1, src = "faster-whisper", asset = asset_id }
  end
end

-- The scene function for a comp authored as rows. M is core/moonsplice (its Scene and ANIMATABLE).
function R.scene(rows, M)
  return function(s)
    local byid, facts, assets = {}, {}, {}
    for _, f in ipairs(rows.fact) do facts[#facts + 1] = f end
    -- an asset no node shows gets only its facts (beats, words, silence): processing pixels or
    -- sound nobody sees or hears would cost minutes and gigabytes for nothing
    local shown = {}
    for _, r in ipairs(rows.prop) do
      if r.name == "src" and type(r.value) == "string" and r.value:match("^asset:") then shown[r.value:sub(7)] = true end
    end
    local FACT_OPS = { beats = true, words = true, silence = true }
    for _, a in ipairs(rows.asset) do
      local ops = a.derive
      if ops and not shown[a.id] then
        local only = {}
        for k, v in pairs(ops) do if FACT_OPS[k] then only[k] = v end end
        ops = only
      end
      local d
      if a.solid then
        -- a solid built by Manifold from its tree (.robot/docs/solids.robot); its measurements go on s.solids
        d = s:solid(a.solid)
        d.declared_parts = a.parts -- several pieces on purpose (a chain) say so: parts = n
        s.solids = s.solids or {}
        s.solids[a.id] = d
      else
        d = (ops and next(ops)) and s:derive(a.src, ops) or { src = a.src }
      end
      assets[a.id] = d
      derived_facts(a.id, d, facts)
    end
    table.sort(facts, function(a, b)
      if a.pred ~= b.pred then return a.pred < b.pred end
      return (a.t0 or 0) < (b.t0 or 0)
    end)
    local function when(t) return type(t) == "number" and t or R.fact_time(t, facts) end
    -- the ask's predicates, with fact references made seconds (lint checks them: expect_failed)
    s.expect = {}
    for _, x in ipairs(rows.expect) do
      local e = copy(x)
      for _, k in ipairs({ "at", "t0", "t1" }) do if e[k] ~= nil then e[k] = when(e[k]) end end
      s.expect[#s.expect + 1] = e
    end
    -- what the assets' derive made, for whoever reads the comp (the agent binds to these)
    s.derived = {}
    for _, f in ipairs(facts) do
      if f.asset then
        s.derived[#s.derived + 1] = { pred = f.pred, args = f.args, t0 = f.t0, t1 = f.t1, src = f.src, asset = f.asset }
      end
    end

    -- keys by (id, name), in time order; a curve holds its first value before its first key
    local curves, order = {}, {}
    for _, k in ipairs(rows.key) do
      local c = k.id .. "\0" .. k.name
      if not curves[c] then curves[c] = { id = k.id, name = k.name, keys = {} }; order[#order + 1] = c end
      local ks = curves[c].keys
      ks[#ks + 1] = { t = when(k.t), value = k.value, ease = k.ease }
    end
    -- in time order, whatever order the rows came in: references resolve to times only here
    for _, c in pairs(curves) do table.sort(c.keys, function(a, b) return a.t < b.t end) end
    local first = {}
    for _, c in ipairs(order) do
      local cv = curves[c]
      table.sort(cv.keys, function(a, b) return a.t < b.t end)
      for i = 2, #cv.keys do
        if cv.keys[i].t == cv.keys[i - 1].t then
          error(("moonsplice rows: two keys on %s.%s at %s"):format(cv.id, cv.name, num(cv.keys[i].t)), 0)
        end
      end
      -- an eased curve holds its first key's value before it; a step (and any structural prop such
      -- as text) leaves the rest value until the key
      local k1 = cv.keys[1]
      if M.ANIMATABLE[cv.name] and k1.ease ~= "step" then
        first[cv.id] = first[cv.id] or {}
        first[cv.id][cv.name] = k1.value
      end
    end

    -- systems and code props share one sandbox: `shared` is what the system named "shared" returns
    -- (constants and helpers), made once
    local q = { facts = facts, state = false, t = 0 } -- state: false until a frame has one
    local extra = { ease = function(name, u) return M.ease.get(name)(u) end,
      lerp = function(a, b, u) return a + (b - a) * u end,
      clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end,
      color = function(c) return require("moonsplice.color").parse(c) end }
    for _, sys in ipairs(rows.system) do
      if sys.name == "shared" then
        extra.shared = R.load_system(sys.name, sys.source, extra, true)
      end
    end
    -- a prop written { fn = "<source>" } is code (a vector's draw, a world's entities): its function
    -- takes the engine's own arguments, and reads the frame through `q`, a name in its sandbox
    extra.q = q
    local function code(id, name, src)
      return R.load_system(id .. "." .. name, src, extra)
    end

    local props = {}
    for _, p in ipairs(rows.prop) do
      props[p.id] = props[p.id] or {}
      props[p.id][p.name] = copy(p.value)
    end
    for _, n in ipairs(rows.node) do
      local ctor = M.Scene[n.kind]
      if n.kind:sub(1, 1) == "_" or ROW_FIELDS[n.kind] or n.kind == "view" or n.kind == "script" or n.kind == "derive" then
        error(("moonsplice rows: node %s has an unknown kind %q"):format(n.id, n.kind), 0)
      end
      if type(ctor) ~= "function" then
        error(("moonsplice rows: node %s has an unknown kind %q"):format(n.id, n.kind), 0)
      end
      local p = props[n.id] or {}
      for name, v in pairs(first[n.id] or {}) do p[name] = copy(v) end
      p.id = n.id
      if n.parent then
        p.parent = byid[n.parent] or error(("moonsplice rows: %s's parent %s must come before it"):format(n.id, n.parent), 0)
      end
      for name in pairs(R.REF) do
        if name ~= "parent" and type(p[name]) == "string" then
          p[name] = byid[p[name]] or error(("moonsplice rows: %s.%s names %s, which is not before it"):format(n.id, name, p[name]), 0)
        end
      end
      for name in pairs(R.REFS) do
        if type(p[name]) == "table" then
          for i, ref in ipairs(p[name]) do
            if type(ref) == "string" then p[name][i] = byid[ref] or error(("moonsplice rows: %s.%s names %s, which is not before it"):format(n.id, name, ref), 0) end
          end
        end
      end
      for name, v in pairs(p) do
        if type(v) == "table" and type(v.fn) == "string" and next(v, next(v)) == nil and next(v) == "fn" then
          p[name] = code(n.id, name, v.fn)
        end
      end
      if type(p.src) == "string" and p.src:match("^asset:") then
        local a = assets[p.src:sub(7)] or error(("moonsplice rows: %s.src names no asset %s"):format(n.id, p.src), 0)
        p.src = a.src
      end
      byid[n.id] = ctor(s, p)
      -- a kinetic's characters are nodes too, addressable as <id>.1, <id>.2, ... (spaces skipped)
      for i, ch in ipairs(byid[n.id].chars or {}) do byid[n.id .. "." .. i] = ch end
    end

    -- keys may name a node a constructor made (a kinetic character): every node by id
    local function any(id)
      if byid[id] then return byid[id] end
      for _, n in ipairs(s.nodes) do if n.id == id then return n end end
    end
    -- keys and motion are recorded through the same recorder the object API uses
    s:script(function(rec)
      for _, c in ipairs(order) do
        local cv = curves[c]
        local node = any(cv.id) or error(("moonsplice rows: a key names no node %s"):format(cv.id), 0)
        local animatable = M.ANIMATABLE[cv.name]
        if not animatable and not M.SETTABLE[cv.name] then
          error(("moonsplice rows: %s.%s cannot be keyed (not animatable)"):format(cv.id, cv.name), 0)
        end
        local k1 = cv.keys[1]
        if not animatable or k1.ease == "step" then
          rec.cursor = k1.t
          rec:set(node, { [cv.name] = k1.value })
        end
        for i = 2, #cv.keys do
          local a, b = cv.keys[i - 1], cv.keys[i]
          if not animatable or b.ease == "step" then
            rec.cursor = b.t
            rec:set(node, { [cv.name] = b.value })
          else
            rec.cursor = a.t
            rec:tween(node, b.t - a.t, { [cv.name] = b.value }, b.ease or "linear")
          end
        end
      end
      for _, m in ipairs(rows.motion) do
        local node = any(m.id) or error(("moonsplice rows: motion names no node %s"):format(m.id), 0)
        local t0, t1 = when(m.t0), when(m.t1)
        local p = m.params or {}
        rec.cursor = t0
        if m.curve == "path" then
          rec:path(node, t1 - t0, p.points, p.ease)
        elseif m.curve == "wiggle" then
          rec:wiggle(node, m.name, { duration = t1 - t0, amp = p.amp, freq = p.freq, seed = p.seed, ramp = p.ramp })
        elseif m.curve == "bake" then
          rec.timeline:record_bake(node, m.name, t0, t1, p.samples)
        else
          error(("moonsplice rows: unknown motion curve %q"):format(tostring(m.curve)), 0)
        end
      end
    end)

    -- systems: pure functions of (t, state, q) whose rows are this frame's live props
    function q.get(id, name)
      local node = byid[id] or error("moonsplice rows: q.get of no node " .. tostring(id), 2)
      return node:get(name)
    end
    function q.fact(ref) return R.fact_time(ref, facts) end
    function q.all(pred)
      local out = {}
      for _, f in ipairs(facts) do if f.pred == pred then out[#out + 1] = f end end
      return out
    end
    setmetatable(q, { __index = function(_, name) return function(id) return q.get(id, name) end end })
    local fns = {}
    for _, sys in ipairs(rows.system) do
      if sys.name ~= "shared" then fns[sys.name] = R.load_system(sys.name, sys.source, extra) end
    end
    -- what each system writes, as it runs: access[system][id][prop] = true (nodes it sets) and
    -- spawned[system][id] = true (entities it spawns). Read, never declared: always what the code does.
    s.access, s.spawned = {}, {}
    for _, sys in ipairs(rows.system) do
      if not sys.name:match("^game%.") and sys.name ~= "shared" then
        local fn = fns[sys.name]
        s:view(function(state, t)
          q.state, q.t = state, t
          local out = fn(t, state, q)
          if out == nil then return end
          assert(type(out) == "table", "moonsplice rows: system " .. sys.name .. " must return rows")
          local acc = s.access[sys.name]
          if not acc then acc = {}; s.access[sys.name] = acc end
          for _, r in ipairs(out) do
            local node = byid[r.id]
            if node then
              local a = acc[r.id]
              if not a then a = {}; acc[r.id] = a end
              for k in pairs(r) do if k ~= "id" then a[k] = true end end
              local set = {}
              for k, v in pairs(r) do if k ~= "id" then set[k] = v end end
              node:set(set)
            else
              -- an id no node has, under a world: an entity this frame alone (spawned, in a game)
              local world = r.parent and byid[r.parent]
              if not (world and world.kind == "world") then
                error(("moonsplice rows: system %s set no node %s (give a world parent to spawn an entity)")
                  :format(sys.name, tostring(r.id)), 0)
              end
              local list = world.state.spawn
              if not list then list = {}; world:set({ spawn = list }) end
              local e = {}
              for k, v in pairs(r) do if k ~= "parent" then e[k] = v end end
              -- solid = "asset:<id>" draws that asset's built solid
              if type(e.solid) == "string" and e.solid:match("^asset:") then
                local a = assets[e.solid:sub(7)]
                if not (a and a.src) then
                  error(("moonsplice rows: entity %s.solid names no asset %s"):format(tostring(r.id), e.solid), 0)
                end
                e.solid = a.src
              end
              list[#list + 1] = e
              local sp = s.spawned[sys.name]
              if not sp then sp = {}; s.spawned[sys.name] = sp end
              sp[tostring(r.id)] = true
            end
          end
        end)
      end
    end
    return byid, fns
  end
end

-- the game, from rows: rate and seed from `game`, init and step from systems game.init / game.step,
-- the script from `input`
function R.game(rows, M)
  if not next(rows.game) and not rows.system[1] then return nil end
  local init, step
  local extra = { ease = function(name, u) return M.ease.get(name)(u) end,
    color = function(c) return require("moonsplice.color").parse(c) end }
  for _, sys in ipairs(rows.system) do
    if sys.name == "shared" then extra.shared = R.load_system(sys.name, sys.source, extra, true) end
  end
  for _, sys in ipairs(rows.system) do
    if sys.name == "game.init" then init = R.load_system(sys.name, sys.source, extra) end
    if sys.name == "game.step" then step = R.load_system(sys.name, sys.source, extra) end
  end
  if not step then
    assert(not next(rows.game), "moonsplice rows: a game needs a system game.step")
    return nil
  end
  local script = {}
  for i, e in ipairs(rows.input) do
    local c = copy(e)
    c.n = nil
    script[i] = c
  end
  return { rate = rows.game.rate, seed = rows.game.seed, init = init, step = step,
    script = #script > 0 and script or nil }
end

-- ---------- dump: any comp as rows ----------

local function hex(c)
  local parts = {}
  for i = 1, 4 do
    local v = c[i] or 1
    local b = math.floor(v * 255 + 0.5)
    if math.abs(b / 255 - v) > 1e-9 then return nil end
    parts[i] = string.format("%02x", b)
  end
  if parts[4] == "ff" then parts[4] = nil end
  return "#" .. table.concat(parts)
end

local function plain(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" then return v end
  if t ~= "table" or depth > 6 then return nil end
  if v.kind and v.initial and v.id then return v.id end -- a node: its id
  local out = {}
  for k, x in pairs(v) do
    local p = plain(x, depth + 1)
    if p ~= nil then out[k] = p end
  end
  return out
end

-- rows from a comp. `compiled` is the comp after compile (its nodes and timeline); for a comp
-- authored as rows the rows are simply its own.
function R.dump(comp, opts)
  opts = opts or {}
  if comp.rows then return R.sort(copy(comp.rows)) end
  local rows = { schema = R.schema, comp = {}, node = {}, prop = {}, key = {}, motion = {}, system = {},
    asset = {}, fact = {}, input = {}, game = {}, expect = {} }
  for _, k in ipairs({ "width", "height", "duration", "fps", "color_space", "lint_allow", "brand" }) do
    rows.comp[k] = plain(comp[k])
  end
  rows.comp.background = hex(comp.background) or plain(comp.background)
  local defaults = opts.defaults or {}
  local code = {}
  local skip_group = {}
  for _, n in ipairs(opts.nodes or {}) do
    if n.generated_by then goto continue end
    local parent = n.initial.parent
    -- the kind is the constructor that was written (s:captions makes a text node; its row is captions)
    rows.node[#rows.node + 1] = { id = n.id, kind = n.made_by or n.kind, parent = parent and parent.id or nil,
      order = #rows.node + 1 }
    if n.initial.cues then skip_group[n.id .. "\0text"] = true end -- recorded from cues at compile
    -- what was written, when the node was made by a constructor call; its resolved props otherwise
    local from_authored = n.authored ~= nil
    for name, v in pairs(n.authored or n.initial) do
      if type(v) == "function" then
        -- code inside a prop is not data: shown as a system, and the comp is not editable as rows
        code[#code + 1] = { name = "code." .. n.id .. "." .. name, source = opts.source_of and opts.source_of(v) or "-- code" }
      elseif name == "kind" or name == "type" and n.kind == "ornament" then
        -- an ornament's own `kind` is its shape (the node's kind is the row's column)
        rows.prop[#rows.prop + 1] = { id = n.id, name = "shape", value = plain(v) }
      elseif name ~= "parent" and name ~= "id" and not (not from_authored and defaults[name] ~= nil and same(defaults[name], v)) then
        local value
        if (name == "color" or name == "outline_color") and type(v) == "table" then value = hex(v) or plain(v)
        else value = plain(v) end
        if value ~= nil then rows.prop[#rows.prop + 1] = { id = n.id, name = name, value = value } end
      end
    end
    ::continue::
  end
  local tl = comp.timeline
  for _, g in ipairs(tl and tl.order or {}) do
    local id, name, last = g.node.id, g.prop, nil
    if skip_group[id .. "\0" .. name] then goto next_group end
    local function key(t, value, ease)
      local v = (name == "color" and type(value) == "table") and (hex(value) or plain(value)) or plain(value)
      if last and last.t == t then
        if same(last.value, v) then return end
        last.value, last.ease = v, ease -- a jump at a segment boundary: the later value wins
        return
      end
      last = { id = id, name = name, t = t, value = v, ease = ease }
      rows.key[#rows.key + 1] = last
    end
    for _, seg in ipairs(g.segs) do
      if seg.kind == nil then
        key(seg.t0, seg.from, nil)
        key(seg.t1, seg.to, seg.ease_id ~= "linear" and seg.ease_id or nil)
      elseif seg.kind == "step" then
        key(seg.t0, seg.to, "step")
      elseif seg.kind == "wiggle" then
        rows.motion[#rows.motion + 1] = { id = id, name = name, t0 = seg.t0, t1 = seg.t1, curve = "wiggle",
          params = { amp = seg.amp, freq = seg.freq, seed = seg.seed, ramp = seg.ramp } }
      elseif seg.kind == "bake" then
        rows.motion[#rows.motion + 1] = { id = id, name = name, t0 = seg.t0, t1 = seg.t1, curve = "bake",
          params = { samples = plain(seg.samples) } }
      elseif seg.kind == "path" and seg.axis == "x" then
        rows.motion[#rows.motion + 1] = { id = id, name = "xy", t0 = seg.t0, t1 = seg.t1, curve = "path",
          params = { points = plain(seg.lut.waypoints), ease = seg.lut.ease_name } }
      end
    end
    ::next_group::
  end
  for i, c in ipairs(code) do
    rows.system[#rows.system + 1] = { name = c.name, order = 1000 + i, source = c.source, opaque = true }
  end
  -- the object API's views and game functions are code with handles in them: shown, not editable
  for i, src in ipairs(opts.views or {}) do
    rows.system[#rows.system + 1] = { name = "view." .. i, order = i, source = src, opaque = true }
  end
  return R.sort(rows)
end

-- ---------- patches (ROWS.md §6) ----------

local function find(list, pred)
  for i, r in ipairs(list) do if pred(r) then return i, r end end
end

local function node_of(rows, id) return find(rows.node, function(n) return n.id == id end) end

-- the node and everything under it (children by parent, recursively)
local function subtree(rows, id)
  local out, seen, frontier = {}, { [id] = true }, { id }
  while #frontier > 0 do
    local cur = table.remove(frontier)
    out[#out + 1] = cur
    for _, n in ipairs(rows.node) do
      if n.parent == cur and not seen[n.id] then seen[n.id] = true; frontier[#frontier + 1] = n.id end
    end
  end
  return out
end

local MOVES = {}

-- a value of the wrong type is rejected at the patch, not found later as a render artifact
local NUMBER = {}
for k in ("x y z w h r rx rotation scale opacity size progress tracking reveal outline weight amp freq mix "
  .. "yaw pitch roll dolly fov aperture maxcoc focus_u focus_v truck_u truck_v look_x look_y look_z cam_x cam_y cam_z "
  .. "sx sy sz volume at from duration media_start fade_in fade_out leading wrap spacing n seed life emit "
  .. "emit_window heading spread speed gravity metallic roughness reflectance emissive_strength intensity "
  .. "range angle softness detail ambient bloom near far"):gmatch("%S+") do NUMBER[k] = true end
local STRING = { text = true, src = true, font = true, anchor = true, blend = true, primitive = true, shape = true }
-- returns the value to store: a numeric prop given a string that is exactly a number ("500",
-- "0.9") takes the number, since a model writing JSON often quotes them; anything else is refused
local function check_value(name, v)
  if v == nil then return nil end
  local ok
  local what = name
  if NUMBER[name] or name:match("^effect_") or name:match("^fx_") then
    if type(v) == "string" and v:match("^%s*[-+]?%d*%.?%d+[eE]?[-+]?%d*%s*$") and tonumber(v) then v = tonumber(v) end
    ok, what = type(v) == "number", name .. " needs a number"
    -- a mesh's size is its three extents
    if name == "size" and type(v) == "table" then
      ok = #v == 3 and type(v[1]) == "number" and type(v[2]) == "number" and type(v[3]) == "number"
      what = "size needs a number (text) or {sx, sy, sz} (mesh)"
    end
  elseif STRING[name] then
    ok, what = type(v) == "string", name .. " needs a string"
  elseif name == "color" or name == "emissive" or name == "background" then
    ok = type(v) == "string" and v:match("^#%x+$") and (#v == 4 or #v == 5 or #v == 7 or #v == 9)
      or type(v) == "table" and type(v[1]) == "number"
    what = name .. ' needs "#rrggbb", "#rrggbbaa" or {r,g,b,a}'
  else
    return v
  end
  if not ok then error(("%s, not %s"):format(what, type(v) == "string" and ("%q"):format(v) or type(v)), 0) end
  return v
end
R.check_value = check_value

function MOVES.add_node(rows, p, touched)
  local n = p.node or error("add_node needs node", 0)
  if type(n.id) ~= "string" or n.id == "" then error("the node needs a string id", 0) end
  if node_of(rows, n.id) then error("a node " .. n.id .. " exists already", 0) end
  if type(n.kind) ~= "string" then error("the node needs a kind", 0) end
  if n.parent and not node_of(rows, n.parent) then error("no parent node " .. tostring(n.parent), 0) end
  local order = n.order
  if not order then order = 0; for _, m in ipairs(rows.node) do if m.order > order then order = m.order end end; order = order + 1 end
  rows.node[#rows.node + 1] = { id = n.id, kind = n.kind, parent = n.parent, order = order }
  touched[#touched + 1] = { id = n.id }
  for name, v in pairs(n) do
    if name ~= "id" and name ~= "kind" and name ~= "parent" and name ~= "order" then
      rows.prop[#rows.prop + 1] = { id = n.id, name = name, value = copy(check_value(name, v)) }
      touched[#touched + 1] = { id = n.id, name = name }
    end
  end
end

function MOVES.set_prop(rows, p, touched)
  local _, n = node_of(rows, p.id)
  if not n then error("no node " .. tostring(p.id), 0) end
  if type(p.name) ~= "string" or p.name == "id" or p.name == "kind" then error("cannot set " .. tostring(p.name), 0) end
  if p.name == "parent" or p.name == "order" then
    if p.name == "parent" and p.value ~= nil and not node_of(rows, p.value) then error("no parent node " .. tostring(p.value), 0) end
    n[p.name] = p.value
  else
    p.value = check_value(p.name, p.value)
    local i = find(rows.prop, function(r) return r.id == p.id and r.name == p.name end)
    if p.value == nil then
      if i then table.remove(rows.prop, i) end
    elseif i then rows.prop[i].value = copy(p.value)
    else rows.prop[#rows.prop + 1] = { id = p.id, name = p.name, value = copy(p.value) } end
  end
  touched[#touched + 1] = { id = p.id, name = p.name }
end

-- a key time is seconds or a fact reference; "2" is seconds
-- a time a model wrote: a number, a quoted number ("0.2"), seconds as `rows --brief` prints them
-- ("0.20s"), or a fact reference (beat:4), which stays as written
local function key_time(t)
  if type(t) == "string" then
    local n = t:match("^%s*([-+]?%d*%.?%d+)%s*s?%s*$")
    if n and tonumber(n) then return tonumber(n) end
  end
  return t
end

local function key_at(rows, p)
  return find(rows.key, function(k)
    if k.id ~= p.id or k.name ~= p.name then return false end
    if type(k.t) == "number" and type(p.t) == "number" then return math.abs(k.t - p.t) < 1e-6 end
    return k.t == p.t
  end)
end

function MOVES.add_key(rows, p, touched)
  p.t = key_time(p.t)
  if not node_of(rows, p.id) then error("no node " .. tostring(p.id), 0) end
  if type(p.name) ~= "string" then error("a key needs a prop name", 0) end
  if type(p.t) ~= "number" and type(p.t) ~= "string" then error("a key needs t (seconds or a fact reference)", 0) end
  if p.value == nil then error("a key needs a value", 0) end
  p.value = check_value(p.name, p.value)
  if key_at(rows, p) then error(("a key on %s.%s at %s exists already (move_key)"):format(p.id, p.name, tostring(p.t)), 0) end
  rows.key[#rows.key + 1] = { id = p.id, name = p.name, t = p.t, value = copy(p.value), ease = p.ease }
  touched[#touched + 1] = { id = p.id, name = p.name }
end

function MOVES.move_key(rows, p, touched)
  p.t, p.to_t = key_time(p.t), key_time(p.to_t)
  local _, k = key_at(rows, p)
  if not k then error(("no key on %s.%s at %s"):format(tostring(p.id), tostring(p.name), tostring(p.t)), 0) end
  if p.to_t ~= nil and p.to_t ~= p.t then
    if key_at(rows, { id = p.id, name = p.name, t = p.to_t }) then error("a key is already at " .. tostring(p.to_t), 0) end
    k.t = p.to_t
  end
  if p.value ~= nil then k.value = copy(check_value(p.name, p.value)) end
  if p.ease ~= nil then k.ease = p.ease ~= "" and p.ease or nil end
  touched[#touched + 1] = { id = p.id, name = p.name }
end

function MOVES.drop_key(rows, p, touched)
  p.t = key_time(p.t)
  local i = key_at(rows, p)
  if not i then error(("no key on %s.%s at %s"):format(tostring(p.id), tostring(p.name), tostring(p.t)), 0) end
  table.remove(rows.key, i)
  touched[#touched + 1] = { id = p.id, name = p.name }
end

-- tie a key's time, or a prop's value, to a fact: { id, name, t, fact } moves that key to the
-- fact's time; { id, name, fact, value_of = "t0" } sets the prop to the fact's time
function MOVES.bind(rows, p, touched)
  if type(p.fact) ~= "string" or not p.fact:match("^[%w_]+:") then error("bind needs fact = \"pred:args\"", 0) end
  if p.t ~= nil then
    return MOVES.move_key(rows, { id = p.id, name = p.name, t = p.t, to_t = p.fact }, touched)
  end
  error("bind needs the key's t", 0)
end

function MOVES.add_system(rows, p, touched)
  if type(p.name) ~= "string" or p.name == "" then error("a system needs a name", 0) end
  if find(rows.system, function(s) return s.name == p.name end) then error("a system " .. p.name .. " exists (edit_system)", 0) end
  if type(p.source) ~= "string" then error("a system needs source", 0) end
  R.load_system(p.name, p.source, nil, p.name == "shared")
  local order = p.order
  if not order then order = 0; for _, s in ipairs(rows.system) do if s.order > order then order = s.order end end; order = order + 1 end
  rows.system[#rows.system + 1] = { name = p.name, order = order, source = p.source }
  touched[#touched + 1] = { id = "system:" .. p.name }
end

function MOVES.edit_system(rows, p, touched)
  local _, s = find(rows.system, function(x) return x.name == p.name end)
  if not s then error("no system " .. tostring(p.name), 0) end
  if s.opaque then error("system " .. s.name .. " is the object API's code; convert the comp to rows first", 0) end
  if p.source then R.load_system(p.name, p.source, nil, p.name == "shared"); s.source = p.source end
  if p.order then s.order = p.order end
  touched[#touched + 1] = { id = "system:" .. p.name }
end

function MOVES.derive(rows, p, touched)
  local a = p.asset or p
  if type(a.id) ~= "string" or type(a.src) ~= "string" then error("derive needs asset { id, src, derive }", 0) end
  local i = find(rows.asset, function(x) return x.id == a.id end)
  -- a model writing JSON quotes booleans often: "true"/"false" in an op are the booleans
  local ops = copy(a.derive)
  if type(ops) == "table" then
    for k, v in pairs(ops) do
      if v == "true" then ops[k] = true elseif v == "false" then ops[k] = false
      elseif type(v) == "string" and v:match("^%s*[-+]?%d*%.?%d+%s*$") then ops[k] = tonumber(v) end
    end
  end
  local row = { id = a.id, src = a.src, derive = ops }
  if i then rows.asset[i] = row else rows.asset[#rows.asset + 1] = row end
  touched[#touched + 1] = { id = "asset:" .. a.id }
end

-- solid: an asset built by Manifold from a tree of plain values (.robot/docs/solids.robot); a mesh node shows
-- it with src = "asset:<id>", a system's entity with solid = "asset:<id>". { asset = { id, solid } }
function MOVES.solid(rows, p, touched)
  local a = p.asset or p
  if type(a.id) ~= "string" or type(a.solid) ~= "table" then error("solid needs asset { id, solid = tree }", 0) end
  local i = find(rows.asset, function(x) return x.id == a.id end)
  local row = { id = a.id, solid = copy(a.solid) }
  if i then rows.asset[i] = row else rows.asset[#rows.asset + 1] = row end
  touched[#touched + 1] = { id = "asset:" .. a.id }
end

function MOVES.remove(rows, p, touched)
  if p.system then
    local i = find(rows.system, function(x) return x.name == p.system end)
    if not i then error("no system " .. tostring(p.system), 0) end
    table.remove(rows.system, i)
    touched[#touched + 1] = { id = "system:" .. p.system }
    return
  end
  if not node_of(rows, p.id) then error("no node " .. tostring(p.id), 0) end
  local gone = {}
  for _, id in ipairs(subtree(rows, p.id)) do gone[id] = true; touched[#touched + 1] = { id = id } end
  local function keep(list, f)
    local out = {}
    for _, r in ipairs(list) do if f(r) then out[#out + 1] = r end end
    return out
  end
  rows.node = keep(rows.node, function(n) return not gone[n.id] end)
  rows.prop = keep(rows.prop, function(r) return not gone[r.id] end)
  rows.key = keep(rows.key, function(r) return not gone[r.id] end)
  rows.motion = keep(rows.motion, function(r) return not gone[r.id] end)
  -- references to what is gone go too
  for _, r in ipairs(rows.prop) do
    if R.REF[r.name] and gone[r.value] then r.value = nil; touched[#touched + 1] = { id = r.id, name = r.name } end
  end
  rows.prop = keep(rows.prop, function(r) return r.value ~= nil end)
end

R.MOVES = {}
for k in pairs(MOVES) do R.MOVES[#R.MOVES + 1] = k end
table.sort(R.MOVES)

-- Apply patches in order. Each is checked by `check(rows)` after it lands (a compile, by the host);
-- one that fails is undone and reported, and the rest still apply.
function R.apply(rows, patches, check)
  local res = { applied = {}, rejected = {}, touched = {} }
  for _, p in ipairs(patches) do
    local before = copy(rows)
    local touched = {}
    local move = MOVES[p.move or ""]
    local ok, err
    if not move then
      ok, err = false, "unknown move " .. tostring(p.move) .. " (" .. table.concat(R.MOVES, ", ") .. ")"
    else
      ok, err = pcall(move, rows, p, touched)
      if ok then
        R.sort(rows)
        if check then ok, err = pcall(check, rows) end
      end
    end
    if ok then
      res.applied[#res.applied + 1] = p
      for _, t in ipairs(touched) do res.touched[#res.touched + 1] = t end
    else
      for k in pairs(rows) do rows[k] = nil end
      for k, v in pairs(before) do rows[k] = v end
      res.rejected[#res.rejected + 1] = { patch = p, why = tostring(err):gsub("^moonsplice rows: ", "") }
    end
  end
  return res
end

-- ---------- the comp file, in rows form ----------

local IDENT = "^[%a_][%w_]*$"
local LUA_KEYWORDS = { ["and"] = 1, ["break"] = 1, ["do"] = 1, ["else"] = 1, ["elseif"] = 1, ["end"] = 1,
  ["false"] = 1, ["for"] = 1, ["function"] = 1, ["goto"] = 1, ["if"] = 1, ["in"] = 1, ["local"] = 1, ["nil"] = 1,
  ["not"] = 1, ["or"] = 1, ["repeat"] = 1, ["return"] = 1, ["then"] = 1, ["true"] = 1, ["until"] = 1, ["while"] = 1 }

local function lua_key(k)
  if type(k) == "string" and k:match(IDENT) and not LUA_KEYWORDS[k] then return k end
  return "[" .. (type(k) == "number" and num(k) or string.format("%q", k)) .. "]"
end

local function lua_val(v, out)
  local t = type(v)
  if t == "number" then out[#out + 1] = num(v)
  elseif t == "string" then
    if v:find("\n") then
      local eq = "="
      while v:find("]" .. eq .. "]", 1, true) do eq = eq .. "=" end
      out[#out + 1] = "[" .. eq .. "[\n" .. v .. "]" .. eq .. "]"
    else
      out[#out + 1] = string.format("%q", v)
    end
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "table" then
    if is_array(v) then
      out[#out + 1] = "{ "
      for i, x in ipairs(v) do if i > 1 then out[#out + 1] = ", " end lua_val(x, out) end
      out[#out + 1] = " }"
    else
      out[#out + 1] = "{ "
      local first = true
      for _, k in ipairs(sorted_keys(v)) do
        if not first then out[#out + 1] = ", " end
        first = false
        out[#out + 1] = lua_key(k) .. " = "
        lua_val(v[k], out)
      end
      out[#out + 1] = " }"
    end
  else
    out[#out + 1] = "nil"
  end
end

local function lv(v) local o = {}; lua_val(v, o); return table.concat(o) end

local COMP_FIRST = { "width", "height", "duration", "fps", "background" }

function R.lua(rows)
  R.sort(rows)
  local o = { "-- A Moonsplice composition in rows form (.robot/docs/rows.robot, msr/1). People and the agent edit the\n",
    "-- same rows; `moonsplice rows` prints them, `moonsplice patch` applies typed edits.\n",
    "local e = require(\"moonsplice\")\n\nreturn e.comp {\n" }
  local done = {}
  local line = {}
  for _, k in ipairs(COMP_FIRST) do
    if rows.comp[k] ~= nil then line[#line + 1] = k .. " = " .. lv(rows.comp[k]); done[k] = true end
  end
  if #line > 0 then o[#o + 1] = "  " .. table.concat(line, ", ") .. ",\n" end
  for _, k in ipairs(sorted_keys(rows.comp)) do
    if not done[k] then o[#o + 1] = "  " .. lua_key(k) .. " = " .. lv(rows.comp[k]) .. ",\n" end
  end
  -- nodes, each with its props; order is the order written, so it is left out when it is the position
  local props = {}
  for _, p in ipairs(rows.prop) do props[p.id] = props[p.id] or {}; props[p.id][#props[p.id] + 1] = p end
  if #rows.node > 0 then
    o[#o + 1] = "\n  nodes = {\n"
    for i, n in ipairs(rows.node) do
      local parts = { "id = " .. lv(n.id), "kind = " .. lv(n.kind) }
      if n.parent then parts[#parts + 1] = "parent = " .. lv(n.parent) end
      if n.order ~= i then parts[#parts + 1] = "order = " .. lv(n.order) end
      for _, p in ipairs(props[n.id] or {}) do parts[#parts + 1] = lua_key(p.name) .. " = " .. lv(p.value) end
      o[#o + 1] = "    { " .. table.concat(parts, ", ") .. " },\n"
    end
    o[#o + 1] = "  },\n"
  end
  if #rows.key > 0 then
    o[#o + 1] = "\n  -- { node, prop, t, value, ease }: the curve runs from the previous key to this one\n  keys = {\n"
    for _, k in ipairs(rows.key) do
      local parts = { lv(k.id), lv(k.name), lv(k.t), lv(k.value) }
      if k.ease then parts[5] = lv(k.ease) end
      o[#o + 1] = "    { " .. table.concat(parts, ", ") .. " },\n"
    end
    o[#o + 1] = "  },\n"
  end
  if #rows.motion > 0 then
    o[#o + 1] = "\n  motion = {\n"
    for _, m in ipairs(rows.motion) do
      o[#o + 1] = ("    { id = %s, name = %s, t0 = %s, t1 = %s, curve = %s, params = %s },\n"):format(lv(m.id),
        lv(m.name), lv(m.t0), lv(m.t1), lv(m.curve), lv(m.params or {}))
    end
    o[#o + 1] = "  },\n"
  end
  if #rows.asset > 0 then
    o[#o + 1] = "\n  assets = {\n"
    for _, a in ipairs(rows.asset) do
      if a.solid then
        o[#o + 1] = ("    { id = %s, solid = %s%s },\n"):format(lv(a.id), lv(a.solid), a.parts and (", parts = " .. lv(a.parts)) or "")
      else
        o[#o + 1] = ("    { id = %s, src = %s%s },\n"):format(lv(a.id), lv(a.src), a.derive and (", derive = " .. lv(a.derive)) or "")
      end
    end
    o[#o + 1] = "  },\n"
  end
  if #rows.expect > 0 then
    o[#o + 1] = "\n  expect = {\n"
    for _, x in ipairs(rows.expect) do o[#o + 1] = "    " .. lv(x) .. ",\n" end
    o[#o + 1] = "  },\n"
  end
  if #rows.fact > 0 then
    o[#o + 1] = "\n  facts = {\n"
    for _, f in ipairs(rows.fact) do
      local parts = { "pred = " .. lv(f.pred), "args = " .. lv(f.args), "t0 = " .. lv(f.t0) }
      if f.t1 then parts[#parts + 1] = "t1 = " .. lv(f.t1) end
      if f.src and f.src ~= "" then parts[#parts + 1] = "src = " .. lv(f.src) end
      if f.conf then parts[#parts + 1] = "conf = " .. lv(f.conf) end
      o[#o + 1] = "    { " .. table.concat(parts, ", ") .. " },\n"
    end
    o[#o + 1] = "  },\n"
  end
  if next(rows.game) then o[#o + 1] = "\n  game = " .. lv(rows.game) .. ",\n" end
  if #rows.input > 0 then
    o[#o + 1] = "\n  input = {\n"
    for _, e in ipairs(rows.input) do
      local c = copy(e); c.n = nil
      o[#o + 1] = "    " .. lv(c) .. ",\n"
    end
    o[#o + 1] = "  },\n"
  end
  if #rows.system > 0 then
    o[#o + 1] = "\n  -- systems: pure (t, state, q) -> rows, run every frame after the keys, in order\n  systems = {\n"
    for _, s in ipairs(rows.system) do
      o[#o + 1] = ("    { name = %s, order = %s, source = %s },\n"):format(lv(s.name), lv(s.order), lv(s.source))
    end
    o[#o + 1] = "  },\n"
  end
  o[#o + 1] = "}\n"
  return table.concat(o)
end

return R
