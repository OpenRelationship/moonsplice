-- When each thing is on screen, measured.
--
-- A timeline's biggest shape is the clip, and a clip's width is the stretch of time the thing
-- exists for. That is the one thing every editor in the world agrees on, and it is the reason a
-- timeline can be read before it is learned.
--
-- The app used to draw that bar across the whole composition for everything, because the shape
-- of a composition does not say when a thing is visible and guessing it from an opacity tween is
-- a heuristic that is wrong the first time somebody fades something out and back in. So this
-- measures it instead: evaluate the composition at each frame and apply the same gates the
-- painter applies --
--
--   * an effective opacity of zero paints nothing (and a fading parent takes its children),
--   * a video outside its own `from`..`from + duration` window paints nothing,
--   * a sound is audible from `at` for its own duration,
--   * a container paints nothing of its own, and is present while any of its children are.
--
-- Host-free on purpose: no love, no ffi, no rasterizer. A compiled comp in, intervals out, so
-- the numbers do not depend on which renderer is running.

local O = {}

-- Kinds that hold other things rather than painting. `painter.lua` skips camera, light and mesh
-- outright; group, kinetic, fx and world exist to carry children.
local CONTAINER = {
  group = true, kinetic = true, fx = true, world = true,
  camera = true, light = true, mesh = true,
}

local SOUND = { audio = true, tts = true, music = true, sfx = true }

-- Kinds that are in the edit without being in the picture or the mix. A marker is a note about
-- a moment; it is never on screen, and saying it is on screen for the whole composition -- which
-- is what "no opacity, so opacity is 1" would say -- would draw a bar across the timeline for a
-- thing that has no duration at all.
local UNSEEN = { marker = true }

-- No composition needs more than this many measurements to show a clip correctly, and a long one
-- should not make opening it slow. Past the cap the sampling strides, which can miss a flicker
-- shorter than the stride; `stride` comes back in the result so a caller can say so.
local MAX_SAMPLES = 3000

local function parent_of(n)
  return n.initial and n.initial.parent or nil
end

--- Own opacity times every ancestor's, which is what the painter multiplies.
local function effective_opacity(n)
  local o = n:get("opacity")
  if o == nil then o = 1 end
  local p = parent_of(n)
  local guard = 0
  while p and guard < 64 do
    local po = p:get("opacity")
    if po ~= nil then o = o * po end
    p = parent_of(p)
    guard = guard + 1
  end
  return o
end

--- Is this node putting anything on screen (or into the mix) at the current evaluated time?
--- Containers answer false here and are filled in from their children afterwards.
local function paints(n, t)
  if UNSEEN[n.kind] then
    return false
  end
  if SOUND[n.kind] then
    local at = n.initial.at or 0
    local d = n.initial.duration
    return t >= at and (d == nil or t < at + d)
  end
  if n.kind == "video" then
    local from = n.initial.from or 0
    local d = n.initial.duration
    if d and not (t >= from and t < from + d) then
      return false
    end
  end
  if CONTAINER[n.kind] then
    return false
  end
  return effective_opacity(n) > 0
end

--- Turn a row of per-sample booleans into intervals in seconds.
---
--- A sample at `i` stands for the frame that starts there, so a run of samples `i..j` is on
--- screen from `i * step` until the end of frame `j` -- not until `j * step`, which would draw a
--- single-frame flash as a zero-width nothing.
local function runs(on, step, duration)
  local out = {}
  local i = 1
  while i <= #on do
    if on[i] then
      local j = i
      while j + 1 <= #on and on[j + 1] do j = j + 1 end
      local t0 = (i - 1) * step
      local t1 = math.min(j * step, duration)
      if t1 <= t0 then t1 = math.min(t0 + step, duration) end
      out[#out + 1] = { t0 = t0, t1 = t1 }
      i = j + 1
    else
      i = i + 1
    end
  end
  return out
end

--- `of(comp)` -> { by_id = { [id] = { {t0=,t1=}, ... } }, stride = n, step = seconds }
---
--- Every node in the composition gets an entry, and a node that is never on screen gets an empty
--- one -- which is information, and the timeline says so rather than drawing a clip for it.
function O.of(comp)
  local duration = comp.duration or 0
  local fps = comp.fps or 30
  if not (duration > 0) or not (fps > 0) then
    local by_id = {}
    for _, n in ipairs(comp.nodes) do by_id[n.id] = {} end
    return { by_id = by_id, stride = 1, step = 0 }
  end

  local frames = math.floor(duration * fps + 0.5)
  if frames < 1 then frames = 1 end
  local stride = math.max(1, math.ceil(frames / MAX_SAMPLES))
  local step = stride / fps
  local samples = math.floor(frames / stride)
  if samples < 1 then samples = 1 end

  local rows = {}
  for _, n in ipairs(comp.nodes) do rows[n] = {} end

  for s = 1, samples do
    local t = math.min((s - 1) * step, duration)
    comp:evaluate(t)
    for _, n in ipairs(comp.nodes) do
      rows[n][s] = paints(n, t)
    end
  end

  -- A container is present while anything inside it is. Walking up from each child covers a
  -- group inside a group without a second pass.
  for _, n in ipairs(comp.nodes) do
    if not CONTAINER[n.kind] then
      local p = parent_of(n)
      local guard = 0
      while p and guard < 64 do
        local up = rows[p]
        if up then
          for s = 1, samples do
            if rows[n][s] then up[s] = true end
          end
        end
        p = parent_of(p)
        guard = guard + 1
      end
    end
  end

  local by_id = {}
  for _, n in ipairs(comp.nodes) do
    by_id[n.id] = runs(rows[n], step, duration)
  end
  return { by_id = by_id, stride = stride, step = step }
end

return O
