-- moonsplice authoring core. Host-free pure Lua: no love.*, no I/O, no clocks.
--
-- Comp file shape:
--   local e = require("moonsplice")
--   return e.comp {
--     width = 1280, height = 720, duration = 4, fps = 30,
--     scene = function(s)
--       local box = s:rect{ x=100, y=100, w=200, h=120, color="#4fa8f2" }
--       s:script(function(t)
--         t:tween(box, 1.0, { x = 800 }, "cubicInOut")
--         t:wait(0.5)
--         t:parallel(
--           function() t:tween(box, 0.5, { rotation = math.pi/4 }, "backOut") end,
--           function() t:tween(box, 0.5, { opacity = 0.3 }) end)
--       end)
--     end,
--   }
--
-- Scripts read top-to-bottom like a screenplay but are executed ONCE at compile
-- time, recording absolute-time segments onto a timeline. Rendering evaluates the
-- timeline at arbitrary t — seek, not playback.

local Timeline = require("moonsplice.timeline")
local color = require("moonsplice.color")

local M = {}

local ANIMATABLE = {
  x = true, y = true, w = true, h = true, r = true, rx = true,
  rotation = true, scale = true, opacity = true, color = true, size = true,
  progress = true, -- html nodes: {{progress}} substitution, re-rendered on change
  tracking = true, -- text letter-spacing in px (moonsplice-scene renderer; love ignores it)
  -- Adjustment-layer controls. These stay flat so timeline segments can seek
  -- them independently; `effects = { blur = 8, contrast = 1.1 }` is only
  -- authoring sugar and expands to these properties at node construction.
  effect_blur = true, effect_brightness = true, effect_contrast = true,
  effect_saturate = true, effect_grayscale = true, effect_sepia = true,
  effect_invert = true, effect_opacity = true, effect_hue_rotate = true,
  -- 3D camera on a flat surface (perspective = true). See core/runtime/persp.lua.
  -- Shared s:camera / s:world look-at. Mesh z is world-space, not screen.
  yaw = true, pitch = true, roll = true, dolly = true, fov = true,
  aperture = true, maxcoc = true, focus_u = true, focus_v = true,
  truck_u = true, truck_v = true,
  look_x = true, look_y = true, look_z = true,
  cam_x = true, cam_y = true, cam_z = true, z = true,
  -- cursor composited onto the surface (page-normalized), so it warps with it
  cursor_u = true, cursor_v = true, cursor_w = true, cursor_opacity = true,
  -- type-on (0..1 of visible characters) and mesh displacement
  reveal = true, amp = true, freq = true,
  -- moonshine-style fx uniforms (s:fx chain)
  fx_bloom = true, fx_vignette = true, fx_chroma = true,
  fx_grain = true, fx_glow = true, fx_blur = true,
  fx_tonemap = true, fx_pixelate = true, fx_posterize = true, fx_worley = true,
  mix = true, -- chart data→data1 lerp
  outline = true, weight = true, -- SDF/coverage type
  -- a world's materials and lights (core/runtime/worldbevy.lua reads them every frame)
  metallic = true, roughness = true, reflectance = true, emissive_strength = true, intensity = true,
  -- a clip's clock (core/moonsplice/clip.lua): a keyed speed is integrated, a keyed time is a time remap
  speed = true, time = true,
}

-- ---------- nodes ----------
local Node = {}
Node.__index = Node

-- Live values, written by a game's view each frame (core/moonsplice/game.lua). They sit where the
-- timeline writes, after it, so a view has the last word on what it sets.
--
-- A frame must not depend on the frame before it, so what a view set is cleared before every
-- evaluate (`Comp:evaluate`): a view that sets something only sometimes (a finish card's
-- opacity) leaves it at its own value, not at whatever the last frame rendered left behind.
local LIVE = setmetatable({}, { __mode = "k" })
function Node:set(props)
  local keys = LIVE[self]
  if not keys then keys = {}; LIVE[self] = keys end
  for k, v in pairs(props) do
    self.state[k] = v
    keys[k] = true
  end
  return self
end
M._clear_live = function()
  for node, keys in pairs(LIVE) do
    for k in pairs(keys) do node.state[k] = nil end
  end
end

function Node:get(prop)
  local v = self.state[prop]
  if v == nil then v = self.initial[prop] end
  return v
end

-- ---------- forced alignment (audio/tts nodes with align = true) ----------
-- resolve populates node.words = { {text=, t0=, t1=}, ... } relative to the clip.
-- These accessors return COMP-ABSOLUTE seconds, so a cue written as
--   at(vo3:word("languages"))
-- stays correct when the copy, the voice, or the clip's start time changes.
local function norm(w) return (w:lower():gsub("[^%w']", "")) end

local function find_word(self, needle, nth)
  assert(self.words, "moonsplice: node has no alignment — pass align = true to tts{}/audio{}")
  local want, hit = norm(needle), 0
  for _, w in ipairs(self.words) do
    if norm(w.text) == want then
      hit = hit + 1
      if hit == (nth or 1) then return w end
    end
  end
  error(("moonsplice: word %q not found in aligned narration %q"):format(needle,
    self.initial.text or self.initial.src or "?"), 0)
