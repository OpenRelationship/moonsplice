-- Part of moonsplice.rows (core/moonsplice/rows/init.lua): see its head for the module's contract.
local R = require("moonsplice.rows")
local copy, num, same, ROW_FIELDS = R._.copy, R._.num, R._.same, R._.ROW_FIELDS

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

