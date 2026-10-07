-- Part of moonsplice (core/moonsplice/init.lua): see its head for the module's contract.
local M = require("moonsplice")
local ANIMATABLE, Rec, record = M._.ANIMATABLE, M._.Rec, M._.record
local resolve_from, SETTABLE = M._.resolve_from, M._.SETTABLE

function Rec:wait(d)
  assert(type(d) == "number" and d >= 0, "moonsplice: wait(seconds >= 0)")
  self.cursor = self.cursor + d
end

-- Relational cursor jump: jumps or waits until a target event occurs.
-- `target` can be:
--   - number: absolute timestamp in seconds
--   - Node: jumps to node.initial.at or node completion
--   - table/event: e.g. node:word("key"), { node = n, event = "beat", nth = 1 }, or conceptual cut
function Rec:at(target)
  local t
  if type(target) == "number" then
    t = target
  elseif type(target) == "table" and target.kind and target.initial then
    t = target.initial.at or 0
  elseif type(target) == "table" and target.t0 ~= nil then
    t = target.t0
  elseif type(target) == "table" and target.at ~= nil then
    t = target.at
  else
    error("moonsplice: at() expects number timestamp, node, or relational event table", 2)
  end
  assert(t >= 0, "moonsplice: cannot jump to negative time")
  self.cursor = t
end

function Rec:tween(node, dur, props, easename)
  assert(type(dur) == "number" and dur > 0, "moonsplice: tween duration must be > 0")
  record(self, node, dur, props, easename)
end

function Rec:set(node, props)
  local anim, struct = {}, nil
  for k, v in pairs(props) do
    if SETTABLE[k] and not ANIMATABLE[k] then
      struct = struct or {}
      struct[k] = v
    else
      anim[k] = v
    end
  end
  if struct then
    for prop, val in pairs(struct) do
      self.timeline:record_step(node, prop, self.cursor, val)
    end
  end
  if next(anim) then record(self, node, 0, anim, "linear") end
end

