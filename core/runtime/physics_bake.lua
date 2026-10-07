-- Compile-phase physics bake (rapier2d, in moonsplice-engine). Simulation runs once at a fixed dt; sampled
-- x/y/rotation become ordinary timeline segments. Render stays pure f(t).
local B = {}

local function node_size(node)
  local i = node.initial
  local w = i.w
  local h = i.h
  if (not w or not h) and node.kind == "text" then
    local painter = require("painter")
    local font = painter.font(i.size or 32, i.font)
    w = font:getWidth(i.text or "")
    h = font:getHeight()
  end
  if (not w or not h) and i.r then
    w, h = i.r * 2, i.r * 2
  end
  return w or 40, h or 40
end

local function center_of(node)
  local x, y = node.initial.x or 0, node.initial.y or 0
  local w, h = node_size(node)
  if node.initial.anchor == "center" or node.kind == "circle" then
    return x, y, w, h
  end
  return x + w / 2, y + h / 2, w, h
end

local function write_sim(rec, node, prop, value)
  rec.sim[node] = rec.sim[node] or {}
  rec.sim[node][prop] = value
  node.initial["_" .. prop .. "_rest"] = value
end

function B.bake(comp, rec)
  local drops = comp.timeline.drops
  if not drops or #drops == 0 then return end
  local E = MOONSPLICE_ENGINE
  if not (E and E.physics_drop) then error("moonsplice: t:drop needs moonsplice-engine (rapier2d)", 0) end

  for _, job in ipairs(drops) do
    local opts = job.opts or {}
    local t0, t1 = job.t0, job.t1
    local dur = t1 - t0
    local fps = opts.sample_fps or 60
    local spec = {
      comp_w = comp.width, comp_h = comp.height, duration = dur,
      samples = math.max(2, math.floor(dur * fps) + 1),
      gravity = opts.gravity or 980, -- pixels/s²
      ground_y = opts.ground_y or (comp.height - 48), ground_w = opts.ground_w or comp.width,
      walls = opts.walls ~= false, friction = opts.friction or 0.45, ground_friction = opts.friction or 0.55,
      density = opts.density or 1, restitution = opts.restitution or 0.18, spin = opts.spin or 0,
      bodies = {},
    }
    local sizes = {}
    for k, node in ipairs(job.nodes) do
      local cx, cy, w, h = center_of(node)
      spec.bodies[k] = { cx = cx, cy = cy, w = w, h = h }
      sizes[k] = { w, h }
    end
    local out = E.physics_drop(spec)
    for k, node in ipairs(job.nodes) do
      local o = out[k]
      local xs, ys = o.x, o.y
      -- the simulation moves centres; a node anchored at its corner is placed by its corner
      if not (node.initial.anchor == "center" or node.kind == "circle") then
        local w, h = sizes[k][1], sizes[k][2]
        local cx, cy = {}, {}
        for s = 1, #xs do cx[s], cy[s] = xs[s] - w / 2, ys[s] - h / 2 end
        xs, ys = cx, cy
      end
      comp.timeline:record_bake(node, "x", t0, t1, xs)
      comp.timeline:record_bake(node, "y", t0, t1, ys)
      comp.timeline:record_bake(node, "rotation", t0, t1, o.r)
      write_sim(rec, node, "x", xs[#xs])
      write_sim(rec, node, "y", ys[#ys])
      write_sim(rec, node, "rotation", o.r[#o.r])
    end
  end
end

return B
