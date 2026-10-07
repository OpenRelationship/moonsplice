-- Composition (.robot/docs/rows.robot, "Composition"): clips are groups with their own time, tracks lay
-- clips end to end, transitions use the overlap between neighbours. Host-free like the rest of core/moonsplice.
-- This module is the clock: each clip's mapping from its parent's time to its local time, and that mapping
-- read backwards. Tracks and transitions are core/moonsplice/track.lua.
--
-- A clip's own props (x, y, opacity, speed, time) are keyed in its parent's time; everything under
-- it sees the clip's LOCAL time: keys, motion, the systems that name it, media. The mapping from
-- comp time to local time is worked out every frame from the parent's time, never baked into key
-- times at compile, so a speed ramp inside a nested clip composes with the clip around it and any
-- frame still seeks exactly. Key times stay local in the rows.
--
--   clip.setup(comp)             once, after compile: clocks, track layout, transitions, checks
--   clip.frame(comp, t)          every evaluate, before the timeline: each clip's local time and state
--   clip.comp_time(comp, c, lt)  the first comp time at which clip c's local time is lt (or nil)
--   clip.range(comp, c)          the local times clip c ever shows: lo, hi
--   clip.describe(comp, c)       one line for the brief: when c plays, as what, and how
local C = {}

-- nodes that are clocks: what is under them is in their local time
C.CLOCKS = { clip = true, precomp = true }
-- nodes that composite as one layer unless they say isolate = false
C.CONTAINERS = { clip = true, precomp = true, track = true }
C.HOLDS = { start = true, ["end"] = true }

-- the last frame of a clip, for hold = "end" and reverse: a frame inside the range, so a video
-- that fills the clip exactly still has a picture there
local EPS = 1e-6
C.EPS = EPS

-- Whether a node composites as one layer: clips, precomps and tracks do unless they say
-- isolate = false; a group only when it says isolate = true (so no existing comp changes).
function C.isolated(n)
  local iso = n.initial.isolate
  if iso ~= nil then return iso and true or false end
  return C.CONTAINERS[n.kind] or false
end

local function where(n) return ("moonsplice: %s %s"):format(n.kind, tostring(n.id)) end
C.where = where

function C.check_props(n)
  local i = n.initial
  local function num(k, ok, need)
    local v = i[k]
    if v ~= nil and (type(v) ~= "number" or not ok(v)) then
      error(("%s: %s needs %s, not %s"):format(where(n), k, need, tostring(v)), 0)
    end
  end
  num("start", function() return true end, "seconds (a number or a fact reference)")
  num("duration", function(v) return v > 0 end, "a number of seconds > 0")
  num("offset", function() return true end, "a number of seconds")
  num("speed", function(v) return v >= 0 end, "a number >= 0 (reverse = true plays it backwards)")
  num("length", function(v) return v > 0 end, "a number of seconds > 0")
  num("gap", function(v) return v >= 0 end, "a number of seconds >= 0")
  num("overlap", function(v) return v >= 0 end, "a number of seconds >= 0")
  for _, k in ipairs({ "loop", "reverse", "isolate" }) do
    if i[k] ~= nil and type(i[k]) ~= "boolean" then
      error(("%s: %s needs true or false, not %s"):format(where(n), k, tostring(i[k])), 0)
    end
  end
  if i.hold ~= nil and type(i.hold) ~= "boolean" and not C.HOLDS[i.hold] then
    error(("%s: hold needs true, false, \"start\" or \"end\", not %s"):format(where(n), tostring(i.hold)), 0)
  end
  if i.loop and not i.length then
    error(("%s: loop needs length (the local seconds that repeat)"):format(where(n)), 0)
  end
end

-- ---------- the mapping ----------

-- local time at e seconds into the clip (before hold, reverse and loop)
local function raw(comp, c, e)
  local i = c.initial
  if c._time_keyed then
    local v = comp.timeline:value(c, "time", c._start + e)
    return v or i.time or 0
  end
  if c._speed_keyed then
    return (i.offset or 0) + comp.timeline:integral(c, "speed", c._start, c._start + e, i.speed or 1)
  end
  return (i.offset or 0) + e * (i.speed or 1)
end

-- local time at e seconds into the clip, after reverse and loop
local function map(comp, c, e)
  local i = c.initial
  if i.reverse then e = math.max(0, c._dur - e - EPS) end
  local lt = raw(comp, c, e)
  if i.loop then lt = lt % c._length end
  return lt
end
C.map = map

-- every clip's local time and whether it shows, parents before children; then the transitions
function C.frame(comp, t)
  local clips = comp._clips
  if not clips then return end
  for _, c in ipairs(clips) do
    local pc = c.clock
    local pt = pc and pc._lt or t
    local i = c.initial
    local e = pt - c._start
    local on = true
    if e < 0 then
      if i.hold == true or i.hold == "start" then e = 0 else on = false end
    elseif c._dur and e >= c._dur then
      if i.hold == true or i.hold == "end" then e = c._dur - EPS else on = false end
    end
    if e < 0 then e = 0 end
    if c._dur and e > c._dur then e = c._dur end
    c._lt, c._on = map(comp, c, e), on
    c._live = on and (not pc or pc._live)
    c._tr = nil
  end
  require("moonsplice.track").frame(comp, t)
