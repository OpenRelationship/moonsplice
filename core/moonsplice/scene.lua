-- Part of moonsplice (core/moonsplice/init.lua): see its head for the module's contract.
local M = require("moonsplice")
local Scene, add = M._.Scene, M._.add

function Scene:rect(p) return add(self, "rect", p) end
-- Surface is a named visual backplate: visually a rect, semantically a parent
-- for a UI assembly. It supports shadow and blend without making authoring code
-- overload `rect`. It does not yet flatten children into an offscreen texture;
-- child effects remain per raster-backed node.
function Scene:surface(p)
  assert(p.w and p.h, "moonsplice: surface{w=,h=} required")
  return add(self, "surface", p)
end
function Scene:circle(p) return add(self, "circle", p) end
function Scene:text(p) return add(self, "text", p) end
-- Video layer (v0: resolve phase extracts frames at comp fps, cover-cropped to w×h).
-- Structural (not animatable): src, from (comp-time start), duration, media_start.
function Scene:video(p)
  assert(type(p.src) == "string", "moonsplice: video{src=...} required")
  return add(self, "video", p)
end
function Scene:image(p)
  -- prompt= in place of src=: generated once in the resolve phase (MiniMax image-01) and cached by hash
  assert(type(p.src) == "string" or type(p.prompt) == "string", "moonsplice: image{src=...} or image{prompt=...} required")
  return add(self, "image", p)
