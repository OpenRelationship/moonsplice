-- Timeline: recorded tween segments, evaluated purely at any t (seek, not playback).
-- Segment = {node, prop, t0, t1, from, to, ease}. Overlaps on (node, prop) are a
-- compile error — determinism by construction, same rule HF/Remotion enforce by lint.
local ease = require("moonsplice.ease")
local color = require("moonsplice.color")

local Timeline = {}
Timeline.__index = Timeline

function Timeline.new()
  return setmetatable({ groups = {}, order = {} }, Timeline)
end

-- key by node identity, not node.id — duplicate explicit ids must not collide
local function groupkey(node, prop) return tostring(node) .. "\0" .. prop end

function Timeline:record(node, prop, t0, t1, from, to, easename)
  local key = groupkey(node, prop)
  local g = self.groups[key]
  if not g then
    g = { node = node, prop = prop, segs = {} }
    self.groups[key] = g
    self.order[#self.order + 1] = g
  end
  for _, s in ipairs(g.segs) do
    if t0 < s.t1 and s.t0 < t1 then
      error(("moonsplice: overlapping tweens on %s.%s (%.3f-%.3f vs %.3f-%.3f)")
        :format(node.id, prop, s.t0, s.t1, t0, t1), 0)
    end
  end
  local efn = ease.get(easename or "linear")
  -- lint metadata: stable ease identity + overshoot detection (sampled, so
  -- custom fns and springs classify correctly without knowing their names)
  local eid = easename and ease.name_of(easename) or "linear"
  local overshoot = false
  for i = 1, 60 do
    if efn(i / 60) > 1.02 then overshoot = true break end
  end
  g.segs[#g.segs + 1] = { t0 = t0, t1 = t1, from = from, to = to, ease = efn,
    ease_id = eid, overshoot = overshoot,
    color_space = node.initial.color_space }
  table.sort(g.segs, function(a, b) return a.t0 < b.t0 end)
end

-- instantaneous switch of a structural prop (text/src/font) at time t.
-- Held until the next step; before the first step the node's initial applies.
function Timeline:record_step(node, prop, t0, value)
  local key = groupkey(node, prop)
  local g = self.groups[key]
  if not g then
    g = { node = node, prop = prop, segs = {} }
    self.groups[key] = g
    self.order[#self.order + 1] = g
  end
  g.segs[#g.segs + 1] = { kind = "step", t0 = t0, t1 = t0, to = value, from = value }
  table.sort(g.segs, function(a, b) return a.t0 < b.t0 end)
end

-- motion along a Catmull-Rom path, arc-length parameterized (constant speed
-- under linear ease). lut built once at compile; axis segments share it.
function Timeline:record_path(node, t0, t1, lut, easename)
  local e = ease.get(easename or "linear")
  local last = lut.pts[#lut.pts]
  for _, axis in ipairs({ "x", "y" }) do
    local key = groupkey(node, axis)
    local g = self.groups[key]
    if not g then
      g = { node = node, prop = axis, segs = {} }
      self.groups[key] = g
      self.order[#self.order + 1] = g
    end
    for _, s in ipairs(g.segs) do
      if t0 < s.t1 and s.t0 < t1 then
        error(("moonsplice: path overlaps tween on %s.%s"):format(node.id, axis), 0)
      end
    end
    g.segs[#g.segs + 1] = { kind = "path", t0 = t0, t1 = t1, lut = lut, axis = axis,
      ease = e, to = axis == "x" and last.x or last.y }
    table.sort(g.segs, function(a, b) return a.t0 < b.t0 end)
  end
end

-- Sampled bake (physics, etc.): evenly spaced values from t0 to t1.
function Timeline:record_bake(node, prop, t0, t1, samples)
  assert(type(samples) == "table" and #samples >= 2, "moonsplice: bake needs samples")
  local key = groupkey(node, prop)
  local g = self.groups[key]
  if not g then
    g = { node = node, prop = prop, segs = {} }
    self.groups[key] = g
    self.order[#self.order + 1] = g
  end
  for _, s in ipairs(g.segs) do
    if t0 < s.t1 and s.t0 < t1 then
      error(("moonsplice: bake overlaps tween on %s.%s"):format(node.id, prop), 0)
    end
  end
  g.segs[#g.segs + 1] = { kind = "bake", t0 = t0, t1 = t1, samples = samples,
    from = samples[1], to = samples[#samples] }
  table.sort(g.segs, function(a, b) return a.t0 < b.t0 end)
end

-- procedural organic drift: value = base + smoothnoise(t·freq)·amp, returns to base
function Timeline:record_wiggle(node, prop, t0, t1, base, amp, freq, seed, ramp)
  local key = groupkey(node, prop)
  local g = self.groups[key]
  if not g then
    g = { node = node, prop = prop, segs = {} }
    self.groups[key] = g
    self.order[#self.order + 1] = g
  end
  for _, s in ipairs(g.segs) do
    if t0 < s.t1 and s.t0 < t1 then
      error(("moonsplice: wiggle overlaps tween on %s.%s"):format(node.id, prop), 0)
    end
  end
  g.segs[#g.segs + 1] = { kind = "wiggle", t0 = t0, t1 = t1, from = base, to = base,
    amp = amp, freq = freq, seed = seed, ramp = ramp }
  table.sort(g.segs, function(a, b) return a.t0 < b.t0 end)
end

-- deterministic 1D smooth value noise, pure Lua (no host deps)
local floor, sin = math.floor, math.sin
local function nhash(i)
  local s = sin(i * 127.1 + 311.7) * 43758.5453
  return (s - floor(s)) * 2 - 1
end
local function noise1d(x)
  local i = floor(x)
  local f = x - i
  local u = f * f * (3 - 2 * f)
  local a, b = nhash(i), nhash(i + 1)
  return a + (b - a) * u
end

local function segvalue(seg, t)
  if seg.kind == "step" then return seg.to end
  if seg.kind == "bake" then
    local dur = seg.t1 - seg.t0
    local k = dur > 0 and (t - seg.t0) / dur or 1
    if k <= 0 then return seg.samples[1] end
    if k >= 1 then return seg.samples[#seg.samples] end
    local n = #seg.samples
    local idx = k * (n - 1)
    local lo = math.floor(idx) + 1
    local hi = math.min(n, lo + 1)
    local f = idx - (lo - 1)
    return seg.samples[lo] + (seg.samples[hi] - seg.samples[lo]) * f
  end
  if seg.kind == "wiggle" then
    local rel = t - seg.t0
    local dur = seg.t1 - seg.t0
    -- attack/release envelope so the wiggle enters and settles without pops
    local ramp = math.min(seg.ramp, dur / 2)
    local env = math.min(1, rel / ramp, (dur - rel) / ramp)
    return seg.from + noise1d(rel * seg.freq + seg.seed * 57.13) * seg.amp * env
  end
  if seg.kind == "path" then
    local k = seg.ease((t - seg.t0) / (seg.t1 - seg.t0))
    local target = k * seg.lut.total
    local pts = seg.lut.pts
    local lo, hi = 1, #pts
    while hi - lo > 1 do -- binary search cumulative arc length
      local mid = math.floor((lo + hi) / 2)
      if pts[mid].len <= target then lo = mid else hi = mid end
    end
    local a, b = pts[lo], pts[hi]
    local span = b.len - a.len
    local f = span > 0 and (target - a.len) / span or 0
    if seg.axis == "x" then return a.x + (b.x - a.x) * f end
    return a.y + (b.y - a.y) * f
  end
  if seg.t1 <= seg.t0 then return seg.to end -- zero-duration set: step
  local k = seg.ease((t - seg.t0) / (seg.t1 - seg.t0))
  if color.is_color(seg.to) then return color.lerp(seg.from, seg.to, k, seg.color_space) end
  return seg.from + (seg.to - seg.from) * k
end

-- One group's value at t: what `evaluate` would write for it (nil before its first segment).
local function group_value(g, t)
  local v = nil
  for _, seg in ipairs(g.segs) do
    if t >= seg.t1 then
      v = seg.to
    elseif t >= seg.t0 then
      return segvalue(seg, t)
    else
      break
    end
  end
  return v
end

function Timeline:group(node, prop) return self.groups[groupkey(node, prop)] end

-- (node, prop) at t, falling back to the node's rest value: for a clip's speed and time, which are
-- read at times other than the frame's (core/moonsplice/clip.lua)
function Timeline:value(node, prop, t)
  local g = self.groups[groupkey(node, prop)]
  local v = g and group_value(g, t)
  if v == nil then v = node.initial[prop] end
  return v
end

-- The integral of (node, prop) over a..b: a clip's local time under a keyed speed. Simpson's rule
-- on each piece between segment boundaries, sixteen panels a piece, so it depends on a and b alone
-- and a frame gets the same local time whichever frames came before it.
function Timeline:integral(node, prop, a, b, rest)
  if b <= a then return 0 end
  local g = self.groups[groupkey(node, prop)]
  local cuts = { a, b }
  for _, seg in ipairs(g and g.segs or {}) do
    if seg.t0 > a and seg.t0 < b then cuts[#cuts + 1] = seg.t0 end
    if seg.t1 > a and seg.t1 < b then cuts[#cuts + 1] = seg.t1 end
  end
  table.sort(cuts)
  local function f(x)
    local v = g and group_value(g, x)
    if v == nil then v = node.initial[prop] end
    if v == nil then v = rest end
    return v
  end
  local sum, N = 0, 16
  for k = 2, #cuts do
    local x0, x1 = cuts[k - 1], cuts[k]
    if x1 > x0 then
      -- the piece's ends are segment boundaries, where a step jumps: sample just inside them
      local h = (x1 - x0) / N
      local acc = f(x0 + 1e-9) + f(x1 - 1e-9)
      for j = 1, N - 1 do acc = acc + f(x0 + j * h) * (j % 2 == 1 and 4 or 2) end
      sum = sum + acc * h / 3
    end
  end
  return sum
end

-- Pure evaluation: writes computed values into each node's state overlay. A node under a clip
-- is evaluated at that clip's local time (core/moonsplice/clip.lua sets clock._lt first).
function Timeline:evaluate(t)
  for _, g in ipairs(self.order) do
    local clock = g.node.clock
    local t = clock and clock._lt or t
    local v = nil
    for _, seg in ipairs(g.segs) do
      if t >= seg.t1 then
        v = seg.to
      elseif t >= seg.t0 then
        v = segvalue(seg, t)
        break
      else
        break
      end
    end
    g.node.state[g.prop] = v -- nil before first segment -> falls back to initial
  end
end

return Timeline
