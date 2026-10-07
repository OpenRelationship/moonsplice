-- Part of moonsplice (core/moonsplice/init.lua): see its head for the module's contract.
local M = require("moonsplice")
local color, Scene, add = M._.color, M._.Scene, M._.add

-- Lottie layer (velato, scene/src/lottie.rs): frame-addressed vector animation. Structural: src, from,
-- duration, loop, speed. w/h define the raster target size.
-- A game's view: called every frame after the state has advanced, to set what nodes show
-- (`node:set{...}`). Views read the state; they never change it.
-- Media and facts made from a source before render (core/runtime/derive.lua): `v.src` is the derived
-- file; audio facts come back as `beats`, `onsets`, `tempo`, `words`, `speech`, `silent`. A host
-- with no derive step (the web preview) hands back the source and no facts.
function Scene:derive(src, ops)
  assert(type(src) == "string", "moonsplice: s:derive(src, ops) takes a path")
  if not self._derive then return { src = src, steps = {} } end
  return self._derive(src, ops or {})
end

-- s:solid(tree) -> { src = mesh file, size, volume, parts, watertight, ... } (.robot/docs/solids.robot)
function Scene:solid(tree)
  assert(type(tree) == "table", "moonsplice: s:solid(tree) takes a solid tree")
  if not self._solid then error("moonsplice: this host builds no solids", 0) end
  return self._solid(tree)
end

