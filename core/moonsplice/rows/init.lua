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

local function find(list, pred)
  for i, r in ipairs(list) do if pred(r) then return i, r end end
end

-- what the parts share, and the parts (they load after this table is registered as moonsplice.rows)
R._ = { copy = copy, num = num, same = same, ROW_FIELDS = ROW_FIELDS, plain = plain, find = find,
  is_array = is_array, sorted_keys = sorted_keys, hex = hex }
package.loaded["moonsplice.rows"] = R
require("moonsplice.rows.dump")
require("moonsplice.rows.moves")
require("moonsplice.rows.scene")

return R
