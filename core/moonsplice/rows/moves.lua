-- Part of moonsplice.rows (core/moonsplice/rows/init.lua): see its head for the module's contract.
local R = require("moonsplice.rows")
local copy, plain, find = R._.copy, R._.plain, R._.find

local function node_of(rows, id) return find(rows.node, function(n) return n.id == id end) end

-- a node a key may name: a row, or a node inside a precomp instance (<instance>/<child>), which is
-- made again from the precomp's file at compile; the compile check then proves the child exists
local function keyable(rows, id)
  if type(id) ~= "string" then return false end
  if node_of(rows, id) then return true end
  local inst = id:match("^(.-)/")
  local _, n = node_of(rows, inst or "")
  return n ~= nil and n.kind == "precomp"
end

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
for k in ("offset length gap overlap time"):gmatch("%S+") do NUMBER[k] = true end
local STRING = { text = true, src = true, font = true, anchor = true, blend = true, primitive = true, shape = true,
  matte = true }
local BOOLEAN = { loop = true, reverse = true, isolate = true }
local MATTES = { alpha = true, alpha_inverted = true, luma = true, luma_inverted = true }
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
  elseif BOOLEAN[name] then
    if v == "true" then v = true elseif v == "false" then v = false end
    ok, what = type(v) == "boolean", name .. " needs true or false"
  elseif name == "start" then
    -- seconds in the parent's time, or a fact the clip starts on (beat:8)
    if type(v) == "string" and v:match("^%s*[-+]?%d*%.?%d+%s*s?%s*$") then v = tonumber((v:gsub("s?%s*$", ""))) end
    ok = type(v) == "number" or type(v) == "string" and v:match("^[%w_]+:.+") ~= nil
    what = "start needs seconds or a fact reference (beat:8)"
  elseif name == "hold" then
    if v == "true" then v = true elseif v == "false" then v = false end
    ok = type(v) == "boolean" or v == "start" or v == "end"
    what = 'hold needs true, false, "start" or "end"'
  elseif name == "matte_mode" then
    ok, what = MATTES[v] == true, "matte_mode needs alpha, alpha_inverted, luma or luma_inverted"
  elseif name == "transition" then
    -- false: a cut here, though the track has a transition for every cut
    if v ~= false then
      local ok2, err = pcall(require("moonsplice.track").transition, v, "transition")
      if not ok2 then error((tostring(err):gsub("^transition: ", "")), 0) end
    end
    return v
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
  if not keyable(rows, p.id) then error("no node " .. tostring(p.id), 0) end
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
  if p.clip ~= nil and type(p.clip) ~= "string" then error("clip needs the id of a clip", 0) end
  local order = p.order
  if not order then order = 0; for _, s in ipairs(rows.system) do if s.order > order then order = s.order end end; order = order + 1 end
  rows.system[#rows.system + 1] = { name = p.name, order = order, source = p.source, clip = p.clip }
  touched[#touched + 1] = { id = "system:" .. p.name }
end

function MOVES.edit_system(rows, p, touched)
  local _, s = find(rows.system, function(x) return x.name == p.name end)
  if not s then error("no system " .. tostring(p.name), 0) end
  if s.opaque then error("system " .. s.name .. " is the object API's code; convert the comp to rows first", 0) end
  if p.source then R.load_system(p.name, p.source, nil, p.name == "shared"); s.source = p.source end
  if p.order then s.order = p.order end
  -- clip = "" (or JSON null is not enough: a missing field leaves it) runs it in comp time again
  if p.clip ~= nil then
    if type(p.clip) ~= "string" then error("clip needs the id of a clip", 0) end
    s.clip = p.clip ~= "" and p.clip or nil
  end
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
  -- and keys on a removed precomp's inner nodes (<instance>/<child>)
  local function inside(id) return gone[id] or gone[tostring(id):match("^(.-)/") or ""] end
  rows.node = keep(rows.node, function(n) return not gone[n.id] end)
  rows.prop = keep(rows.prop, function(r) return not gone[r.id] end)
  rows.key = keep(rows.key, function(r) return not inside(r.id) end)
  rows.motion = keep(rows.motion, function(r) return not inside(r.id) end)
  for _, s in ipairs(rows.system) do
    if s.clip and gone[s.clip] then s.clip = nil; touched[#touched + 1] = { id = "system:" .. s.name } end
  end
  -- references to what is gone go too
  for _, r in ipairs(rows.prop) do
    if R.REF[r.name] and gone[r.value] then r.value = nil; touched[#touched + 1] = { id = r.id, name = r.name } end
  end
  rows.prop = keep(rows.prop, function(r) return r.value ~= nil end)
end

-- move_clip: put a clip at another place in its track, { id, index } (1 is first) or { id, before }
-- or { id, after } (a sibling clip's id). The track lays clips end to end, so the rest ripple. The
-- clips' subtrees keep their draw order among themselves and take the places the track's nodes held,
-- so nothing outside the track moves in the draw order.
function MOVES.move_clip(rows, p, touched)
  local _, c = node_of(rows, p.id)
  if not c then error("no node " .. tostring(p.id), 0) end
  local _, track = node_of(rows, c.parent or "")
  if not (track and track.kind == "track") then error(tostring(p.id) .. " is not in a track", 0) end
  local clips = {}
  for _, n in ipairs(rows.node) do if n.parent == track.id then clips[#clips + 1] = n.id end end
  local from
  for i, id in ipairs(clips) do if id == p.id then from = i end end
  table.remove(clips, from)
  local to
  if p.index ~= nil then
    to = tonumber(p.index)
    if not to or to < 1 or to > #clips + 1 or to ~= math.floor(to) then
      error(("index needs a whole number from 1 to %d"):format(#clips + 1), 0)
    end
  else
    local ref = p.before or p.after
    if type(ref) ~= "string" then error("move_clip needs index, before or after", 0) end
    for i, id in ipairs(clips) do if id == ref then to = p.before and i or i + 1 end end
    if not to then error(("%s is not another clip in track %s"):format(ref, track.id), 0) end
  end
  table.insert(clips, to, p.id)
  -- each clip's subtree, in its present draw order; then the same order values, handed out again
  local blocks, slots = {}, {}
  for _, id in ipairs(clips) do
    local set = {}
    for _, sid in ipairs(subtree(rows, id)) do set[sid] = true end
    local block = {}
    for _, n in ipairs(rows.node) do
      if set[n.id] then block[#block + 1] = n; slots[#slots + 1] = n.order end
    end
    blocks[#blocks + 1] = block
  end
  table.sort(slots)
  local k = 0
  for _, block in ipairs(blocks) do
    for _, n in ipairs(block) do k = k + 1; n.order = slots[k] end
  end
  for _, id in ipairs(clips) do touched[#touched + 1] = { id = id, name = "order" } end
end

R.MOVES = {}
for k in pairs(MOVES) do R.MOVES[#R.MOVES + 1] = k end
table.sort(R.MOVES)

-- Apply patches in order. Each is checked by `check(rows)` after it lands (a compile, by the host);
-- one that fails is undone and reported, and the rest still apply.
-- One move's shape, applied to rows in place; the comp check comes after. ok, err.
local function shape(rows, p, touched)
  local move = MOVES[p.move or ""]
  if not move then return false, "unknown move " .. tostring(p.move) .. " (" .. table.concat(R.MOVES, ", ") .. ")" end
  local ok, err = pcall(move, rows, p, touched)
  if ok then R.sort(rows) end
  return ok, err
end

local function restore(rows, before)
  for k in pairs(rows) do rows[k] = nil end
  for k, v in pairs(before) do rows[k] = v end
end

-- A patch is a batch: moves that only work together (a game.init that sets state and the hud that reads it)
-- must land together. So the batch is applied whole and checked once. When that fails, each move is tried
-- alone, in order, and the ones refused are tried again against what has landed until nothing more lands;
-- a move is refused with the error it raised last.
function R.apply(rows, patches, check)
  local res = { applied = {}, rejected = {}, touched = {} }
  local start = copy(rows)
  local whole, all_ok = {}, true
  for _, p in ipairs(patches) do
    local ok = shape(rows, p, whole)
    if not ok then all_ok = false break end
  end
  local together
  if all_ok then
    local ok, err = true, nil
    if check then ok, err = pcall(check, rows) end
    if ok then
      for _, p in ipairs(patches) do res.applied[#res.applied + 1] = p end
      res.touched = whole
      return res
    end
    -- the batch as a whole fails: that error names what the patch as written breaks, and leads each refusal
    together = (tostring(err):gsub("^moonsplice rows: ", ""))
  end
  restore(rows, start)
  local pending, why = {}, {}
  for i, p in ipairs(patches) do pending[#pending + 1] = i end
  repeat
    local landed, still = false, {}
    for _, i in ipairs(pending) do
      local p, before, touched = patches[i], copy(rows), {}
      local ok, err = shape(rows, p, touched)
      if ok and check then ok, err = pcall(check, rows) end
      if ok then
        landed = true
        res.applied[#res.applied + 1] = p
        for _, t in ipairs(touched) do res.touched[#res.touched + 1] = t end
      else
        restore(rows, before)
        why[i], still[#still + 1] = err, i
      end
    end
    pending = still
  until not landed or #pending == 0
  for _, i in ipairs(pending) do
    local alone = (tostring(why[i]):gsub("^moonsplice rows: ", ""))
    res.rejected[#res.rejected + 1] = { patch = patches[i],
      why = together and #patches > 1 and ("with the whole patch applied: %s (this move alone: %s)"):format(together, alone) or alone }
  end
  return res
end

-- ---------- the comp file, in rows form ----------