end
-- Kinetic text: splits text into per-char nodes (positions measured by the host
-- at compile via post_scene). Returns the container; container.chars = array of
-- char nodes for t:stagger / per-char tweens. anchor: "center" on p.x.
function Scene:kinetic(p)
  assert(type(p.text) == "string" and #p.text > 0, "moonsplice: kinetic{text=...} required")
  local container = add(self, "kinetic", {
    text = p.text, x = p.x or 0, y = p.y or 0, size = p.size or 64,
    spacing = p.spacing or 0, font = p.font,
  })
  container.chars = {}
  for ch in p.text:gmatch(".") do
    if ch ~= " " then
      local node = add(self, "text", {
        text = ch, size = p.size or 64, color = p.color or "#ffffff",
        anchor = "center", x = 0, y = p.y or 0, font = p.font,
        opacity = p.opacity, rotation = p.rotation, scale = p.scale,
      })
      node._kinetic_char = ch
      node._group = container -- lint: chars of one word are one motion unit
      container.chars[#container.chars + 1] = node
    end
  end
  return container
end

-- A note pinned to a moment. The renderer never draws it and the encode never
-- hears it: it is a thing the *edit* contains rather than a thing the picture
-- does, which is what every editor's ruler markers are. Props: at (comp
-- seconds), text.
--
-- It is a node rather than a field on the comp because that is what makes it
-- cost nothing: putting one in, moving it, renaming it and taking it out are
-- the verbs the app already has, and a marker needs no eleventh.
function Scene:marker(p)
  assert(type(p.text) == "string", "moonsplice: marker{text=...} required")
  assert(type(p.at) == "number", "moonsplice: marker{at=...} required, in seconds")
  return add(self, "marker", p)
end

-- Audio clips: never rendered by the engine — resolved pre-render, mixed by
-- ffmpeg filter_complex at encode (canon §1.5). Props: at (comp seconds),
-- duration (default = clip length), media_start, volume, fade_in, fade_out.
function Scene:audio(p)
  assert(type(p.src) == "string", "moonsplice: audio{src=...} required")
  return add(self, "audio", p)
end
-- ElevenLabs TTS: resolve phase generates + caches the clip; after resolve,
-- node.initial.duration holds the real length so scripts can pace to narration.
function Scene:tts(p)
  assert(type(p.text) == "string", "moonsplice: tts{text=...} required")
  return add(self, "tts", p)
end
-- ElevenLabs sound effect from a text prompt.
function Scene:sfx(p)
  assert(type(p.prompt) == "string", "moonsplice: sfx{prompt=...} required")
  return add(self, "sfx", p)
end
-- Eleven Music track from a prompt (paid-plan API; free tier gets a clear error).
-- gen_duration in seconds (3-300). Same content-hash caching as tts/sfx.
function Scene:music(p)
  assert(type(p.prompt) == "string", "moonsplice: music{prompt=...} required")
  return add(self, "music", p)
end
-- HTML/CSS layer (Blitz: Stylo + Taffy + vello_cpu — no Chrome). Static content
-- renders once and is cached; tweening `progress` substitutes {{progress}} in the
-- markup and re-renders per change. Transforms animate like any node.
function Scene:html(p)
  assert(type(p.html) == "string" or type(p.src) == "string",
    "moonsplice: html{html=...} or html{src=...} required")
  assert(p.w and p.h, "moonsplice: html{w=,h=} required")
  return add(self, "html", p)
end
-- Full HTML document painted to a viewport (linked CSS/images/fonts). Rasterized
-- once at resolve — fetch and optional script bake live there, never in evaluate(t).
function Scene:page(p)
  assert(type(p.html) == "string" or type(p.src) == "string",
    "moonsplice: page{html=...} or page{src=...} required")
  return add(self, "page", p)
end
-- Procedural vector layer (vello_cpu): draw fn(v, t) builds a display list each
-- frame — antialiased paths/beziers/gradients love.graphics lacks. fn must be
-- pure f(t): no clocks, no state, no I/O.
function Scene:vector(p)
  assert(type(p.draw) == "function", "moonsplice: vector{draw=function(v,t) ...} required")
  assert(p.w and p.h, "moonsplice: vector{w=,h=} required")
  return add(self, "vector", p)
end
-- Group: a transform parent. Children declare `parent = group` and inherit the
-- group's x/y/scale/rotation/opacity, so a whole UI assembly moves as one unit.
-- `clip_node` on children provides a live mask; `blend` accepts the CSS blend modes and `add`.
-- Effects are available on raster-backed child nodes (`html` and `vector`) and
-- accept CSS-style sugar, e.g. effects={blur=8, contrast=1.1}.
function Scene:group(p)
  return add(self, "group", p or {})
end
-- Clip: a group with its own time (core/moonsplice/clip.lua, .robot/docs/rows.robot "Composition"). Its children
-- see local time: start (parent seconds it begins), duration, offset (local time at start), speed (keyable,
-- integrated), time (keyable remap), loop + length, hold, reverse. Outside its range it draws nothing.
function Scene:clip(p) return add(self, "clip", p or {}) end
-- Track: its child clips play end to end, each starting where the one before ends, less the overlap
-- its transition needs. Reordering or trimming one clip ripples the rest.
function Scene:track(p) return add(self, "track", p or {}) end
-- Precomp: a clip of another rows comp (src), its nodes made again under this one as <id>/<child id>.
-- core/moonsplice/rows/ expands it; it needs the host to read the file, so it is rows form only.
function Scene:precomp(p)
  assert(type(p.src) == "string", "moonsplice: precomp{src=...} required")
  if not p.length then error("moonsplice: precomp is rows form only (.robot/docs/rows.robot, Composition)", 0) end
  return add(self, "precomp", p)
end
-- Flex container (Taffy): positions its item nodes at compile/resolve time.
-- Structural: x,y,w,h,dir("row"|"column"),justify,align,gap,pad,wrap,items={nodes}.
-- Solved once before render — layout is static; item x/y get overwritten.
function Scene:flex(p)
  assert(type(p.items) == "table" and #p.items > 0, "moonsplice: flex{items={...}} required")
  return add(self, "flex", p)
end
-- SVG layer (resvg): rasterized at resolve time to exactly w×h, cached.
function Scene:svg(p)
  assert(type(p.src) == "string", "moonsplice: svg{src=...} required")
  assert(p.w and p.h, "moonsplice: svg{w=,h=} required")
  return add(self, "svg", p)
end