end

-- start of a spoken word, comp-absolute
function Node:word(needle, nth)
  return self.initial.at + find_word(self, needle, nth).t0
end

-- end of a spoken word, comp-absolute (use to land a beat as the word finishes)
function Node:word_end(needle, nth)
  return self.initial.at + find_word(self, needle, nth).t1
end

-- every aligned word as comp-absolute {text, t0, t1}; drives per-word captions
function Node:word_times()
  assert(self.words, "moonsplice: node has no alignment — pass align = true")
  local out = {}
  for k, w in ipairs(self.words) do
    out[k] = { text = w.text, t0 = self.initial.at + w.t0, t1 = self.initial.at + w.t1 }
  end
  return out
end

-- find a phoneme or viseme within aligned narration
function Node:phoneme(needle, nth)
  assert(self.phonemes, "moonsplice: node has no phoneme alignment")
  local want, hit = needle:lower(), 0
  for _, p in ipairs(self.phonemes) do
    if p.text:lower() == want then
      hit = hit + 1
      if hit == (nth or 1) then return self.initial.at + p.t0 end
    end
  end
  error(("moonsplice: phoneme %q not found in aligned narration"):format(needle), 0)
end

-- find an extracted feature event (e.g. "beat", "drop", "cut", "motion_peak")
function Node:event(name, nth)
  assert(self.events, "moonsplice: node has no extracted events — pass analyze = true")
  local want, hit = name:lower(), 0
  for _, ev in ipairs(self.events) do
    if ev.name:lower() == want or ev.type:lower() == want then
      hit = hit + 1
      if hit == (nth or 1) then return self.initial.at + ev.t0 end
    end
  end
  error(("moonsplice: event %q not found on node %s"):format(name, self.id), 0)
end

-- SMPTE timecode helper: converts seconds to "HH:MM:SS:FF" or "HH:MM:SS;FF" (drop frame)
function Node:smpte(t, fps, drop_frame)
  fps = fps or 30
  t = t or (self.initial and self.initial.at or 0)
  local total_frames = math.floor(t * fps + 0.5)
  local f = total_frames % fps
  local total_sec = math.floor(total_frames / fps)
  local s = total_sec % 60
  local total_min = math.floor(total_sec / 60)
  local m = total_min % 60
  local h = math.floor(total_min / 60)
  local sep = drop_frame and ";" or ":"
  return string.format("%02d:%02d:%02d%s%02d", h, m, s, sep, f)
end

local node_defaults = {
  opacity = 1, rotation = 0, scale = 1, anchor = "topleft",
  effect_blur = 0, effect_brightness = 1, effect_contrast = 1,
  effect_saturate = 1, effect_grayscale = 0, effect_sepia = 0,
  effect_invert = 0, effect_opacity = 1, effect_hue_rotate = 0,
}

local function make_node(kind, id, props)
  local initial = {}
  for k, v in pairs(node_defaults) do initial[k] = v end
  for k, v in pairs(props) do initial[k] = v end
  if type(props.effects) == "table" then
    for key, value in pairs(props.effects) do
      local prop = "effect_" .. key
      assert(ANIMATABLE[prop], "moonsplice: unknown effect " .. tostring(key))
      initial[prop] = value
    end
  end
  -- s:fx { bloom = 0.5, vignette = 0.4 } sugar → fx_bloom / fx_vignette
  for alias, prop in pairs({
    bloom = "fx_bloom", vignette = "fx_vignette", chroma = "fx_chroma",
    grain = "fx_grain", glow = "fx_glow", blur = "fx_blur",
    tonemap = "fx_tonemap", pixelate = "fx_pixelate", posterize = "fx_posterize",
    worley = "fx_worley",
  }) do
    if props[alias] ~= nil and initial[prop] == nil then
      initial[prop] = props[alias]
    end
  end
  if initial.color ~= nil then initial.color = color.parse(initial.color) end
  if initial.outline_color ~= nil then initial.outline_color = color.parse(initial.outline_color) end
  return setmetatable({ kind = kind, id = id, initial = initial, state = {} }, Node)
end

-- ---------- scene builder ----------
local Scene = {}
Scene.__index = Scene

-- Where in the composition a node was written. Additive: nothing in the render reads it, so
-- no frame hash moves. It exists because an editor has to map a thing on screen back to the
-- text that built it, and counting constructor calls cannot do that — one call inside a loop
-- builds many nodes, and sugar like `s:captions` builds a node of another kind entirely.
--
-- Found by walking out to the first frame that belongs to the composition itself, rather than a
-- fixed level, because the depth differs between `s:rect{}` and sugar that calls it.
local function wrote_at(s)
  if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then return nil end
  local want = s and s.source
  for level = 2, 12 do
    local info = debug.getinfo(level, "Sl")
    if not info then return nil end
    if info.currentline and info.currentline > 0 then
      if want == nil or info.source == want then return info.currentline end
      if info.source and info.source:match("%.lua$") and not info.source:match("/lib/moonsplice/") then
        return info.currentline
      end
    end
  end
  return nil