function Scene:view(fn)
  assert(type(fn) == "function", "moonsplice: s:view(fn(state, t)) takes a function")
  self.views[#self.views + 1] = fn
end

function Scene:lottie(p)
  assert(type(p.src) == "string", "moonsplice: lottie{src=...} required")
  assert(p.w and p.h, "moonsplice: lottie{w=,h=} required")
  return add(self, "lottie", p)
end
-- Post-FX group: children parented here are flattened to an offscreen canvas,
-- then a moonshine-style shader chain runs. Uniforms (bloom, vignette, chroma,
-- grain, glow, blur) are timeline-animatable. Optional `shadertoy` GLSL is
-- converted to a LÖVE effect (iTime = t). Seek-safe: shaders + uniforms only.
function Scene:fx(p)
  assert(p.w and p.h, "moonsplice: fx{w=,h=} required")
  p.chain = p.chain or { "bloom", "vignette" }
  p.fx_bloom = p.fx_bloom or p.bloom or 0.45
  p.fx_vignette = p.fx_vignette or p.vignette or 0.35
  p.fx_chroma = p.fx_chroma or p.chroma or 1.2
  p.fx_grain = p.fx_grain or p.grain or 0.06
  p.fx_glow = p.fx_glow or p.glow or 0.4
  p.fx_blur = p.fx_blur or p.blur or 0
  p.fx_tonemap = p.fx_tonemap or p.tonemap or 0
  p.fx_pixelate = p.fx_pixelate or p.pixelate or 0
  p.fx_posterize = p.fx_posterize or p.posterize or 0
  p.fx_worley = p.fx_worley or p.worley or 0
  return add(self, "fx", p)
end
-- Frame-addressed spritesheet. `src` is a PNG (optionally with Aseprite JSON
-- via `json=` or a .json src whose meta.image points at the sheet). Frame =
-- floor((t-from)*fps) % count, or Aseprite per-frame durations if fps is nil.
function Scene:spritesheet(p)
  assert(type(p.src) == "string", "moonsplice: spritesheet{src=...} required")
  return add(self, "spritesheet", p)
end
-- Closed-form particles. Particle i = f(t − birth_i) from hash(seed, i).
-- No love.graphics.newParticleSystem — any-order seek is identical.
function Scene:particles(p)
  assert(type(p.n) == "number" and p.n > 0, "moonsplice: particles{n=} required")
  p.seed = p.seed or 1
  p.life = p.life or 1.2
  p.emit = p.emit or 0
  p.emit_window = p.emit_window or 0.2
  p.spread = p.spread or math.pi
  p.heading = p.heading or -math.pi / 2
  p.speed = p.speed or 240
  p.gravity = p.gravity or 520
  p.r = p.r or 3.5
  return add(self, "particles", p)
end
-- Data motion (d3-shape port). type = line|area|bar|stack|pie|arc.
-- reveal clips path length; mix lerps data→data1; stroke="rough" is seeded.
function Scene:chart(p)
  assert(type(p.data) == "table" and #p.data > 0, "moonsplice: chart{data=} required")
  p.type = p.type or "bar"
  p.w = p.w or 420
  p.h = p.h or 240
  p.reveal = p.reveal or 1
  p.mix = p.mix or 0
  p.stroke = p.stroke or "clean"
  p.seed = p.seed or 1
  if p.colors then
    for i, c in ipairs(p.colors) do
      if type(c) == "string" then p.colors[i] = color.parse(c) end
    end
  end
  return add(self, "chart", p)
end
-- Motion-bumper ornaments: star, compass, egg, linker. Polylines; optional rough.
function Scene:ornament(p)
  -- which ornament is `shape` (`kind` is the node's own kind in rows, .robot/docs/rows.robot; still read here)
  p.shape = p.shape or p.kind or p.type or "star"
  p.kind, p.type = nil, nil
  p.w = p.w or 180
  p.h = p.h or 180
  p.reveal = p.reveal or 1
  p.stroke = p.stroke or "clean"
  p.seed = p.seed or 1
  p.width = p.width or 2.5
  return add(self, "ornament", p)
end
-- Captions: inline cues or SRT/CSV src (resolved to cues). Text steps on the timeline.
-- Build cues from aligned words via require("moonsplice.captions").from_lines / from_words
-- (opts.mode: word | phrase | rolling | line, opts.window for phrase size).
function Scene:captions(p)
  p.size = p.size or 36
  p.text = p.text or ""
  if p.cues then p.cues = require("moonsplice.captions").normalize(p.cues) end
  return add(self, "text", p)
end
-- Seek-safe skeletal pose. skeleton = Spine-like table; animation name; t drives keys.
function Scene:spine(p)
  assert(p.skeleton or p.src, "moonsplice: spine{skeleton= or src=} required")
  p.w = p.w or 240
  p.h = p.h or 320
  p.animation = p.animation or "default"
  return add(self, "spine", p)
end
-- Frame-addressed Rive (.riv). Same clock as Lottie: set time from t, no update(dt).
function Scene:rive(p)
  assert(type(p.src) == "string", "moonsplice: rive{src=} required")
  assert(p.w and p.h, "moonsplice: rive{w=,h=} required")
  return add(self, "rive", p)
end
-- Shared plane camera. Perspective nodes set `camera = cam` and keep their own dolly.
function Scene:camera(p)
  p.yaw = p.yaw or 0
  p.pitch = p.pitch or 0
  p.roll = p.roll or 0
  p.dolly = p.dolly or 1
  p.fov = p.fov or 0.62
  p.aperture = p.aperture or 0
  return add(self, "camera", p)
end
-- Real 3D layer: offscreen RGBA, same contract as s:lottie. Children are mesh/light.
-- Pose is written from t; the native crate rasterizes one frame. No engine loop.
function Scene:world(p)
  assert(p.w and p.h, "moonsplice: world{w=,h=} required")
  p.fov = p.fov or 0.7
  p.cam_x = p.cam_x or 0
  p.cam_y = p.cam_y or 0.35
  p.cam_z = p.cam_z or 3.2
  p.look_x = p.look_x or 0
  p.look_y = p.look_y or 0
  p.look_z = p.look_z or 0
  p.yaw = p.yaw or 0
  p.pitch = p.pitch or 0
  p.roll = p.roll or 0
  p.near = p.near or 0.05
  p.far = p.far or 80
  return add(self, "world", p)
end
-- glTF instance or unit primitive, parented to a world, or to a mesh in one: a part under a mesh
-- takes its x/y/z, yaw/pitch/roll and scale in that mesh's frame, so an assembly moves as one.
-- Transforms are f(t).
local function in_world(p) return p and (p.kind == "world" or p.kind == "mesh") end
function Scene:mesh(p)
  assert(in_world(p.parent), "moonsplice: mesh{parent=world or mesh} required")
  assert(p.src or p.primitive, "moonsplice: mesh{src= or primitive=} required")
  p.primitive = p.primitive or (p.src and "gltf" or "cube")
  p.x = p.x or 0
  p.y = p.y or 0
  p.z = p.z or 0
  p.yaw = p.yaw or 0
  p.pitch = p.pitch or 0
  p.roll = p.roll or 0
  p.scale = p.scale or 1
  return add(self, "mesh", p)
end
function Scene:light(p)
  assert(in_world(p.parent), "moonsplice: light{parent=world or mesh} required")
  p.dir = p.dir or { -0.4, -1, -0.3 } -- the way the light travels: down and away from a camera on +z
  p.intensity = p.intensity or 1
  p.color = p.color or "#ffffff"
  return add(self, "light", p)
end
-- Image or rasterized text as a grid mesh, displaced by a vertex shader.
-- amp/freq are animatable; time comes from t. Seek-safe.
function Scene:displace(p)
  assert(p.src or p.text, "moonsplice: displace{src= or text=} required")
  assert(p.w and p.h, "moonsplice: displace{w=,h=} required")
  p.cols = p.cols or 24
  p.rows = p.rows or 16
  p.amp = p.amp or 14
  p.freq = p.freq or 1
  return add(self, "displace", p)
end
-- Escape hatch: pure custom draw fn(t, g) where g is the host graphics API.
function Scene:draw(fn) return add(self, "draw", { fn = fn }) end
function Scene:script(fn) self.scripts[#self.scripts + 1] = fn end