end

-- ---------- setup, once after compile ----------

-- how long a clip runs in its parent's time, or nil (it runs on)
function C.duration(comp, c)
  local i = c.initial
  if i.duration then return i.duration end
  -- a precomp plays its comp once, at its speed, unless it loops (then it runs on)
  if c.kind == "precomp" and not i.loop then
    if c._time_keyed or c._speed_keyed or (i.speed or 1) <= 0 then return i.length end
    return i.length / (i.speed or 1)
  end
  return nil
end

function C.setup(comp)
  local clips, tracks, any = {}, {}, false
  for _, n in ipairs(comp.nodes) do
    local p = n.initial.parent
    while p and not C.CLOCKS[p.kind] do p = p.initial.parent end
    -- a kinetic's characters hang off no parent; they keep their word's time
    if not p and n._group then
      p = n._group.initial.parent
      while p and not C.CLOCKS[p.kind] do p = p.initial.parent end
    end
    n.clock = p
    if C.CLOCKS[n.kind] then clips[#clips + 1] = n; any = true end
    if n.kind == "track" then tracks[#tracks + 1] = n; any = true end
  end
  if not any then return end
  if comp.game then
    error("moonsplice: clips, tracks and precomps are for videos: a game's time is its simulation, "
      .. "stepped from 0 with its input, and cannot run at another speed or start", 0)
  end
  for _, c in ipairs(clips) do
    C.check_props(c)
    c._time_keyed = comp.timeline:group(c, "time") ~= nil
    c._speed_keyed = comp.timeline:group(c, "speed") ~= nil
    c._start = c.initial.start or 0
    c._length = c.initial.length
  end
  -- tracks place their clips (each starts where the one before ends) and wire the transitions
  local incoming = require("moonsplice.track").layout(comp, tracks)
  for _, c in ipairs(clips) do
    local i = c.initial
    c._dur = C.duration(comp, c)
    if i.reverse and not c._dur then
      error(("%s: reverse needs a duration (it plays the clip from its end)"):format(where(c)), 0)
    end
    if i.transition ~= nil and not (i.parent and i.parent.kind == "track") then
      error(("%s: a transition belongs to a clip in a track (it uses the overlap with the clip before)"):format(where(c)), 0)
    end
  end
  comp._clips, comp._tracks, comp._incoming = clips, tracks, incoming
  C.place_audio(comp)
end

-- Sound is mixed by ffmpeg at encode, so a clip's mapping cannot reach it frame by frame. A sound
-- under clips at speed 1 is placed in comp time once here, trimmed to the clip; any other mapping is
-- refused with the reason, rather than mixed at the wrong moment.
local AUDIO = { audio = true, tts = true, sfx = true, music = true }
function C.place_audio(comp)
  for _, n in ipairs(comp.nodes) do
    if AUDIO[n.kind] and n.clock then
      local i = n.initial
      local c = n.clock
      while c do
        local ci = c.initial
        if c._time_keyed or c._speed_keyed or ci.reverse or ci.loop or (ci.speed or 1) ~= 1 then
          error(("moonsplice: %s %s is inside clip %s, which plays at another speed (or reversed, looped or "
            .. "remapped); sound is mixed at encode and can follow only a clip at speed 1. Put it outside the "
            .. "clip, at comp time"):format(n.kind, tostring(n.id), tostring(c.id)), 0)
        end
        local off = ci.offset or 0
        if i.at < off then
          local cut = off - i.at
          i.media_start = (i.media_start or 0) + cut
          i.duration = i.duration and (i.duration - cut)
          i.at = off
        end
        if c._dur and i.duration then i.duration = math.min(i.duration, off + c._dur - i.at) end
        if i.duration and i.duration <= 0 then
          error(("moonsplice: %s %s falls outside its clip %s entirely"):format(n.kind, tostring(n.id), tostring(c.id)), 0)
        end
        i.at = c._start + (i.at - off)
        c = c.clock
      end
    end
  end
end

-- ---------- reading the mapping (lint, the brief, expectations) ----------

-- the clip's own mapping is a straight line: no time keys, no speed keys, no reverse
local function linear(c)
  return not c._time_keyed and not c._speed_keyed and not c.initial.reverse
end

-- The seconds into a remapped clip worth looking at: an even grid, and every moment its time or
-- speed curve turns (a remap's peak is a key, and a grid would step over it)
local function probes(comp, c)
  local d = c._dur or 60
  local es, n = {}, 800
  for k = 0, n do es[#es + 1] = d * k / n end
  for _, prop in ipairs({ "time", "speed" }) do
    local g = comp.timeline:group(c, prop)
    for _, seg in ipairs(g and g.segs or {}) do
      for _, x in ipairs({ seg.t0 - c._start, seg.t1 - c._start }) do
        if x > 0 and x < d then
          -- reversed, the clip reaches a parent moment at the mirrored offset
          es[#es + 1] = c.initial.reverse and math.max(0, d - x - EPS) or x
        end
      end
    end
  end
  table.sort(es)
  return es
end

-- The local times clip c ever shows, lo..hi (hi may be math.huge).
function C.range(comp, c)
  local i = c.initial
  if i.loop then return 0, c._length end
  if linear(c) then
    local o, sp = i.offset or 0, i.speed or 1
    if not c._dur then return o, math.huge end
    return o, o + c._dur * sp
  end
  local lo, hi = math.huge, -math.huge
  for _, e in ipairs(probes(comp, c)) do
    local v = map(comp, c, e)
    if v < lo then lo = v end
    if v > hi then hi = v end
  end
  -- the last instant of a reversed clip is EPS short of its end; it shows that moment
  if i.reverse and math.abs(hi - (i.offset or 0) - c._dur * (i.speed or 1)) < 1e-4 then
    hi = (i.offset or 0) + c._dur * (i.speed or 1)
  end
  return lo, hi
end

-- The first parent time at which clip c shows local time lt, or nil.
local function parent_time(comp, c, lt)
  local i = c.initial
  -- a looping clip shows every local time inside its length, and only those
  if i.loop then lt = lt % c._length end
  if linear(c) then
    local o, sp = i.offset or 0, i.speed or 1
    if i.loop then
      if lt < o % c._length then lt = lt + c._length end
      o = o % c._length
    end
    if sp <= 0 then return lt == o and c._start or nil end
    local e = (lt - o) / sp
    if e < -1e-9 or (c._dur and e > c._dur + 1e-9) then return nil end
    return c._start + math.max(0, e)
  end
  -- remapped: a probe that lands on lt (within the end's EPS), or the first pair that brackets it,
  -- then bisection
  local es = probes(comp, c)
  local prev
  for k, e in ipairs(es) do
    local v = map(comp, c, e)
    if math.abs(v - lt) < 1e-5 then return c._start + e end
    -- a loop's wrap is a jump, not a crossing
    if prev and (prev - lt) * (v - lt) < 0 and math.abs(v - prev) < 0.5 * math.max(1e-9, c._length or math.huge) then
      local a, b = es[k - 1], e
      for _ = 1, 50 do
        local m = (a + b) / 2
        if (map(comp, c, a) - lt) * (map(comp, c, m) - lt) <= 0 then b = m else a = m end
      end
      return c._start + (a + b) / 2
    end
    prev = v
  end
  return nil
end

-- The first comp time at which clip c (and every clip around it) shows local time lt, or nil.
function C.comp_time(comp, c, lt)
  while c do
    lt = parent_time(comp, c, lt)
    if not lt then return nil end
    c = c.clock
  end
  return lt
end

-- the comp time of a key time on node n (its clock's local time), or the time itself
function C.to_comp(comp, n, t)
  if not n or not n.clock then return t end
  return C.comp_time(comp, n.clock, t)
end

-- One line for `rows --brief`: the comp times clip c plays, the local times it shows, how it maps
-- them, the transition into it, and for a precomp what it holds.
function C.describe(comp, c)
  local function secs(t) return t == math.huge and "end" or ("%.2fs"):format(t) end
  local i = c.initial
  local a = C.to_comp(comp, c, c._start)
  local b = c._dur and C.to_comp(comp, c, c._start + c._dur)
  local lo, hi = C.range(comp, c)
  local how = {}
  if c._time_keyed then how[#how + 1] = "time remapped"
  elseif c._speed_keyed then how[#how + 1] = "speed keyed"
  elseif (i.speed or 1) ~= 1 then how[#how + 1] = ("speed %g"):format(i.speed) end
  if i.reverse then how[#how + 1] = "reversed" end
  if i.loop then how[#how + 1] = ("loops every %gs"):format(c._length) end
  if i.hold then how[#how + 1] = "holds " .. (i.hold == true and "both ends" or ("its " .. i.hold)) end
  local line = ("plays comp %s..%s as local %s..%s%s"):format(a and secs(a) or "?", b and secs(b) or (c._dur and "?" or "end"),
    secs(lo), secs(hi), #how > 0 and ("; " .. table.concat(how, ", ")) or "")
  if c._in then
    line = line .. ("; %s %.2fs from %s"):format(c._in.kind, c._in.duration, c._in.prev.id)
  elseif (c._overlap or 0) > 0 then
    line = line .. ("; overlaps the clip before by %.2fs, no transition"):format(c._overlap)
  end
  if c.kind == "precomp" then
    local inside = 0
    for _, n in ipairs(comp.nodes) do if n.id and n.id:sub(1, #c.id + 1) == c.id .. "/" then inside = inside + 1 end end
    line = line .. ("; %s (%dx%d, %gs): %d nodes inside as %s/<id>, keyable from here in its local time"):format(
      tostring(c.precomp_path or i.src):match("([^/]+)$"), i.w or 0, i.h or 0, i.length or 0, inside, c.id)
  end
  return line
end

return C
