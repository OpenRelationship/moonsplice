-- `s:world` on Bevy: the world node and its children, at t, as the document render/src/world.rs
-- draws (through cs_world_render in scene/). A world can also hand over rows of its own:
-- `entities = function(t, state)` returns { {id=, shape=, pos={x,y,z}, ...}, ... } every frame,
-- with `state` the game's state when the comp is a game, so data or play drives the scene.
local ffi = require("ffi")
local scene = require("scene")

local W = {}

ffi.cdef([[
int cs_world_render(const char *id, const uint8_t *doc, size_t doc_len, uint16_t w, uint16_t h,
                    uint8_t *out, size_t out_len);
]])

local lib
pcall(function() lib = ffi.load(require("native").lib("moonsplice_scene")) end)
W.available = lib ~= nil and os.getenv("MOONSPLICE_WORLD") ~= "scene3d"

-- JSON, enough for a world document: numbers, strings, booleans, arrays, objects
local function enc(v, out)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then v = 0 end
    out[#out + 1] = string.format("%.6g", v)
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      out[#out + 1] = "["
      for i, x in ipairs(v) do if i > 1 then out[#out + 1] = "," end enc(x, out) end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, x in pairs(v) do
        if type(k) == "string" and type(x) ~= "function" and type(x) ~= "userdata" then
          if not first then out[#out + 1] = "," end
          first = false
          out[#out + 1] = '"' .. k .. '":'
          enc(x, out)
        end
      end
      out[#out + 1] = "}"
    end
  else
    out[#out + 1] = "null"
  end
end
function W.encode(v) local out = {}; enc(v, out); return table.concat(out) end

local function rgba(c, opacity)
  if type(c) == "string" then c = require("moonsplice.color").parse(c) end
  if type(c) ~= "table" then return nil end
  return { c[1], c[2], c[3], (c[4] or 1) * (opacity or 1) }
end

-- the old camera: a position and a target, with yaw/pitch orbiting the position about the target
local function camera(node)
  local px, py, pz = node:get("cam_x") or 0, node:get("cam_y") or 0.35, node:get("cam_z") or 3.2
  local lx, ly, lz = node:get("look_x") or 0, node:get("look_y") or 0, node:get("look_z") or 0
  local dx, dy, dz = px - lx, py - ly, pz - lz
  local yaw, pitch = node:get("yaw") or 0, node:get("pitch") or 0
  if yaw ~= 0 then
    local c, s = math.cos(yaw), math.sin(yaw)
    dx, dz = dx * c + dz * s, -dx * s + dz * c
  end
  if pitch ~= 0 then
    local c, s = math.cos(pitch), math.sin(pitch)
    dy, dz = dy * c - dz * s, dy * s + dz * c
  end
  return { pos = { lx + dx, ly + dy, lz + dz }, look = { lx, ly, lz }, fov = node:get("fov") or 0.7,
    near = node.initial.near or 0.05, far = node.initial.far or 200 }
end

local MESH_PROPS = { "metallic", "roughness", "reflectance", "emissive_strength", "unlit", "double_sided", "detail" }

function W.document(comp, node, t)
  local i = node.initial
  local doc = {
    camera = camera(node),
    background = rgba(node:get("background") or i.background) or { 0, 0, 0, 0 },
    ambient = { color = rgba(i.ambient_color or "#ffffff"), brightness = node:get("ambient") or i.ambient or 160 },
    bloom = node:get("bloom") or i.bloom,
    fog = i.fog and { color = rgba(i.fog.color or "#808a94"), start = i.fog.start or 5, ["end"] = i.fog["end"] or 40 } or nil,
    tonemapping = i.tonemapping,
    entities = {},
  }
  local rows, lit = doc.entities, false
  for _, child in ipairs(comp.nodes) do
    if child.initial.parent == node then
      local ci = child.initial
      if child.kind == "light" then
        lit = true
        -- type says which light; directional unless it says point or spot. (Every node carries x = 0
        -- and every light a default dir, so neither can mean "point": that rule once made every
        -- authored light a point light at the world's origin.)
        local kind = ci.type or "directional"
        rows[#rows + 1] = {
          id = child.id or tostring(#rows), light = kind,
          color = rgba(child:get("color") or ci.color or "#ffffff"),
          intensity = (child:get("intensity") or ci.intensity or 1) * (kind == "directional" and 3500 or 900000),
          dir = ci.dir, pos = { child:get("x") or 0, child:get("y") or 0, child:get("z") or 0 },
          range = ci.range, shadows = ci.shadows, angle = ci.angle,
        }
      elseif child.kind == "mesh" then
        local sc = child:get("scale") or 1
        local row = {
          id = child.id or tostring(#rows),
          shape = (ci.primitive ~= "gltf") and ci.primitive or nil,
          src = (ci.primitive == "gltf" and not (child.file or ""):match("%.msh$")) and child.file or nil,
          solid = (child.file or ""):match("%.msh$") and child.file or nil,
          pos = { child:get("x") or 0, child:get("y") or 0, child:get("z") or 0 },
          yaw = child:get("yaw") or 0, pitch = child:get("pitch") or 0, roll = child:get("roll") or 0,
          scale = sc, size = ci.size,
          color = rgba(child:get("color") or ci.color or { 0.85, 0.88, 0.92, 1 }, child:get("opacity") or 1),
          emissive = rgba(child:get("emissive") or ci.emissive),
        }
        for _, k in ipairs(MESH_PROPS) do
          local v = child:get(k)
          if v ~= nil then row[k] = v end
        end
        rows[#rows + 1] = row
      end
    end
  end
  if i.entities then
    local state = comp.game and comp.game.state or nil
    for _, r in ipairs(i.entities(t, state) or {}) do
      if r.light then lit = true end
      if type(r.color) == "string" then r.color = rgba(r.color) end
      if type(r.emissive) == "string" then r.emissive = rgba(r.emissive) end
      rows[#rows + 1] = r
    end
  end
  -- entities a rows system spawned this frame (core/moonsplice/rows.lua): Bevy's rows, by id
  for _, r in ipairs(node:get("spawn") or {}) do
    local e = {}
    for k, v in pairs(r) do e[k] = v end
    if e.light then lit = true end
    if type(e.color) == "string" then e.color = rgba(e.color) end
    if type(e.emissive) == "string" then e.emissive = rgba(e.emissive) end
    rows[#rows + 1] = e
  end
  if not lit then
    rows[#rows + 1] = { id = "_sun", light = "directional", dir = { -0.4, -1, -0.3 }, intensity = 3500, color = { 1, 1, 1, 1 } }
  end
  return doc
end

-- Draw `node` at t into its pixels (a love-shim ImageData). Errors say why.
function W.render(comp, node, t, data, w, h)
  local doc = W.encode(W.document(comp, node, t))
  local rc = lib.cs_world_render(tostring(node.id or node), doc, #doc, w, h,
    ffi.cast("uint8_t*", data:getFFIPointer()), data:getSize())
  if rc ~= 0 then error("moonsplice: " .. ffi.string(lib.cs_last_error()), 0) end
end

local _ = scene
return W
