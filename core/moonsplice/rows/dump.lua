-- Part of moonsplice.rows (core/moonsplice/rows/init.lua): see its head for the module's contract.
local R = require("moonsplice.rows")
local copy, num, same, plain = R._.copy, R._.num, R._.same, R._.plain
local find, is_array, sorted_keys, hex = R._.find, R._.is_array, R._.sorted_keys, R._.hex

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
      o[#o + 1] = ("    { name = %s, order = %s,%s source = %s },\n"):format(lv(s.name), lv(s.order),
        s.clip and (" clip = " .. lv(s.clip) .. ",") or "", lv(s.source))
    end
    o[#o + 1] = "  },\n"
  end
  o[#o + 1] = "}\n"
  return table.concat(o)
end