-- Organic drift on one prop: value = base + noise(t·freq)·amp. Does NOT advance
-- the cursor (runs alongside whatever follows). seed defaults per-node so
-- staggered wiggles don't move in lockstep.
function Rec:wiggle(node, prop, opts)
  assert(ANIMATABLE[prop], "moonsplice: wiggle prop not animatable: " .. tostring(prop))
  local duration = assert(opts.duration, "moonsplice: wiggle{duration=} required")
  local base = resolve_from(self, node, prop)
  self.timeline:record_wiggle(node, prop, self.cursor, self.cursor + duration,
    base, opts.amp or 10, opts.freq or 1.5, opts.seed or (#node.id * 7.31), opts.ramp or 0.25)
end

-- Motion along a smooth path through waypoints (Catmull-Rom, constant-speed).
-- Starts from the node's current position; updates sim so later tweens chain.
function Rec:path(node, dur, points, easename)
  assert(type(points) == "table" and #points >= 1, "moonsplice: path needs waypoints {{x,y},...}")
  local sx = resolve_from(self, node, "x")
  local sy = resolve_from(self, node, "y")
  local P = { { sx, sy } }
  for _, p in ipairs(points) do P[#P + 1] = { p[1] or p.x, p[2] or p.y } end
  -- Catmull-Rom sampling, 24 samples/segment, cumulative arc length
  local pts, total = { { x = sx, y = sy, len = 0 } }, 0
  local function cr(p0, p1, p2, p3, u)
    local u2, u3 = u * u, u * u * u
    return 0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2
      + (-p0 + 3 * p1 - 3 * p2 + p3) * u3)
  end
  for i = 1, #P - 1 do
    local p0 = P[math.max(i - 1, 1)]
    local p1, p2 = P[i], P[i + 1]
    local p3 = P[math.min(i + 2, #P)]
    for s = 1, 24 do
      local u = s / 24
      local x = cr(p0[1], p1[1], p2[1], p3[1], u)
      local y = cr(p0[2], p1[2], p2[2], p3[2], u)
      local prev = pts[#pts]
      total = total + math.sqrt((x - prev.x) ^ 2 + (y - prev.y) ^ 2)
      pts[#pts + 1] = { x = x, y = y, len = total }
    end
  end
  self.timeline:record_path(node, self.cursor, self.cursor + dur,
    { pts = pts, total = total, waypoints = points, ease_name = easename }, easename)
  self.sim[node] = self.sim[node] or {}
  self.sim[node].x = P[#P][1]
  self.sim[node].y = P[#P][2]
  self.cursor = self.cursor + dur
end

-- GSAP-style stagger: same tween across many nodes, each offset by `each`.
-- from = "start" (default) | "end" | "center" changes the launch order.
function Rec:stagger(nodes, dur, props, opts)
  opts = opts or {}
  local each = opts.each or 0.06
  local n = #nodes
  local t0 = self.cursor
  self.timeline.staggers = self.timeline.staggers or {}
  self.timeline.staggers[#self.timeline.staggers + 1] =
    { t0 = t0, n = n, each = each, span = each * math.max(0, n - 1) }
  local t_end = t0
  for idx, node in ipairs(nodes) do
    local k = idx - 1
    if opts.from == "end" then
      k = n - idx
    elseif opts.from == "center" then
      k = math.abs(idx - (n + 1) / 2)
    end
    self.cursor = t0 + k * each
    local p = type(props) == "function" and props(node, idx) or props
    record(self, node, dur, p, opts.ease)
    if self.cursor > t_end then t_end = self.cursor end
  end
  self.cursor = t_end
end

function Rec:parallel(...)
  local fns = { ... }
  local t0 = self.cursor
  local t_end = t0
  for _, fn in ipairs(fns) do
    self.cursor = t0
    fn()
    if self.cursor > t_end then t_end = self.cursor end
  end
  self.cursor = t_end
end

-- Compile-phase Box2D: colliding bodies sampled onto x/y/rotation. Render is
-- ordinary nodes. Host fills the bake in post_script (needs love.physics).
function Rec:drop(nodes, opts)
  assert(type(nodes) == "table" and #nodes > 0, "moonsplice: drop needs a node list")
  opts = opts or {}
  local t0 = self.cursor
  local dur = opts.duration or 1.4
  self.timeline.drops = self.timeline.drops or {}
  self.timeline.drops[#self.timeline.drops + 1] = {
    nodes = nodes, t0 = t0, t1 = t0 + dur, opts = opts,
  }
  self.cursor = t0 + dur
end

-- Audio-reactive: bake a 0..1 curve onto a prop. source is an audio node with
-- follow=true (resolve fills initial.energy) or a raw samples table.
-- Does NOT advance the cursor (runs alongside). duration defaults to source clip.
function Rec:follow(node, prop, source, opts)
  assert(ANIMATABLE[prop], "moonsplice: follow prop not animatable: " .. tostring(prop))
  opts = opts or {}
  local samples
  if type(source) == "table" and source.kind then
    samples = source.initial.energy or source.energy
    assert(samples and #samples >= 2,
      "moonsplice: follow needs audio{ follow=true } (energy baked at resolve)")
  else
    samples = source
  end
  assert(type(samples) == "table" and #samples >= 2, "moonsplice: follow needs samples")
  local gain = opts.gain or 1
  local base = opts.base
  if base == nil then base = resolve_from(self, node, prop) end
  local scaled = {}
  for i, v in ipairs(samples) do scaled[i] = base + v * gain end
  local t0 = self.cursor
  local dur = opts.duration
  if not dur then
    if type(source) == "table" and source.kind then
      dur = source.initial.duration or (#samples / 50)
    else
      dur = #samples / 50
    end
  end
  self.timeline:record_bake(node, prop, t0, t0 + dur, scaled)
  self.sim[node] = self.sim[node] or {}
  self.sim[node][prop] = scaled[#scaled]
end