end

-- The blend modes the renderer composites with: the CSS set (vello's Mix) plus `add`.
-- LÖVE's `subtract` and `replace` left with LÖVE: no CSS mode and no vello compose is either.
M.BLENDS = {
  alpha = true, normal = true, multiply = true, screen = true, overlay = true, darken = true,
  lighten = true, ["color-dodge"] = true, ["color-burn"] = true, ["hard-light"] = true,
  ["soft-light"] = true, difference = true, exclusion = true, hue = true, saturation = true,
  color = true, luminosity = true, add = true,
}
local BLEND_INSTEAD = { subtract = "difference", replace = "normal (alpha)" }

local function add(s, kind, props)
  if props.blend ~= nil and not M.BLENDS[props.blend] then
    local instead = BLEND_INSTEAD[props.blend]
    error(("moonsplice: blend %q is not a blend mode%s"):format(tostring(props.blend),
      instead and (" any more; use " .. instead) or ""), 0)
  end
  s.count = s.count + 1
  local id = props.id or (kind .. s.count)
  local n = make_node(kind, id, props)
  n.line = wrote_at(s)
  s.nodes[#s.nodes + 1] = n
  return n
end

-- ---------- script recorder ----------
local Rec = {}
Rec.__index = Rec

local function resolve_from(self, node, prop)
  local sim = self.sim[node]
  if sim and sim[prop] ~= nil then return sim[prop] end
  local v = node.initial[prop]
  if v == nil then
    error(("moonsplice: tween of %s.%s but node has no initial value for it"):format(node.id, prop), 0)
  end
  return v
end

local function record(self, node, dur, props, easename)
  local t0, t1 = self.cursor, self.cursor + dur
  for prop, target in pairs(props) do
    if not ANIMATABLE[prop] then
      error(("moonsplice: %q is not animatable"):format(prop), 0)
    end
    local to = target
    if prop == "color" then to = color.parse(target) end
    local from = resolve_from(self, node, prop)
    self.timeline:record(node, prop, t0, t1, from, to, easename)
    self.sim[node] = self.sim[node] or {}
    self.sim[node][prop] = to
  end
  self.cursor = t1
end

-- Structural (non-animatable) props that a `set` may switch instantly at a
-- point in time — text swaps, source swaps. Recorded as step segments.
local SETTABLE = { text = true, src = true, font = true }

-- ---------- comp ----------
local Comp = {}
Comp.__index = Comp

function M.palette(opts)
  return color.palette(opts)
end

package.loaded["moonsplice"] = M

-- what the parts share, and the parts (they load after this table is registered as moonsplice)
M._ = {
  Timeline = Timeline, color = color, ANIMATABLE = ANIMATABLE, Node = Node,
  make_node = make_node, Scene = Scene, wrote_at = wrote_at, add = add,
  Rec = Rec, record = record, resolve_from = resolve_from, SETTABLE = SETTABLE,
  Comp = Comp, BLEND_INSTEAD = BLEND_INSTEAD, node_defaults = node_defaults,
}
require("moonsplice.comp")
require("moonsplice.kinds")
require("moonsplice.rec")
require("moonsplice.scene")

-- Nodes a constructor makes besides the one it returns (kinetic's characters, a chart's marks,
-- a caption's text) are its own making: marked `generated_by`, so rows (.robot/docs/rows.robot) list the
-- node that was written and let its constructor make the rest again, with the same ids.
for name, fn in pairs(Scene) do
  if type(fn) == "function" and name ~= "derive" and name ~= "view" and name ~= "script" then
    Scene[name] = function(self, ...)
      local first = #self.nodes + 1
      -- the props as written, before the constructor fills in defaults or hands them to what it makes
      local arg, authored = ..., nil
      if (self._depth or 0) == 0 and type(arg) == "table" then
        authored = {}
        for k, v in pairs(arg) do authored[k] = v end
      end
      self._depth = (self._depth or 0) + 1
      local ok, r = pcall(fn, self, ...)
      self._depth = self._depth - 1
      if not ok then error(r, 0) end
      if self._depth == 0 and type(r) == "table" and r.kind and r.initial then
        r.authored, r.made_by = authored, name -- the constructor written (captions makes a text node)
        for i = first, #self.nodes do
          local n = self.nodes[i]
          if n ~= r then n.generated_by = r.id end
        end
      end
      return r
    end
  end
end

-- what core/moonsplice/rows/ builds a comp from rows with
M.Scene, M.ANIMATABLE, M.SETTABLE, M.ease = Scene, ANIMATABLE, SETTABLE, require("moonsplice.ease")
M.NODE_DEFAULTS = node_defaults

return M
