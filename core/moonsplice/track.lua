-- Tracks and transitions (.robot/docs/rows.robot, "Composition"): a track lays its clips end to end, each
-- starting where the one before ends less the overlap its transition needs, so trimming or reordering one
-- ripples the rest; a transition uses that overlap. The clocks themselves are core/moonsplice/clip.lua,
-- which calls in here.
--
--   track.layout(comp, tracks) -> incoming   once, from clip.setup: each member's start; the clips a
--                                            transition leads into
--   track.frame(comp, t)                     every evaluate, after the clocks: what each transition
--                                            does to the two clips it joins (their _tr)
--   track.transition(spec, who)              a transition as written, checked, with its defaults
local ease = require("moonsplice.ease")
local color = require("moonsplice.color")
local Clip = require("moonsplice.clip")

local T = {}

-- transition kinds and the ease each defaults to: a dissolve is linear in every NLE; a move eases
T.TRANSITIONS = { crossfade = "linear", dip = "linear", wipe = "cubicInOut", push = "cubicInOut",
  slide = "cubicInOut", zoom = "cubicInOut" }
-- the way a push or slide moves, or a wipe's edge travels
T.DIRS = { left = { -1, 0 }, right = { 1, 0 }, up = { 0, -1 }, down = { 0, 1 } }

local where = Clip.where

-- a transition, as written ({ kind, duration, ease, color, dir }), checked and with its defaults
function T.transition(spec, who)
  if type(spec) ~= "table" then
    error(("%s: transition needs { kind, duration }, not %s"):format(who, tostring(spec)), 0)
  end
  if not T.TRANSITIONS[spec.kind] then
    error(("%s: transition kind %s is not one of crossfade, dip, wipe, push, slide, zoom"):format(who,
      tostring(spec.kind)), 0)
  end
  if type(spec.duration) ~= "number" or spec.duration <= 0 then
    error(("%s: transition duration needs a number of seconds > 0"):format(who), 0)
  end
  local dir = spec.dir or (spec.kind == "wipe" and "right" or "left")
  if not T.DIRS[dir] then error(("%s: transition dir %s is not left, right, up or down"):format(who, tostring(dir)), 0) end
  local ok, fn = pcall(ease.get, spec.ease or T.TRANSITIONS[spec.kind])
  if not ok then error(("%s: transition ease %s: %s"):format(who, tostring(spec.ease), tostring(fn)), 0) end
  return { kind = spec.kind, duration = spec.duration, ease = fn, dir = dir,
    color = color.parse(spec.color or "#000000") }
end

-- ---------- every frame ----------

local function tr(c)
  local x = c._tr
  if not x then
    local track = c.initial.parent
    local w, h = track and track.initial.w or 0, track and track.initial.h or 0
    x = { op = 1, dx = 0, dy = 0, s = 1, cx = w / 2, cy = h / 2, w = w, h = h }
    c._tr = x
  end
  return x
end

-- what a transition at progress p does to the clip coming in (b) and the one going out (a)
function T.apply(b, a, spec, p)
  local A, B = tr(a), tr(b)
  local W, H = B.w, B.h
  local d = T.DIRS[spec.dir]
  -- a dissolve is exact only inside one layer: the outgoing clip at 1-p over nothing, the incoming
  -- added at p, then the sum over the backdrop. Outside a layer the incoming simply covers.
  local layered = Clip.isolated(b.initial.parent)
  local k = spec.kind
  if k == "crossfade" or k == "zoom" then
    B.op = B.op * p
    if layered then A.op, B.plus = A.op * (1 - p), true end
    if k == "zoom" then A.s, B.s = 1 + 0.25 * p, 0.8 + 0.2 * p end
  elseif k == "dip" then
    local c = spec.color
    if p < 0.5 then
      A.dip = { c[1], c[2], c[3], (c[4] or 1) * 2 * p }
      B.op = 0
    else
      B.dip = { c[1], c[2], c[3], (c[4] or 1) * 2 * (1 - p) }
      A.op = 0
    end
  elseif k == "wipe" then
    -- the edge travels in dir: right reveals from the left side, down from the top
    if d[1] > 0 then B.wipe = { 0, 0, W * p, H }
    elseif d[1] < 0 then B.wipe = { W * (1 - p), 0, W * p, H }
    elseif d[2] > 0 then B.wipe = { 0, 0, W, H * p }
    else B.wipe = { 0, H * (1 - p), W, H * p } end
  elseif k == "push" or k == "slide" then
    -- both move in dir (push), or the incoming slides over a still outgoing (slide)
    if k == "push" then A.dx, A.dy = d[1] * W * p, d[2] * H * p end
    B.dx, B.dy = d[1] * W * (p - 1), d[2] * H * (p - 1)
  end
end

function T.frame(comp, t)
  for _, c in ipairs(comp._incoming or {}) do
    local tin = c._in
    local pc = c.clock
    local pt = pc and pc._lt or t
    local u = (pt - c._start) / tin.duration
    if u >= 0 and u < 1 and (not pc or pc._live) then
      T.apply(c, tin.prev, tin, tin.ease(u))
    end
  end
end

-- ---------- layout, once after compile ----------

function T.layout(comp, tracks)
  for _, tk in ipairs(tracks) do
    Clip.check_props(tk)
    local i = tk.initial
    i.w, i.h = i.w or comp.width, i.h or comp.height
  end
  -- each clip starts where the one before it ends, less the overlap its transition needs
  local incoming = {}
  for _, tk in ipairs(tracks) do
    local members = {}
    for _, n in ipairs(comp.nodes) do
      if n.initial.parent == tk then
        if not Clip.CLOCKS[n.kind] then
          error(("%s: a track holds clips; %s is a %s (put it in a clip)"):format(where(tk), tostring(n.id), n.kind), 0)
        end
        members[#members + 1] = n
      end
    end
    local cursor = tk.initial.start or 0
    local prev
    for k, c in ipairs(members) do
      local i = c.initial
      if i.start ~= nil then
        error(("%s is in track %s, which places it: drop start (gap leaves space before it, the track's order "
          .. "sets the sequence)"):format(where(c), tostring(tk.id)), 0)
      end
      local spec = i.transition
      if spec == nil and k > 1 then spec = tk.initial.transition end
      if spec == false then spec = nil end
      if spec and k == 1 then
        if i.transition then
          error(("%s is the first clip in track %s: a transition needs a clip before it"):format(where(c), tostring(tk.id)), 0)
        end
        spec = nil
      end
      if spec and i.overlap then
        error(("%s: give overlap or a transition (whose duration is the overlap), not both"):format(where(c)), 0)
      end
      if (i.gap or 0) > 0 and (spec or (i.overlap or 0) > 0) then
        error(("%s: a gap and an overlap cannot both lead into one clip"):format(where(c)), 0)
      end
      local tspec = spec and T.transition(spec, where(c)) or nil
      local overlap = tspec and tspec.duration or (i.overlap or 0)
      if k == 1 then overlap = 0 end
      c._start = cursor + (i.gap or 0) - overlap
      c._overlap = overlap
      if tspec then
        tspec.prev = prev
        c._in = tspec
        prev._out = c
        incoming[#incoming + 1] = c
      end
      local dur = Clip.duration(comp, c)
      if not dur and k < #members then
        error(("%s in track %s needs a duration: the next clip starts where it ends"):format(where(c), tostring(tk.id)), 0)
      end
      cursor = c._start + (dur or math.huge)
      prev = c
    end
    tk._members, tk._end = members, cursor
  end
  return incoming
end

return T
