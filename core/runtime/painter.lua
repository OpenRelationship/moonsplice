-- love host painter: draws an moonsplice scene graph via love.graphics.
-- The only file (besides main.lua) that touches love.* — the painter contract
-- keeps lib/ host-free so the rust host can implement the same interface.
local P = {}

-- BT.709 YUV -> RGB on the GPU. Cover-crop + scale ride the draw quad for free.
local yuv_shader
local function get_yuv_shader()
  if not yuv_shader then
    yuv_shader = love.graphics.newShader([[
      uniform Image u_plane;
      uniform Image v_plane;
      uniform float full_range;
      vec4 effect(vec4 color, Image y_plane, vec2 uv, vec2 sc) {
        float y = Texel(y_plane, uv).r;
        float u = Texel(u_plane, uv).r - 0.5;
        float v = Texel(v_plane, uv).r - 0.5;
        y = mix((y - 0.0625) * 1.16438, y, full_range);
        float r = y + 1.5748 * v;
        float g = y - 0.18732 * u - 0.46812 * v;
        float b = y + 1.8556 * u;
        return vec4(r, g, b, 1.0) * color;
      }
    ]])
  end
  return yuv_shader
end

-- Real drop shadows: a rounded-rect silhouette rendered once into a canvas and
-- separably gaussian-blurred, then cached by geometry. Cheap per frame (one
-- textured quad) and genuinely soft, unlike stacked rects.
local blur_shader
local shadow_cache = {}

local function get_blur()
  if not blur_shader then
    blur_shader = love.graphics.newShader([[
      extern vec2 dir;       // (1/w, 0) or (0, 1/h) scaled by radius
      vec4 effect(vec4 c, Image tex, vec2 uv, vec2 sc) {
        float w[9];
        w[0]=0.0625; w[1]=0.0938; w[2]=0.1250; w[3]=0.1562; w[4]=0.1688;
        w[5]=0.1562; w[6]=0.1250; w[7]=0.0938; w[8]=0.0625;
        vec4 sum = vec4(0.0);
        float tot = 0.0;
        for (int i = 0; i < 9; i++) {
          float o = float(i) - 4.0;
          sum += Texel(tex, uv + dir * o) * w[i];
          tot += w[i];
        }
        return (sum / tot) * c;
      }
    ]])
  end
  return blur_shader
end

-- returns a canvas holding a soft shadow for a w×h rounded rect
local function shadow_canvas(w, h, rx, blur)
  local key = ("%d|%d|%d|%d"):format(w, h, rx, blur)
  local c = shadow_cache[key]
  if c then return c end
  local pad = blur * 3
  local cw, ch = math.ceil(w + pad * 2), math.ceil(h + pad * 2)
  local a = love.graphics.newCanvas(cw, ch)
  local b = love.graphics.newCanvas(cw, ch)
  local prev = love.graphics.getCanvas()
  local pc, pv = love.graphics.getStencilTest()
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setStencilTest()
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.setCanvas(a)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", pad, pad, w, h, rx, rx)
  love.graphics.setColor(1, 1, 1, 1)
  local sh = get_blur()
  love.graphics.setShader(sh)
  -- two separable passes, repeated for a wider kernel
  for _ = 1, 3 do
    love.graphics.setCanvas(b)
    love.graphics.clear(0, 0, 0, 0)
    sh:send("dir", { (blur / 4) / cw, 0 })
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(a, 0, 0)
    love.graphics.setCanvas(a)
    love.graphics.clear(0, 0, 0, 0)
    sh:send("dir", { 0, (blur / 4) / ch })
    love.graphics.draw(b, 0, 0)
  end
  love.graphics.setShader()
  love.graphics.setCanvas(prev and { prev, stencil = true } or nil)
  love.graphics.pop()
  if pc then love.graphics.setStencilTest(pc, pv) end
  b:release()
  shadow_cache[key] = { canvas = a, pad = pad }
  return shadow_cache[key]
end

P.shadow_canvas = shadow_canvas

-- A font, as the code that lays text out asks about it: how wide a string is, how tall a line is.
--
-- Answered by scene/ -- parley, the same shaper and the same font file that draw the text -- so a
-- width used to place a line is the width the line is drawn at. These used to be LÖVE fonts
-- (FreeType), which measured a little differently from what scene/ then painted; with LÖVE gone
-- (.robot/docs/engine.robot) there is one text engine, and it both measures and draws.
local scene = require("scene")
local fonts = {}
local Font = {}
Font.__index = Font
function Font:getWidth(text)
  local w = scene.measure(self.id, self.size, text or "")
  return w
end
function Font:getHeight()
  if not self.height then
    local _, h = scene.measure(self.id, self.size, "Ag")
    self.height = h
  end
  return self.height
end
function Font:getLineHeight() return 1 end
function Font:getAscent() return self:getHeight() * 0.8 end
function Font:getDescent() return -self:getHeight() * 0.2 end
function Font:getBaseline() return self:getAscent() end
local function font(size, path)
  size = math.floor(size + 0.5)
  local key = (path or "") .. "|" .. size
  if not fonts[key] then
    fonts[key] = setmetatable({ id = scene.font_id(path), size = size }, Font)
  end
  return fonts[key]
end
P.font = font -- resolve.layout uses the same cache for kinetic measuring

-- Frame/image loading from absolute paths (love.filesystem is sandboxed to the
-- source dir, so go through raw io + FileData). Tiny per-node cache: render order
-- is sequential, so cache size 1 per node hits ~always.
local img_cache = {}
local function load_image(path)
  local f = assert(_MOONSPLICE_IOOPEN(path, "rb"), "moonsplice: cannot read " .. path)
  local bytes = f:read("*a")
  f:close()
  local fd = love.filesystem.newFileData(bytes, "f.jpg")
  return love.graphics.newImage(love.image.newImageData(fd))
end

local function node_image(node, path)
  local c = img_cache[node]
  if c and c.path == path then return c.img end
  if c and c.img then c.img:release() end
  local img = load_image(path)
  img_cache[node] = { path = path, img = img }
  return img
end

-- Cursor composited INTO the page surface (before any 3D warp), so it tilts
-- with the page and defocuses with it — exactly as a baked-in recording cursor
-- would. Position is normalized page coords; the sprite is offset by its
-- hotspot so the tip, not the corner, sits on the point.
local surf_cache = {}
local function surface_image(path)
  if not surf_cache[path] then surf_cache[path] = load_image(path) end
  return surf_cache[path]
end

local function paint_surface_cursor(node, w, h, dx, dy)
  if not node.cursor_file then return end
  local op = node:get("cursor_opacity")
  if op == nil then op = 1 end
  if op <= 0 then return end
  local img = surface_image(node.cursor_file)
  local iw, ih = img:getDimensions()
  local cw = node:get("cursor_w") or 34
  local hx = node.initial.cursor_hot_x or (8 / 32)
  local hy = node.initial.cursor_hot_y or (6 / 32)
  local cu = node:get("cursor_u") or 0.5
  local cv = node:get("cursor_v") or 0.5
  love.graphics.setColor(1, 1, 1, op)
  love.graphics.draw(img, dx + cu * w - hx * cw, dy + cv * h - hy * cw, 0, cw / iw, cw / iw)
  love.graphics.setColor(1, 1, 1, 1)
end

local function setcolor(c, opacity)
  c = c or { 1, 1, 1, 1 }
  love.graphics.setColor(c[1], c[2], c[3], (c[4] or 1) * opacity)
end

local sdf_shader
local function get_sdf()
  if not sdf_shader then
    sdf_shader = love.graphics.newShader([[
      uniform float weight;
      uniform float outline;
      uniform vec4 fill;
      uniform vec4 stroke;
      vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
        float a = Texel(tex, uv).a;
        float edge = 0.50 - weight * 0.12;
        float fillA = smoothstep(edge - 0.08, edge + 0.08, a);
        float strokeA = smoothstep(edge - 0.22 * outline, edge - 0.06, a) * (1.0 - fillA);
        vec4 outc = fill * fillA + stroke * strokeA;
        outc.a *= color.a;
        return outc;
      }
    ]])
  end
  return sdf_shader
end


local function anchor_offset(node, w, h)
  if node:get("anchor") == "center" then return -w / 2, -h / 2 end
  return 0, 0
end

-- Kinds that draw through `love.graphics`-shaped calls. Both branches call these: the canvas
-- branch with LÖVE's `g`, the scene branch with `sceneg`'s, which records into `scene/`.
local DRAW_KIND = {}
local function gcolor(g, c, a)
  c = c or { 1, 1, 1, 1 }
  if type(c) == "string" then c = require("moonsplice.color").parse(c) end
  g.setColor(c[1], c[2], c[3], (c[4] or 1) * a)
end

DRAW_KIND.draw = function(node, g, t, opacity)
  gcolor(g, { 1, 1, 1, 1 }, opacity)
  node.initial.fn(t, g)
end

DRAW_KIND.spritesheet = function(node, g, t, opacity)
  local img = g.image and g.image(node.file) or node_image(node, node.file)
  local iw, ih = img:getDimensions()
  local sheet = node.sheet or {}
  local frames = sheet.frames
  if not frames then
    local cols = sheet.cols or node.initial.cols or 1
    local rows = sheet.rows or node.initial.rows or 1
    local fw = node.initial.frame_w or (iw / cols)
    local fh = node.initial.frame_h or (ih / rows)
    frames = {}
    for row = 0, rows - 1 do
      for col = 0, cols - 1 do
        frames[#frames + 1] = { x = col * fw, y = row * fh, w = fw, h = fh }
      end
    end
    node.sheet = { frames = frames }
  end
  local quads = {}
  for k, fr in ipairs(frames) do quads[k] = g.newQuad(fr.x, fr.y, fr.w, fr.h, iw, ih) end
  local i = node.initial
  local rel = math.max(0, t - (i.from or 0))
  local idx
  if i.fps then
    idx = math.floor(rel * i.fps)
    if i.loop == false then
      idx = math.min(idx, #frames - 1)
    else
      idx = idx % #frames
    end
    idx = idx + 1
  else
    local acc, chosen = 0, #frames
    for fi, fr in ipairs(frames) do
      acc = acc + (fr.duration or (1 / 12))
      if rel < acc then chosen = fi break end
    end
    if i.loop == false then
      idx = math.min(chosen, #frames)
    else
      local total = acc
      if total > 0 and rel >= total then
        local r = rel % total
        acc, chosen = 0, #frames
        for fi, fr in ipairs(frames) do
          acc = acc + (fr.duration or (1 / 12))
          if r < acc then chosen = fi break end
        end
      end
      idx = chosen
    end
  end
  local fr = frames[idx]
  local dw = node:get("w") or fr.w
  local dh = node:get("h") or fr.h
  local ox, oy = anchor_offset(node, dw, dh)
  gcolor(g, { 1, 1, 1, 1 }, opacity)
  g.draw(img, quads[idx], ox, oy, 0, dw / fr.w, dh / fr.h)
end

DRAW_KIND.particles = function(node, g, t, opacity)
  local i = node.initial
  local n = i.n
  local seed = i.seed or 1
  local life = i.life or 1.2
  local emit = i.emit or 0
  local window = i.emit_window or 0.2
  local spread = i.spread or math.pi
  local heading = i.heading or -math.pi / 2
  local speed0 = i.speed or 240
  local grav = i.gravity or 520
  local rad = i.r or 3.5
  local col = node:get("color") or { 1, 1, 1, 1 }
  local function phash(k)
    local s = math.sin(seed * 12.9898 + k * 78.233) * 43758.5453
    return s - math.floor(s)
  end
  for pi = 1, n do
    local u1, u2, u3 = phash(pi), phash(pi + 97), phash(pi + 193)
    local birth = emit + u1 * window
    local age = t - birth
    if age >= 0 and age < life then
      local ang = heading + (u2 - 0.5) * spread
      local spd = speed0 * (0.55 + 0.9 * u3)
      local fade = 1 - age / life
      local px = math.cos(ang) * spd * age
      local py = math.sin(ang) * spd * age + 0.5 * grav * age * age
      gcolor(g, col, opacity * fade)
      g.circle("fill", px, py, rad * (0.45 + 0.55 * fade))
    end
  end
end

DRAW_KIND.chart = function(node, g, t, opacity)
  local spec = {
    type = node.initial.type, data = node.initial.data, data1 = node.initial.data1,
    w = node:get("w"), h = node:get("h"),
    stroke = node.initial.stroke, seed = node.initial.seed,
    roughness = node.initial.roughness, bowing = node.initial.bowing,
    color = node:get("color") or node.initial.color,
    colors = node.initial.colors, hue = node.initial.hue, sat = node.initial.sat,
    mix = node:get("mix") or 0, width = node.initial.width,
    inner = node.initial.inner, start = node.initial.start,
    track = node.initial.track,
  }
  for _, cmd in ipairs(require("moonsplice.chart").commands(spec, node:get("reveal") or 1)) do
    gcolor(g, cmd.color, opacity * (cmd.opacity or 1))
    if cmd.kind == "rect" then
      g.rectangle("fill", cmd.x, cmd.y, cmd.w, cmd.h, cmd.rx or 0, cmd.rx or 0)
    elseif cmd.kind == "arc" then
      g.arc(cmd.fill and "fill" or "line", cmd.x, cmd.y, cmd.r, cmd.a0, cmd.a1)
    elseif cmd.kind == "polyline" then
      local pts = cmd.pts
      if pts and #pts >= 4 then
        if cmd.fill and #pts >= 6 then
          g.polygon("fill", unpack(pts))
        else
          g.setLineWidth(cmd.width or 2)
          g.setLineJoin("bevel")
          g.setLineStyle("smooth")
          g.line(unpack(pts))
        end
      end
    end
  end
end

DRAW_KIND.ornament = function(node, g, t, opacity)
  local spec = {
    w = node:get("w"), h = node:get("h"), r = node.initial.r,
    n = node.initial.n, inner = node.initial.inner,
    rx = node.initial.rx, ry = node.initial.ry,
    x0 = node.initial.x0, y0 = node.initial.y0,
    x1 = node.initial.x1, y1 = node.initial.y1, bow = node.initial.bow,
    stroke = node.initial.stroke, seed = node.initial.seed,
    roughness = node.initial.roughness,
  }
  g.setLineWidth(node.initial.width or 2.5)
  g.setLineJoin("bevel")
  gcolor(g, node:get("color") or { 1, 1, 1, 1 }, opacity)
  for _, pts in ipairs(require("moonsplice.ornament").polylines(
    node.initial.shape, spec, node:get("reveal") or 1)) do
    if #pts >= 4 then g.line(unpack(pts)) end
  end
end

DRAW_KIND.spine = function(node, g, t, opacity)
  local skel = node.initial.skeleton
  if not skel then return end
  local world = require("moonsplice.spine").pose(skel, node.initial.animation, t)
  gcolor(g, node:get("color") or { 0.95, 0.72, 0.28, 1 }, opacity)
  g.setLineWidth(8)
  g.setLineJoin("bevel")
  for _, b in ipairs(world) do
    if b.length and b.length > 2 then
      g.line(b.x, b.y, b.x2, b.y2)
      g.circle("fill", b.x, b.y, 6)
    else
      g.circle("fill", b.x, b.y, 7)
    end
  end
end


local blend_modes = {
  alpha = true, add = true, subtract = true, multiply = true,
  lighten = true, darken = true, screen = true, replace = true,
}

-- The canvas path's half of a blend; which modes exist is checked when the node is made
-- (core/moonsplice), and the scene path composites every one of them.
local function set_node_blend(node)
  local blend = node.initial.blend
  if blend and blend_modes[blend] then
    love.graphics.setBlendMode(blend, blend == "replace" and "alphamultiply" or "premultiplied")
  end
end

-- Draw a flat surface: rounded corners, opacity, and — when the node sets
-- perspective = true — a 3D camera. The content is composed flat into a canvas
-- first, so the 3D path reuses the normal draw code instead of duplicating it.
local function draw_surface(node, w, h, opacity, ox, oy, rx, paint)
  if not node.initial.perspective then
    if rx > 0 then
      love.graphics.stencil(function()
        love.graphics.rectangle("fill", ox, oy, w, h, rx, rx)
      end, "replace", 1, false)
      love.graphics.setStencilTest("greater", 0)
    end
    setcolor({ 1, 1, 1, 1 }, opacity)
    paint(ox, oy)
    paint_surface_cursor(node, w, h, ox, oy)
    if rx > 0 then love.graphics.setStencilTest() end
    return
  end
  local persp = require("persp")
  local fw, fh = math.ceil(w), math.ceil(h)
  local flat = persp.flat_canvas(fw, fh)
  local prevc = love.graphics.getCanvas()
  local pcc, pvv = love.graphics.getStencilTest()
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setStencilTest()
  love.graphics.setCanvas({ flat, stencil = true })
  love.graphics.clear(0, 0, 0, 0)
  if rx > 0 then
    love.graphics.stencil(function()
      love.graphics.rectangle("fill", 0, 0, w, h, rx, rx)
    end, "replace", 1, false)
    love.graphics.setStencilTest("greater", 0)
  end
  love.graphics.setColor(1, 1, 1, 1)
  paint(0, 0)
  paint_surface_cursor(node, w, h, 0, 0)
  love.graphics.setStencilTest()
  love.graphics.setCanvas(prevc and { prevc, stencil = true } or nil)
  love.graphics.pop()
  if pcc then love.graphics.setStencilTest(pcc, pvv) end
  local stage, sx, sy = persp.render(node, flat, w, h)
  if stage then
    local bm, ba = love.graphics.getBlendMode()
    love.graphics.setBlendMode("alpha", "premultiplied")
    setcolor({ 1, 1, 1, 1 }, opacity)
    love.graphics.draw(stage, ox + sx, oy + sy)
    love.graphics.setBlendMode(bm, ba)
  end
end

-- Kick decode-ahead for every video active at t_next — called right after drawing
-- the current frame, so workers decode while love does readback + encode.
function P.prefetch(comp, t_next)
  local decode = require("decode")
  for _, node in ipairs(comp.nodes) do
    if node.kind == "video" and node.dec then
      local i = node.initial
      local rel = t_next - i.from
      if rel >= 0 and rel < i.duration then
        decode.prefetch(node.dec, i.media_start + rel)
      end
    end
  end
end

-- What a thing's opacity comes to once everything holding it has had its say. The same
-- product `paint_node` computes, hoisted so a decision can be made before the drawing
-- starts rather than after.
local function chain_opacity(node, stop)
  local o = node:get("opacity") or 1
  local p = node.initial and node.initial.parent
  while p and p ~= stop do
    o = o * (p:get("opacity") or 1)
    p = p.initial and p.initial.parent
  end
  return o
end

-- walk the parent chain root-first so a group's transform wraps its children.
-- Optional `stop` (exclusive) lets an fx canvas draw descendants in local space.
local function parent_chain(node, stop)
  local chain, p = {}, node.initial and node.initial.parent
  while p and p ~= stop do
    table.insert(chain, 1, p)
    p = p.initial and p.initial.parent
  end
  return chain
end

-- kinds that never paint (world children); hoisted so the scene block sees it
-- Nodes the frame never contains. Sound is the load-bearing entry: an audio clip is
-- resolved before the render and mixed by ffmpeg at encode (canon 1.5), so it draws
-- nothing -- but if it is not named here it is a node the scene does not own, which
-- takes the whole composition off the direct path and flushes the builder once per
-- clip. A ten minute edit with seventy sounds paid for all seventy.
local SKIP_DRAW = { camera = true, light = true, mesh = true,
  audio = true, tts = true, sfx = true, music = true, marker = true }

local function fx_ancestor(node)
  local p = node.initial and node.initial.parent
  while p do
    if p.kind == "fx" then return p end
    p = p.initial and p.initial.parent
  end
end

local paint_node, paint_layer

-- ---- composition: clips, tracks and isolated groups paint as layers (core/runtime/layers.lua) ----
local layers = require("layers")
local plan_of, within, live = layers.plan, layers.within, layers.live
local opacity_from, fx_paints = layers.opacity_from, layers.fx_paints
P.plan = plan_of

local function paint_any(comp, node, t)
  local plan = comp._plan
  if plan and plan.layer[node] then return paint_layer(comp, node, t) end
  return paint_node(comp, node, t)
end

-- ---- moonsplice-scene (MOONSPLICE_SCENE=1): text goes to the vello rasterizer ----
P.scene = scene
local scene_builder = scene.enabled and scene.new_builder() or nil

-- compose love's translate/rotate/scale chain into one absolute affine
local function affine_mul(m, n)
  return {
    m[1] * n[1] + m[3] * n[2], m[2] * n[1] + m[4] * n[2],
    m[1] * n[3] + m[3] * n[4], m[2] * n[3] + m[4] * n[4],
    m[1] * n[5] + m[3] * n[6] + m[5], m[2] * n[5] + m[4] * n[6] + m[6],
  }
end
local function node_affine(chain, node)
  local m = { 1, 0, 0, 1, 0, 0 }
  local function trs(n)
    -- a push, slide or zoom moves the clip in its track's space before its own transform
    local tr = n._tr
    if tr and (tr.dx ~= 0 or tr.dy ~= 0 or tr.s ~= 1) then
      m = affine_mul(m, { tr.s, 0, 0, tr.s, tr.dx + tr.cx - tr.s * tr.cx, tr.dy + tr.cy - tr.s * tr.cy })
    end
    local x, y = n:get("x") or 0, n:get("y") or 0
    local r = n:get("rotation") or 0
    local s = n:get("scale") or 1
    local c, sn = math.cos(r), math.sin(r)
    m = affine_mul(m, { c * s, sn * s, -sn * s, c * s, x, y })
  end
  for _, p in ipairs(chain) do
    trs(p)
    local o = P.fx_offset and P.fx_offset[p]
    if o then m = affine_mul(m, { 1, 0, 0, 1, o[1], o[2] }) end
  end
  if node then trs(node) end
  return m
end

-- flush pending scene commands into one full-frame premultiplied layer
local scene_text, scene_shape, scene_image, scene_vector
local scene_data, scene_img, scene_w, scene_h
function P.scene_flush(comp)
  if not scene_builder or not scene_builder.pending then return end
  -- The preview draws the composition at the size of the pane (`P.preview_scale`, set by the
  -- frame server). The rasterizer takes the scale, so the pixels that are never going to be seen
  -- are never made -- and the buffer this flushes through is the size of the canvas, not the
  -- size of the composition.
  local s = P.preview_scale or 1
  local w = math.max(1, math.floor(comp.width * s + 0.5))
  local h = math.max(1, math.floor(comp.height * s + 0.5))
  if not scene_data or scene_w ~= w or scene_h ~= h then
    if scene_data then scene_img:release() end
    scene_data = love.image.newImageData(w, h, "rgba8")
    scene_img = love.graphics.newImage(scene_data)
    scene_w, scene_h = w, h
  end
  local t0 = love.timer.getTime()
  scene.render(scene_builder, w, h, scene_data:getFFIPointer(), scene_data:getSize(), s)
  P.scene_time = (P.scene_time or 0) + (love.timer.getTime() - t0)
  P.scene_flushes = (P.scene_flushes or 0) + 1
  scene_img:replacePixels(scene_data)
  local g = love.graphics
  g.push("all")
  -- The flushed image is already in the coordinates of the canvas being drawn into, so it goes
  -- down at the origin of that canvas rather than under whatever transform a node left behind.
  g.origin()
  g.setColor(1, 1, 1, 1)
  g.setBlendMode("alpha", "premultiplied")
  g.draw(scene_img, 0, 0)
  g.pop()
  scene_builder:reset()
end

-- which nodes the scene crate paints today (grows one kind at a time)
local SCENE_KINDS = { displace = true, draw = true, spritesheet = true, particles = true, chart = true, ornament = true, spine = true,
  text = true, rect = true, surface = true, circle = true, flex = true, group = true, kinetic = true,
  image = true, svg = true, page = true, vector = true, html = true, world = true, fx = true, video = true, lottie = true,
  clip = true, track = true, precomp = true }
local EFFECT_DEFAULTS = { effect_blur = 0, effect_brightness = 1, effect_contrast = 1, effect_saturate = 1,
  effect_grayscale = 0, effect_sepia = 0, effect_invert = 0, effect_opacity = 1, effect_hue_rotate = 0 }
local SCENE_BLENDS = scene.BLEND
local PERSP_KINDS = { rect = true, surface = true, image = true, svg = true, page = true, video = true }
local function scene_owns(node)
  if not SCENE_KINDS[node.kind] then return false end
  local i = node.initial
  -- a perspective plane is flat content warped through a camera: anything that has a flat face
  if i.perspective and not PERSP_KINDS[node.kind] then return false end
  if i.blend and not SCENE_BLENDS[i.blend] then return false end
  return true
end
P.scene_owns = scene_owns

scene_shape = function(node, opacity, chain)
  scene_builder:transform(node_affine(chain, node))
  local c = node:get("color")
  if type(c) == "string" then c = require("moonsplice.color").parse(c) end
  c = c or { 1, 1, 1, 1 }
  local cc = { c[1], c[2], c[3], (c[4] or 1) * opacity }
  if node.kind == "circle" then
    scene_builder:circle(0, 0, node:get("r"), cc)
  else
    local w, h = node:get("w"), node:get("h")
    local ox, oy = anchor_offset(node, w, h)
    scene_builder:rect(ox, oy, w, h, cc, node:get("rx") or 0)
  end
end


local scene_imgdata = {}
scene_image = function(node, opacity, chain)
  local path = node.file
  if not scene_imgdata[path] then
    local f = assert(_MOONSPLICE_IOOPEN(path, "rb"), "moonsplice: cannot read " .. path)
    local bytes = f:read("*a"); f:close()
    scene_imgdata[path] = love.image.newImageData(love.filesystem.newFileData(bytes, "f.png"))
  end
  local id = scene.image_id(path, scene_imgdata[path])
  local w, h = node:get("w"), node:get("h")
  local ox, oy = anchor_offset(node, w, h)
  scene_builder:transform(node_affine(chain, node))
  scene_builder:image(id, ox, oy, w, h, node:get("rx") or 0, opacity)
end

scene_vector = function(node, opacity, chain, t)
  local i = node.initial
  local ox, oy = anchor_offset(node, i.w, i.h)
  local m = node_affine(chain, node)
  -- shift into the node box so draw(v, t) keeps its 0..w/0..h coordinates
  m = affine_mul(m, { 1, 0, 0, 1, ox, oy })
  scene_builder:transform(m)
  scene_builder:clip_push(0, 0, i.w, i.h, 0)
  scene_builder.grain_box = { 0, 0, i.w, i.h }
  i.draw(scene_builder, t, node)
  scene_builder.grain_box = nil
  scene_builder:clip_pop()
  -- node opacity < 1 is applied by scene_node as an opacity layer around this call
end

local function comp_render_fps(node) return P.render_fps or 30 end
local function scene_video(node, opacity, chain, t)
  local i = node.initial
  local rel = t - i.from
  if rel < 0 or rel >= i.duration then return true end
  local w, h = i.w, i.h
  local ox, oy = anchor_offset(node, w, h)
  local id
  if node.dec then
    local d = node.dec
    local decode = require("decode")
    if not node.vrgba then node.vrgba = love.image.newImageData(w, h, "rgba8") end
    if d.mode == "yuv" then
      if not node.ydata then
        node.ydata = love.image.newImageData(d.w, d.h, "r8")
        node.udata = love.image.newImageData(d.w / 2, d.h / 2, "r8")
        node.vdata = love.image.newImageData(d.w / 2, d.h / 2, "r8")
        node.vfull = love.image.newImageData(d.w, d.h, "rgba8")
      end
      decode.frame_yuv(d, i.media_start + rel,
        node.ydata:getFFIPointer(), node.ydata:getSize(),
        node.udata:getFFIPointer(), node.udata:getSize(),
        node.vdata:getFFIPointer(), node.vdata:getSize())
      decode.yuv_to_rgba(node.ydata:getFFIPointer(), node.udata:getFFIPointer(), node.vdata:getFFIPointer(),
        d.w, d.h, d.full_range, node.vfull:getFFIPointer(), node.vfull:getSize())
      -- cover-crop the decoded frame into the node box (same rule as the GPU quad)
      local sc = math.max(w / d.w, h / d.h)
      local cw, ch = w / sc, h / sc
      local sx, sy = math.floor((d.w - cw) / 2), math.floor((d.h - ch) / 2)
      id = scene.image_slot(node, node.vfull, true, true)
      scene_builder:transform(node_affine(chain, node))
      scene_builder:clip_push(ox, oy, w, h, node:get("rx") or 0)
      scene_builder:image(id, ox - sx * sc, oy - sy * sc, d.w * sc, d.h * sc, 0, opacity)
      scene_builder:clip_pop()
      return true
    else
      decode.frame_rgba(d, i.media_start + rel, node.vrgba:getFFIPointer(), node.vrgba:getSize())
      id = scene.image_slot(node, node.vrgba, true, false)
    end
  elseif node.frame_count and node.frame_count > 0 then
    local idx = math.min(math.floor(rel * comp_render_fps(node) ) + 1, node.frame_count)
    local path = ("%s/%05d.jpg"):format(node.frames_dir, idx)
    if node.vpath ~= path then
      local f = assert(_MOONSPLICE_IOOPEN(path, "rb"), "moonsplice: cannot read " .. path)
      local bytes = f:read("*a"); f:close()
      node.vframe = love.image.newImageData(love.filesystem.newFileData(bytes, "f.jpg"))
      node.vpath = path
    end
    id = scene.image_slot(node, node.vframe, true, false)
  else
    return true
  end
  scene_builder:transform(node_affine(chain, node))
  scene_builder:image(id, ox, oy, w, h, node:get("rx") or 0, opacity)
  return true
end

-- Seconds into the node become a Lottie frame the way the file counts them: from its first
-- frame at its own rate, looping over its length or held at its ends.
local function scene_lottie(node, opacity, chain, t)
  local i = node.initial
  local rel = t - i.from
  if rel < 0 or rel >= i.duration then return end
  local l = scene.lottie(node.file)
  local len = (l.last - l.first) / math.max(l.fps, 1)
  local tl = i.media_start + rel * (i.speed or 1)
  if i.loop then tl = tl % len else tl = math.min(math.max(tl, 0), len) end
  local frame = math.min(l.first + tl * l.fps, l.last - 0.001)
  local ox, oy = anchor_offset(node, i.w, i.h)
  scene_builder:transform(node_affine(chain, node))
  scene_builder:lottie(l.id, frame, ox, oy, i.w, i.h, opacity)
end

local function scene_html(node, opacity, chain)
  local html = require("html")
  if not html.available then return false end
  local i = node.initial
  if not node.htmldata then
    node.htmldata = love.image.newImageData(i.w, i.h, "rgba8")
    node.html_key = nil
  end
  local progress = node:get("progress") or 0
  local progress_key = string.format("%.2f", progress)
  local changed = node.html_key ~= progress_key
  if changed then
    local markup = i.html:gsub("{{progress_int}}", tostring(math.floor(progress + 0.5)))
      :gsub("{{progress}}", progress_key)
    html.render(markup, i.w, i.h, 1.0, node.htmldata:getFFIPointer(), node.htmldata:getSize())
    node.html_key = progress_key
  end
  local id = scene.image_slot(node, node.htmldata, changed, true) -- blitz output is premultiplied
  local ox, oy = anchor_offset(node, i.w, i.h)
  scene_builder:transform(node_affine(chain, node))
  scene_builder:image(id, ox, oy, i.w, i.h, 0, opacity)
  return true
end

-- node-local box {x, y, w, h} (anchor applied) for effect bounds
local function node_box(node)
  local i = node.initial
  if node.kind == "circle" then local r = node:get("r") or 0; return { -r, -r, 2 * r, 2 * r } end
  local w, h = node:get("w") or i.w or 0, node:get("h") or i.h or 0
  if node.kind == "text" then
    local size = node:get("size") or 32
    w, h = scene.measure(scene.font_id(node:get("font")), size, (node:get("text") or i.text or ""):gsub("{[^}]*}", ""),
      node:get("tracking") or 0, i.wrap or 0, i.leading or 0)
  end
  local ox, oy = anchor_offset(node, w, h)
  return { ox, oy, w, h }
end

-- one scene-owned node: clip / blend / shadow / effect layers around its paint
local function scene_node(node, opacity, chain, t, noblend)
  local i = node.initial
  local pops = 0
  if i.clip_node then
    local clipn = i.clip_node
    local cx, cy = clipn:get("x") or 0, clipn:get("y") or 0
    local cw, ch = clipn:get("w") or 0, clipn:get("h") or 0
    local crx = clipn:get("rx") or 0
    if clipn.initial.anchor == "center" then cx, cy = cx - cw / 2, cy - ch / 2 end
    if crx > 0 then crx = math.min(crx, cw / 2, ch / 2) end
    scene_builder:transform(node_affine(chain, nil))
    if i.clip_invert then
      scene_builder:clip_push_outside(cx, cy, math.max(cw, 0), math.max(ch, 0), crx)
    else
      scene_builder:clip_push(cx, cy, math.max(cw, 0), math.max(ch, 0), crx)
    end
    pops = pops + 1
  end
  if i.blend and i.blend ~= "alpha" and not noblend then scene_builder:blend_push(i.blend); pops = pops + 1 end
  if i.shadow then
    local sw, sh2 = node:get("w") or 0, node:get("h") or 0
    if sw > 0 and sh2 > 0 then
      scene_builder:transform(node_affine(chain, node))
      local ox, oy = anchor_offset(node, sw, sh2)
      scene_builder:filter_push(0, (i.shadow.blur or 40) / 2)
      scene_builder:rect(ox, oy + (i.shadow.dy or 10), sw, sh2, { 0, 0, 0, (i.shadow.alpha or 0.3) * opacity }, node:get("rx") or 0)
      scene_builder:pop()
    end
  end
  local has_fx = false
  for key, default in pairs(EFFECT_DEFAULTS) do
    local v = node:get(key)
    if v ~= nil and v ~= default then has_fx = true end
  end
  if has_fx then
    local function e(k) local v = node:get(k); if v == nil then v = EFFECT_DEFAULTS[k] end; return v end
    scene_builder:transform(node_affine(chain, node))
    scene_builder:fx_push(e("effect_blur"), e("effect_brightness"), e("effect_contrast"), e("effect_saturate"),
      e("effect_grayscale"), e("effect_sepia"), e("effect_invert"), e("effect_opacity"), e("effect_hue_rotate"), node_box(node))
    pops = pops + 1
  end
  if node.kind == "vector" and opacity < 1 then scene_builder:opacity_push(opacity); pops = pops + 1 end
  if i.perspective then
    -- the content below paints the flat page at (ox, oy, w, h) in node space; 114 warps it
    local w, h = node:get("w") or i.w or 0, node:get("h") or i.h or 0
    local p = w > 0 and h > 0 and require("persp").params(node, w, h)
    if not p then for _ = 1, pops do scene_builder:pop() end return true end
    local ox, oy = anchor_offset(node, w, h)
    scene_builder:transform(node_affine(chain, node))
    scene_builder:persp_push(p, ox, oy, w, h)
    pops = pops + 1
  end
  local k = node.kind
  local ok = true
  if k == "text" then scene_text(node, opacity, chain)
  elseif k == "rect" or k == "surface" or k == "circle" or k == "flex" then
    if k ~= "flex" or node:get("color") then scene_shape(node, opacity, chain) end
  elseif k == "image" or k == "svg" or k == "page" then scene_image(node, opacity, chain)
  elseif k == "vector" then scene_vector(node, opacity, chain, t)
  elseif k == "html" then ok = scene_html(node, opacity, chain)
  elseif k == "video" then ok = scene_video(node, opacity, chain, t)
  elseif k == "lottie" then scene_lottie(node, opacity, chain, t)
  elseif k == "displace" then
    local w, h = node:get("w"), node:get("h")
    local ox, oy = anchor_offset(node, w, h)
    scene_builder:transform(node_affine(chain, node))
    scene_builder:displace_push(ox, oy, w, h, i.cols or 24, i.rows or 16, t, node:get("amp") or 14, node:get("freq") or 1)
    if node.file then
      local img = require("sceneg").image(node.file)
      scene_builder:image(img.scene_id, ox, oy, w, h, 0, opacity)
    else
      local size, fpath = i.size or 72, i.font
      local fid = scene.font_id(fpath)
      local text = i.text or ""
      local tw, th = scene.measure(fid, size, text)
      local c = node:get("color") or { 1, 1, 1, 1 }
      if type(c) == "string" then c = require("moonsplice.color").parse(c) end
      scene_builder:text(fid, size, ox + (w - tw) / 2, oy + (h - th) / 2,
        { { text = text, color = { c[1], c[2], c[3], 1 } } }, { opacity = opacity })
    end
    scene_builder:pop()
  elseif DRAW_KIND[k] then
    local sg = require("sceneg")
    DRAW_KIND[k](node, sg.new(scene_builder, node_affine(chain, node), sg.image), t, opacity)
  else ok = false end
  for _ = 1, pops do scene_builder:pop() end
  return ok
end

scene_text = function(node, opacity, chain)
  local size = node:get("size") or 32
  local fontpath = node:get("font")
  local fid = scene.font_id(fontpath)
  local text = node:get("text") or node.initial.text or ""
  local wrap = node.initial.wrap
  local reveal = node:get("reveal")
  local runs
  if wrap or text:find("{", 1, true) or reveal ~= nil then
    local rich = require("richtext")
    runs = rich.parse(text, node:get("color"))
    if reveal ~= nil then runs = rich.reveal(runs, reveal) end
  else
    runs = { { text = text, color = node:get("color") } }
  end
  local leading = node.initial.leading
  local tw, th
  if node:get("anchor") == "center" then
    local plain = {}
    for _, r in ipairs(runs) do plain[#plain + 1] = r.text end
    tw, th = scene.measure(fid, size, table.concat(plain), node:get("tracking") or 0, wrap or 0, leading or 0)
  end
  local ox, oy = 0, 0
  if tw then ox, oy = -tw / 2, -th / 2 end
  local outline = node:get("outline") or node.initial.outline
  local weight = node:get("weight") or 0
  scene_builder:transform(node_affine(chain, node))
  local tracking = node:get("tracking") or 0
  scene_builder:text(fid, size, ox, oy, runs, {
    wrap = wrap, leading = leading, opacity = opacity, ls = tracking,
    outline = (outline and outline > 0) and outline * size * 0.04 or 0,
    outline_color = node.initial.outline_color,
    embolden = weight > 0 and weight * size * 0.03 or 0,
  })
end
-- ----------------------------------------------------------------------------

-- fx passes the rasterizer runs itself (scene/src/fx.rs); worley and shadertoy
-- stay GLSL and go through the canvas + slot path below.
local CHAIN_PROP = { bloom = "fx_bloom", glow = "fx_glow", blur = "fx_blur", vignette = "fx_vignette",
  chroma = "fx_chroma", chromasep = "fx_chroma", grain = "fx_grain", tonemap = "fx_tonemap",
  aces = "fx_tonemap", pixelate = "fx_pixelate", posterize = "fx_posterize", filmgrain = "fx_grain",
  kawase = "fx_blur", worley = "fx_worley" }
local CHAIN_DEFAULT = { bloom = 0.45, glow = 0.4, blur = 4, vignette = 0.35, chroma = 1.5, chromasep = 1.5,
  grain = 0.08, tonemap = 1, aces = 1, pixelate = 0.45, posterize = 0.55, filmgrain = 0.08, kawase = 2, worley = 0.45 }
local function scene_chain(comp, node, t)
  if not scene_builder then return nil end
  local passes = {}
  for _, name in ipairs(node.initial.chain or { "bloom", "vignette" }) do
    if name == "shadertoy" then
      -- the comp's own GLSL runs on the GPU (moonsplice-render); no source, no pass, as before
      if node.initial.shadertoy then passes[#passes + 1] = { src = node.initial.shadertoy, t = t } end
      goto next
    end
    local id = scene.CHAIN[name]
    if not id then return nil end
    local v = node:get(CHAIN_PROP[name])
    if v == nil then v = CHAIN_DEFAULT[name] end
    passes[#passes + 1] = { id, v, t }
    ::next::
  end
  for _, child in ipairs(comp.nodes) do
    if fx_ancestor(child) == node and not SKIP_DRAW[child.kind] and not scene_owns(child) then return nil end
  end
  return passes
end

local function apply_fx(comp, node, t)
  local g = love.graphics
  local opacity = node:get("opacity")
  local chain = parent_chain(node)
  for k = opacity_from(comp, chain), #chain do opacity = opacity * (chain[k]:get("opacity") or 1) end
  if opacity <= 0 then return end
  local w = math.floor(node:get("w") or 0)
  local h = math.floor(node:get("h") or 0)
  if w < 1 or h < 1 then return end
  local passes = scene_chain(comp, node, t)
  if passes then
    -- native chain: children stream into a scratch frame the size of the fx
    -- box, the passes run on the CPU, the result composites in z-order
    local ox, oy = anchor_offset(node, w, h)
    scene_builder:transform(node_affine(chain, node))
    scene_builder:chain_push(passes, { ox, oy, w, h })
    P.fx_offset = P.fx_offset or {}
    P.fx_offset[node] = { ox, oy }
    for _, child in ipairs(comp.nodes) do
      if fx_ancestor(child) == node and fx_paints(comp, child, node) then paint_any(comp, child, t) end
    end
    P.fx_offset[node] = nil
    scene_builder:pop()
    return
  end
  local fxmod = require("fx")
  local a, b, c = fxmod.canvases(node, w, h)
  local prev = g.getCanvas()
  local pc, pv = g.getStencilTest()
  g.push("all")
  g.origin()
  g.setStencilTest()
  g.setCanvas({ a, stencil = true })
  g.clear(0, 0, 0, 0)
  for _, child in ipairs(comp.nodes) do
    if fx_ancestor(child) == node then
      paint_node(comp, child, t, node)
    end
  end
  g.setCanvas(prev and { prev, stencil = true } or nil)
  g.pop()
  if pc then g.setStencilTest(pc, pv) end
  local out = fxmod.apply(node, a, b, c, t, w, h)
  if scene_builder then
    -- scene mode: the processed canvas becomes an image slot in the one frame
    local data = g.readbackTexture and g.readbackTexture(out) or out:newImageData()
    local id = scene.image_slot(node, data, true, true)
    data:release()
    local ox, oy = anchor_offset(node, w, h)
    scene_builder:transform(node_affine(chain, node))
    scene_builder:image(id, ox, oy, w, h, 0, opacity)
    return
  end
  g.push("all")
  for _, p in ipairs(chain) do
    g.translate(p:get("x") or 0, p:get("y") or 0)
    g.rotate(p:get("rotation") or 0)
    local ps = p:get("scale") or 1
    g.scale(ps, ps)
  end
  g.translate(node:get("x") or 0, node:get("y") or 0)
  g.rotate(node:get("rotation") or 0)
  local s = node:get("scale") or 1
  g.scale(s, s)
  local ox, oy = anchor_offset(node, w, h)
  local bm, ba = g.getBlendMode()
  g.setBlendMode("alpha", "premultiplied")
  setcolor({ 1, 1, 1, 1 }, opacity)
  g.draw(out, ox, oy)
  g.setBlendMode(bm, ba)
  g.pop()
end


-- What an offline thing looks like: a flat slate, the same one every time.
--
-- Deliberately not black and deliberately not nothing. A hole in the frame reads as a bug in the
-- app; a slate reads as a thing that is not there, which is what it is. Nothing is written on it
-- -- which thing and why is a sentence, and a sentence belongs in the window where it can be
-- read and acted on, not burnt into a picture that also gets exported.
local OFFLINE_SLATE = { 0.13, 0.13, 0.15 }

local function paint_offline(node, t, stop)
  local i = node.initial
  -- Still only while it is on screen: offline or not, a clip that has not started draws nothing.
  if i.from and i.duration and (t < i.from or t >= i.from + i.duration) then return end
  local w = node:get("w") or i.w or 0
  local h = node:get("h") or i.h or 0
  -- A sound has no box, and neither has anything else that was never going to paint.
  if not (w > 0 and h > 0) then return end
  local chain = parent_chain(node, stop)
  local opacity = node:get("opacity") or 1
  for _, p in ipairs(chain) do opacity = opacity * (p:get("opacity") or 1) end
  if opacity <= 0 then return end
  local ox, oy = anchor_offset(node, w, h)
  local c = { OFFLINE_SLATE[1], OFFLINE_SLATE[2], OFFLINE_SLATE[3], opacity }
  -- Through the same door its picture would have gone through, so the slate lands in the same
  -- place in the draw order that the clip did.
  if scene_builder and not stop and scene_owns(node) then
    scene_builder:transform(node_affine(chain, node))
    scene_builder:rect(ox, oy, w, h, c, node:get("rx") or 0)
    return
  end
  local g = love.graphics
  g.push("all")
  for _, p in ipairs(chain) do
    g.translate(p:get("x") or 0, p:get("y") or 0)
    g.rotate(p:get("rotation") or 0)
    local ps = p:get("scale") or 1
    g.scale(ps, ps)
  end
  g.translate(node:get("x") or 0, node:get("y") or 0)
  g.rotate(node:get("rotation") or 0)
  local ns = node:get("scale") or 1
  g.scale(ns, ns)
  g.setColor(c)
  g.rectangle("fill", ox, oy, w, h)
  g.pop()
end

paint_node = function(comp, node, t, stop, flags)
  local g = love.graphics
  -- a clip that is not playing paints nothing, and what is under one is drawn at its local time
  if not live(node) then return end
  if node.clock then t = node.clock._lt end
  -- Something this node needed is not on the disk. It keeps its place, its size and its moment,
  -- so the edit around it is exactly the edit it was, and it paints a slate instead of its
  -- picture. `core/runtime/resolve.lua` decides that and says why.
  if node.offline then
    paint_offline(node, t, stop)
    return
  end
  if node.kind == "fx" and not stop then
    apply_fx(comp, node, t)
    return
  end
  if scene_builder and not stop and node.initial.perspective then
    -- A perspective slot is the most expensive thing a frame can contain: a canvas the size
    -- of the composition, cleared, drawn into, and read back off the GPU. A card at zero
    -- opacity puts nothing in the picture, so it is not worth that -- and on a ten minute
    -- edit where three cards appear for twelve seconds, it was being paid on all eighteen
    -- thousand frames. Measured there: 21 ms of a 45 ms frame, for three invisible cards.
    if chain_opacity(node) <= 0 then return end
  end
  local opacity = node:get("opacity")
    -- inherited opacity: a group fading takes its children with it
    local chain = parent_chain(node, stop)
    for k = opacity_from(comp, chain), #chain do opacity = opacity * (chain[k]:get("opacity") or 1) end
    if opacity > 0 and node.kind ~= "group" and node.kind ~= "kinetic" and node.kind ~= "fx"
      and node.kind ~= "camera" and node.kind ~= "light" and node.kind ~= "mesh"
      and node.kind ~= "clip" and node.kind ~= "track" and node.kind ~= "precomp" then
      -- Blend, shader, canvas, and stencil state are node-local. Transform-only
      -- pushes let a `screen` node leak into later text, corrupting glyph atlas
      -- blending into solid character rectangles.
      g.push("all")
      for _, p in ipairs(chain) do
        g.translate(p:get("x") or 0, p:get("y") or 0)
        g.rotate(p:get("rotation") or 0)
        local ps = p:get("scale") or 1
        g.scale(ps, ps)
      end
      -- clip_node: stencil this node to another node's live rect (same parent
      -- space). Used for reveal wipes and "text inverts under a sliding pill".
      local clipn = node.initial.clip_node
      local clipped = false
      if clipn then
        local cx, cy = clipn:get("x") or 0, clipn:get("y") or 0
        local cw, ch = clipn:get("w") or 0, clipn:get("h") or 0
        local crx = clipn:get("rx") or 0
        if clipn.initial.anchor == "center" then cx, cy = cx - cw / 2, cy - ch / 2 end
        -- Always stencil, even at zero area: an empty clip must reveal NOTHING.
        -- Skipping it here would leak the whole node on the first frame of a wipe.
        clipped = true
        if crx > 0 then crx = math.min(crx, cw / 2, ch / 2) end
        love.graphics.stencil(function()
          if cw > 0 and ch > 0 then
            love.graphics.rectangle("fill", cx, cy, cw, ch, crx, crx)
          end
        end, "replace", 1, false)
        love.graphics.setStencilTest(node.initial.clip_invert and "equal" or "greater", 0)
      end
      g.translate(node:get("x") or 0, node:get("y") or 0)
      g.rotate(node:get("rotation"))
      local s = node:get("scale")
      g.scale(s, s)
      set_node_blend(node)

      -- soft drop shadow beneath this node, drawn before its own paint
      local shq = node.initial.shadow
      if shq then
        local sw = (node:get("w") or 0)
        local sh2 = (node:get("h") or 0)
        if sw > 0 and sh2 > 0 then
          local sc = shadow_canvas(math.floor(sw), math.floor(sh2),
            math.floor(node:get("rx") or 0), shq.blur or 40)
          local ox, oy = anchor_offset(node, sw, sh2)
          local bm, ba = love.graphics.getBlendMode()
          love.graphics.setBlendMode("alpha", "premultiplied")
          love.graphics.setColor(0, 0, 0, (shq.alpha or 0.3) * opacity)
          love.graphics.draw(sc.canvas, ox - sc.pad, oy - sc.pad + (shq.dy or 10))
          love.graphics.setColor(1, 1, 1, 1)
          love.graphics.setBlendMode(bm, ba)
        end
      end
      if scene_builder and not stop and scene_owns(node) and scene_node(node, opacity, chain, t, flags and flags.noblend) then
        -- painted by moonsplice-scene
      elseif node.kind == "flex" then
        if node:get("color") then
          setcolor(node:get("color"), opacity)
          g.rectangle("fill", 0, 0, node:get("w"), node:get("h"), node:get("rx") or 0)
        end
      elseif node.kind == "rect" or node.kind == "surface" then
        local w, h = node:get("w"), node:get("h")
        local ox, oy = anchor_offset(node, w, h)
        local rx = node:get("rx") or 0
        if node.initial.perspective then
          local col = node:get("color")
          draw_surface(node, w, h, opacity, ox, oy, rx, function(dx, dy)
            setcolor(col, 1)
            g.rectangle("fill", dx, dy, w, h)
          end)
        else
          setcolor(node:get("color"), opacity)
          g.rectangle("fill", ox, oy, w, h, rx, rx)
        end
      elseif node.kind == "circle" then
        setcolor(node:get("color"), opacity)
        g.circle("fill", 0, 0, node:get("r"))
      elseif node.kind == "text" then
        local f = font(node:get("size") or 32, node:get("font"))
        g.setFont(f)
        local text = node:get("text") or node.initial.text or ""
        local wrap = node.initial.wrap
        local reveal = node:get("reveal")
        local tagged = text:find("{", 1, true)
        if wrap or tagged or reveal ~= nil then
          local rich = require("richtext")
          local runs = rich.parse(text, node:get("color"))
          if reveal ~= nil then runs = rich.reveal(runs, reveal) end
          local lines = rich.wrap(f, runs, wrap)
          local tw, th = rich.measure(f, lines, node.initial.leading)
          local ox, oy = anchor_offset(node, tw, th)
          rich.draw(g, f, lines, node.initial.leading, opacity, ox, oy)
        else
          local ox, oy = anchor_offset(node, f:getWidth(text), f:getHeight())
          local outline = node:get("outline") or node.initial.outline
          if outline and outline > 0 then
            local tw, th = f:getWidth(text), f:getHeight()
            local key = text .. "|" .. tostring(node:get("size"))
            if node.sdf_key ~= key then
              local pad = 12
              local canvas = love.graphics.newCanvas(math.ceil(tw + pad * 2), math.ceil(th + pad * 2))
              local prev = love.graphics.getCanvas()
              love.graphics.push("all")
              love.graphics.origin()
              love.graphics.setCanvas(canvas)
              love.graphics.clear(0, 0, 0, 0)
              love.graphics.setFont(f)
              love.graphics.setColor(1, 1, 1, 1)
              love.graphics.print(text, pad, pad)
              love.graphics.setCanvas(prev)
              love.graphics.pop()
              node.sdf_canvas, node.sdf_key, node.sdf_pad = canvas, key, pad
            end
            local sh = get_sdf()
            local fill = node:get("color") or { 1, 1, 1, 1 }
            local stroke = node.initial.outline_color or { 0, 0, 0, 1 }
            sh:send("weight", node:get("weight") or 0)
            sh:send("outline", outline)
            sh:send("fill", { fill[1], fill[2], fill[3], (fill[4] or 1) * opacity })
            sh:send("stroke", { stroke[1], stroke[2], stroke[3], (stroke[4] or 1) * opacity })
            g.setShader(sh)
            g.setColor(1, 1, 1, 1)
            g.draw(node.sdf_canvas, ox - node.sdf_pad, oy - node.sdf_pad)
            g.setShader()
          else
            setcolor(node:get("color"), opacity)
            g.print(text, ox, oy)
          end
        end
      elseif node.kind == "video" then
        local i = node.initial
        local rel = t - i.from
        if rel >= 0 and rel < i.duration then
          local ox, oy = anchor_offset(node, i.w, i.h)
          local rx = node:get("rx") or 0
          -- Each decode path only supplies a `paint(dx, dy)`; draw_surface owns
          -- rounding, opacity and the optional 3D camera. Perspective therefore
          -- works on every source (yuv, rgba, extracted frames) for free.
          local paint
          if node.dec and node.dec.mode == "yuv" then
            local d = node.dec
            if not node.ydata then
              node.ydata = love.image.newImageData(d.w, d.h, "r8")
              node.udata = love.image.newImageData(d.w / 2, d.h / 2, "r8")
              node.vdata = love.image.newImageData(d.w / 2, d.h / 2, "r8")
              node.yimg = love.graphics.newImage(node.ydata)
              node.uimg = love.graphics.newImage(node.udata)
              node.vimg = love.graphics.newImage(node.vdata)
              node.yimg:setFilter("linear", "linear")
              node.uimg:setFilter("linear", "linear")
              node.vimg:setFilter("linear", "linear")
              -- cover-crop region in source space; GPU scales it to node w×h
              local sc = math.max(i.w / d.w, i.h / d.h)
              local cw, ch = i.w / sc, i.h / sc
              node.quad = love.graphics.newQuad((d.w - cw) / 2, (d.h - ch) / 2, cw, ch, d.w, d.h)
              node.qscale = { i.w / cw, i.h / ch }
            end
            local decode = require("decode")
            decode.frame_yuv(d, i.media_start + rel,
              node.ydata:getFFIPointer(), node.ydata:getSize(),
              node.udata:getFFIPointer(), node.udata:getSize(),
              node.vdata:getFFIPointer(), node.vdata:getSize())
            node.yimg:replacePixels(node.ydata)
            node.uimg:replacePixels(node.udata)
            node.vimg:replacePixels(node.vdata)
            paint = function(dx, dy)
              local sh = get_yuv_shader()
              g.setShader(sh)
              sh:send("u_plane", node.uimg)
              sh:send("v_plane", node.vimg)
              sh:send("full_range", d.full_range and 1.0 or 0.0)
              g.draw(node.yimg, node.quad, dx, dy, 0, node.qscale[1], node.qscale[2])
              g.setShader()
            end
          elseif node.dec then
            -- rgba fallback (non-yuv420 sources, e.g. lossless 4:4:4 captures)
            if not node.imgdata then
              node.imgdata = love.image.newImageData(i.w, i.h, "rgba8")
              node.img = love.graphics.newImage(node.imgdata)
            end
            local decode = require("decode")
            decode.frame_rgba(node.dec, i.media_start + rel,
              node.imgdata:getFFIPointer(), node.imgdata:getSize())
            node.img:replacePixels(node.imgdata)
            paint = function(dx, dy) g.draw(node.img, dx, dy) end
          elseif node.frame_count and node.frame_count > 0 then
            local idx = math.min(math.floor(rel * comp.render_fps) + 1, node.frame_count)
            local img = node_image(node, ("%s/%05d.jpg"):format(node.frames_dir, idx))
            paint = function(dx, dy) g.draw(img, dx, dy) end
          end
          if paint then draw_surface(node, i.w, i.h, opacity, ox, oy, rx, paint) end
        end
      elseif node.kind == "vector" then
        local vector = require("vector")
        if vector.available then
          local i = node.initial
          if not node.vecdata then
            node.vecdata = love.image.newImageData(i.w, i.h, "rgba8")
            node.vecimg = love.graphics.newImage(node.vecdata)
            node.vecbuilder = vector.new_builder()
          end
          node.vecbuilder:reset()
          i.draw(node.vecbuilder, t, node)
          vector.render(node.vecbuilder, i.w, i.h,
            node.vecdata:getFFIPointer(), node.vecdata:getSize())
          require("effects").apply(node, node.vecdata, i.w, i.h)
          node.vecimg:replacePixels(node.vecdata)
          setcolor({ 1, 1, 1, 1 }, opacity)
          love.graphics.setBlendMode("alpha", "premultiplied")
          local ox, oy = anchor_offset(node, i.w, i.h)
          g.draw(node.vecimg, ox, oy)
          love.graphics.setBlendMode("alpha", "alphamultiply")
        end
      elseif node.kind == "world" and require("worldbevy").available then
        -- Bevy draws the world (render/src/world.rs); MOONSPLICE_WORLD=scene3d keeps the old one
        local i = node.initial
        local w, h = math.floor(node:get("w") or i.w or 0), math.floor(node:get("h") or i.h or 0)
        if w >= 1 and h >= 1 then
          if not node.worlddata or node.worldsize ~= w * 65536 + h then
            node.worlddata = love.image.newImageData(w, h, "rgba8")
            node.worldsize = w * 65536 + h
          end
          require("worldbevy").render(comp, node, t, node.worlddata, w, h)
          local ox, oy = anchor_offset(node, w, h)
          local id = scene.image_slot(node, node.worlddata, true, false)
          scene_builder:transform(node_affine(chain, node))
          scene_builder:image(id, ox, oy, w, h, 0, opacity)
        end
      elseif node.kind == "world" then
        local scene3d = require("scene3d")
        if scene3d.available then
          local i = node.initial
          local w, h = math.floor(node:get("w") or i.w or 0), math.floor(node:get("h") or i.h or 0)
          if w >= 1 and h >= 1 then
            if not node.worlddata then
              node.worlddata = love.image.newImageData(w, h, "rgba8")
              node.worldimg = love.graphics.newImage(node.worlddata)
              node.worldbuilder = scene3d.new_builder()
            end
            local b = node.worldbuilder
            b:reset()
            b:clear(0, 0, 0, 0)
            b:camera(
              node:get("cam_x") or 0, node:get("cam_y") or 0.35, node:get("cam_z") or 3.2,
              node:get("look_x") or 0, node:get("look_y") or 0, node:get("look_z") or 0,
              0, 1, 0,
              node:get("fov") or 0.7, i.near or 0.05, i.far or 80,
              node:get("yaw") or 0, node:get("pitch") or 0, node:get("roll") or 0)
            b:ambient(0.16, 0.17, 0.20)
            local lit = false
            for _, child in ipairs(comp.nodes) do
              if child.kind == "light" and child.initial.parent == node then
                local d = child.initial.dir or { 0.35, -1, 0.25 }
                local c = child:get("color") or child.initial.color or { 1, 1, 1, 1 }
                b:light(d[1], d[2], d[3], c[1], c[2], c[3], child.initial.intensity or 1)
                lit = true
              end
            end
            if not lit then b:light(0.4, -1, 0.25, 1, 1, 1, 1.05) end
            for _, child in ipairs(comp.nodes) do
              if child.kind == "mesh" and child.initial.parent == node then
                local c = child:get("color") or { 0.85, 0.88, 0.92, 1 }
                local sc = child:get("scale") or 1
                local a = (c[4] or 1) * (child:get("opacity") or 1)
                local prim = child.initial.primitive
                if child.mesh_id then
                  b:mesh(child.mesh_id,
                    child:get("x") or 0, child:get("y") or 0, child:get("z") or 0,
                    child:get("yaw") or 0, child:get("pitch") or 0, child:get("roll") or 0,
                    sc, sc, sc, c[1], c[2], c[3], a)
                elseif prim == "sphere" then
                  b:sphere(
                    child:get("x") or 0, child:get("y") or 0, child:get("z") or 0,
                    child:get("yaw") or 0, child:get("pitch") or 0, child:get("roll") or 0,
                    sc, sc, sc, c[1], c[2], c[3], a)
                else
                  b:cube(
                    child:get("x") or 0, child:get("y") or 0, child:get("z") or 0,
                    child:get("yaw") or 0, child:get("pitch") or 0, child:get("roll") or 0,
                    sc, sc, sc, c[1], c[2], c[3], a)
                end
              end
            end
            scene3d.render(b, w, h, node.worlddata:getFFIPointer(), node.worlddata:getSize())
            local ox, oy = anchor_offset(node, w, h)
            if scene_builder and not stop then
              local id = scene.image_slot(node, node.worlddata, true, true)
              scene_builder:transform(node_affine(chain, node))
              scene_builder:image(id, ox, oy, w, h, 0, opacity)
            else
              node.worldimg:replacePixels(node.worlddata)
              setcolor({ 1, 1, 1, 1 }, opacity)
              love.graphics.setBlendMode("alpha", "premultiplied")
              g.draw(node.worldimg, ox, oy)
              love.graphics.setBlendMode("alpha", "alphamultiply")
            end
          end
        end
      elseif node.kind == "html" then
        local html = require("html")
        if html.available then
          local i = node.initial
          if not node.htmldata then
            node.htmldata = love.image.newImageData(i.w, i.h, "rgba8")
            node.htmlimg = love.graphics.newImage(node.htmldata)
            node.html_key = nil
          end
          local progress = node:get("progress") or 0
          local progress_key = string.format("%.2f", progress)
          local key = string.format("%s|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%.3f",
            progress_key, node:get("effect_blur"), node:get("effect_brightness"),
            node:get("effect_contrast"), node:get("effect_saturate"),
            node:get("effect_grayscale"), node:get("effect_sepia"),
            node:get("effect_invert"), node:get("effect_opacity"), node:get("effect_hue_rotate"))
          if node.html_key ~= key then
            local markup = i.html:gsub("{{progress_int}}", tostring(math.floor(progress + 0.5)))
              :gsub("{{progress}}", progress_key)
            html.render(markup, i.w, i.h, 1.0,
              node.htmldata:getFFIPointer(), node.htmldata:getSize())
            require("effects").apply(node, node.htmldata, i.w, i.h)
            node.htmlimg:replacePixels(node.htmldata)
            node.html_key = key
          end
          setcolor({ 1, 1, 1, 1 }, opacity)
          love.graphics.setBlendMode("alpha", "premultiplied")
          local ox, oy = anchor_offset(node, i.w, i.h)
          g.draw(node.htmlimg, ox, oy)
          love.graphics.setBlendMode("alpha", "alphamultiply")
        end
      elseif node.kind == "image" or node.kind == "svg" or node.kind == "page" then
        local img = node_image(node, node.file)
        local iw, ih = img:getDimensions()
        local w, h = node:get("w"), node:get("h")
        local ox, oy = anchor_offset(node, w, h)
        local irx = node:get("rx") or 0
        if node.initial.perspective then
          draw_surface(node, w, h, opacity, ox, oy, irx,
            function(dx, dy) g.draw(img, dx, dy, 0, w / iw, h / ih) end)
        else
        if irx > 0 and not clipped then
          love.graphics.stencil(function()
            love.graphics.rectangle("fill", ox, oy, w, h, irx, irx)
          end, "replace", 1, false)
          love.graphics.setStencilTest("greater", 0)
        end
        setcolor({ 1, 1, 1, 1 }, opacity)
        g.draw(img, ox, oy, 0, w / iw, h / ih)
        if irx > 0 and not clipped then love.graphics.setStencilTest() end
        end
      elseif DRAW_KIND[node.kind] then
        DRAW_KIND[node.kind](node, g, t, opacity)
      elseif node.kind == "rive" then
        -- runtime optional; skip when the rive-rs dylib is not bundled
        local rive = require("rive")
        if rive.available then
          error("moonsplice rive: open/render path not wired")
        end
      elseif node.kind == "displace" then
        local w, h = node:get("w"), node:get("h")
        local img
        if node.file then
          img = node_image(node, node.file)
        else
          if not node.disp_text then
            local f = font(node.initial.size or 72, node.initial.font)
            local canvas = love.graphics.newCanvas(w, h)
            local prev = love.graphics.getCanvas()
            love.graphics.push("all")
            love.graphics.origin()
            love.graphics.setCanvas(canvas)
            love.graphics.clear(0, 0, 0, 0)
            love.graphics.setFont(f)
            local c = node:get("color") or { 1, 1, 1, 1 }
            love.graphics.setColor(c[1], c[2], c[3], 1)
            local tw = f:getWidth(node.initial.text or "")
            love.graphics.print(node.initial.text or "", (w - tw) / 2, (h - f:getHeight()) / 2)
            love.graphics.setCanvas(prev)
            love.graphics.pop()
            node.disp_text = canvas
          end
          img = node.disp_text
        end
        local iw, ih = img:getDimensions()
        local cols = node.initial.cols or 24
        local rows = node.initial.rows or 16
        if not node.mesh then
          local verts = {}
          for row = 0, rows - 1 do
            for col = 0, cols - 1 do
              local x0, y0 = col / cols * w, row / rows * h
              local x1, y1 = (col + 1) / cols * w, (row + 1) / rows * h
              local u0, v0 = col / cols, row / rows
              local u1, v1 = (col + 1) / cols, (row + 1) / rows
              verts[#verts + 1] = { x0, y0, u0, v0, 1, 1, 1, 1 }
              verts[#verts + 1] = { x1, y0, u1, v0, 1, 1, 1, 1 }
              verts[#verts + 1] = { x1, y1, u1, v1, 1, 1, 1, 1 }
              verts[#verts + 1] = { x0, y0, u0, v0, 1, 1, 1, 1 }
              verts[#verts + 1] = { x1, y1, u1, v1, 1, 1, 1, 1 }
              verts[#verts + 1] = { x0, y1, u0, v1, 1, 1, 1, 1 }
            end
          end
          node.mesh = love.graphics.newMesh(verts, "triangles", "static")
        end
        node.mesh:setTexture(img)
        if not node.disp_sh then
          node.disp_sh = love.graphics.newShader([[
            uniform float u_time;
            uniform float u_amp;
            uniform float u_freq;
            vec4 position(mat4 transform_projection, vec4 vertex_position) {
              vec4 p = vertex_position;
              p.y += sin((p.x * 0.031 + u_time * 2.4) * u_freq) * u_amp;
              p.x += cos((p.y * 0.027 + u_time * 1.7) * u_freq) * u_amp * 0.35;
              return transform_projection * p;
            }
            vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
              return Texel(tex, uv) * color;
            }
          ]])
        end
        local sh = node.disp_sh
        sh:send("u_time", t)
        sh:send("u_amp", node:get("amp") or 14)
        sh:send("u_freq", node:get("freq") or 1)
        local ox, oy = anchor_offset(node, w, h)
        setcolor({ 1, 1, 1, 1 }, opacity)
        g.setShader(sh)
        g.draw(node.mesh, ox, oy)
        g.setShader()
      end

      if clipped then love.graphics.setStencilTest() end
      g.pop()
    end
end


-- A layer: its subtree drawn as one picture, then composited once. From the outside in: the blend
-- (a crossfade's incoming clip adds onto the outgoing one), the opacity (its own, a transition's, and
-- the plain groups above it up to the next layer), the matte, the effects, a wipe's edge and a
-- precomp's or track's box; then the members, and a dip's colour over them.
local MATTE_MODE = { alpha = 0, alpha_inverted = 1, luma = 2, luma_inverted = 3 }
local CONTAINER = { group = true, clip = true, track = true, precomp = true, flex = true }
local LEAF = { noblend = true }
paint_layer = function(comp, L, t)
  if not live(L) then return end
  if L.clock then t = L.clock._lt end
  local plan = comp._plan
  local i, tr = L.initial, L._tr
  local chain = parent_chain(L)
  local op = (L:get("opacity") or 1) * (tr and tr.op or 1)
  for k = opacity_from(comp, chain), #chain do op = op * (chain[k]:get("opacity") or 1) end
  if op <= 0 then return end
  local b = scene_builder
  -- a node that is a layer only for its matte paints itself (with its own opacity) inside the matte
  local leaf = L.kind == "fx" or (not plan.members[L] and not CONTAINER[L.kind])
  local pops = 0
  local blend = (tr and tr.plus) and "add" or i.blend
  if blend and blend ~= "alpha" and blend ~= "normal" then b:blend_push(blend); pops = pops + 1 end
  if not leaf and op < 1 then b:opacity_push(op); pops = pops + 1 end
  if i.matte then
    b:matte_push(MATTE_MODE[i.matte_mode or "alpha"] or 0)
    paint_layer(comp, i.matte, t)
    b:matte_body()
    pops = pops + 1
  end
  if not leaf then
    local has_fx = false
    for key, default in pairs(EFFECT_DEFAULTS) do
      local v = L:get(key)
      if v ~= nil and v ~= default then has_fx = true end
    end
    if has_fx then
      local function e(k) local v = L:get(k); if v == nil then v = EFFECT_DEFAULTS[k] end; return v end
      b:transform({ 1, 0, 0, 1, 0, 0 })
      b:fx_push(e("effect_blur"), e("effect_brightness"), e("effect_contrast"), e("effect_saturate"),
        e("effect_grayscale"), e("effect_sepia"), e("effect_invert"), e("effect_opacity"), e("effect_hue_rotate"),
        { 0, 0, comp.width, comp.height })
      pops = pops + 1
    end
  end
  if tr and tr.wipe then
    b:transform(node_affine(chain, nil))
    b:clip_push(tr.wipe[1], tr.wipe[2], tr.wipe[3], tr.wipe[4], 0)
    pops = pops + 1
  end
  -- a precomp and a track are frames: what falls outside their box (a push, a boat sailing off) is cut
  if L.kind == "precomp" or L.kind == "track" then
    b:transform(node_affine(chain, L))
    b:clip_push(0, 0, i.w or comp.width, i.h or comp.height, 0)
    pops = pops + 1
  end
  if leaf then
    paint_node(comp, L, t, nil, LEAF)
  else
    for _, m in ipairs(plan.members[L] or {}) do
      if not SKIP_DRAW[m.kind] and not plan.matte_src[m] then
        local fa = fx_ancestor(m)
        if not (fa and within(fa, L)) then paint_any(comp, m, t) end
      end
    end
  end
  if tr and tr.dip then
    b:transform(node_affine(chain, nil))
    b:rect(0, 0, tr.w, tr.h, tr.dip, 0)
  end
  for _ = 1, pops do b:pop() end
end

-- The first node scene/ cannot draw, in words, or nil when it can draw them all.
function P.scene_blocker(comp)
  if not scene_builder then return "the scene renderer (native/target/release has no moonsplice-scene)" end
  for _, n in ipairs(comp.nodes) do
    if not SKIP_DRAW[n.kind] and not scene_owns(n) then
      local i, what = n.initial, nil
      if not SCENE_KINDS[n.kind] then what = ("the %s kind"):format(n.kind)
      elseif i.blend and not SCENE_BLENDS[i.blend] then what = ("the %s blend"):format(i.blend)
      else what = n.kind end
      return ("%s (node %s)"):format(what, tostring(n.id or "?"))
    end
  end
end

function P.scene_direct_ok(comp)
  return P.scene_blocker(comp) == nil
end

-- Far perspective planes (smaller dolly) draw first so closer cards occlude.
-- Non-perspective nodes keep declaration order against everything else.
local function draw_order(comp)
  local order = {}
  for i, node in ipairs(comp.nodes) do
    order[i] = { i = i, node = node }
  end
  table.sort(order, function(a, b)
    local pa, pb = a.node.initial.perspective, b.node.initial.perspective
    if pa and pb then
      local da, db = a.node:get("dolly") or 1, b.node:get("dolly") or 1
      if da ~= db then return da < db end
    end
    return a.i < b.i
  end)
  return order
end

-- Direct path (step 3 of the plan): every node is scene-owned, so the frame is
-- evaluated straight into an ImageData. No canvas, no GPU readback.
local direct_data, direct_w, direct_h
-- Walk the draw order, one node at a time. `flush` is called before anything the scene builder does not own, which
-- is what keeps the love path's draw order honest; the direct path has nothing to flush.
local function paint_in_order(comp, t, flush)
  local plan = plan_of(comp)
  local order = draw_order(comp)
  local i = 1
  while i <= #order do
    local node = order[i].node
    local skip = SKIP_DRAW[node.kind] or fx_ancestor(node)
    -- a layer paints what it holds; a matte's source is painted only as the matte
    if plan and not skip then skip = plan.owner[node] or plan.matte_src[node] end
    if skip then
      i = i + 1
    else
      if flush then flush(node) end
      paint_any(comp, node, t)
      i = i + 1
    end
  end
end

function P.scene_direct(comp, t)
  P.render_fps = comp.render_fps or comp.fps
  require("persp").frame_h = comp.height
  local s = P.preview_scale or 1
  local w = math.max(1, math.floor(comp.width * s + 0.5))
  local h = math.max(1, math.floor(comp.height * s + 0.5))
  if not direct_data or direct_w ~= w or direct_h ~= h then
    direct_data = love.image.newImageData(w, h, "rgba8")
    direct_w, direct_h = w, h
  end
  scene_builder:reset()
  scene_builder:clear({ comp.background[1], comp.background[2], comp.background[3], 1 })
  paint_in_order(comp, t, nil)
  local t0 = love.timer.getTime()
  scene.render(scene_builder, w, h, direct_data:getFFIPointer(), direct_data:getSize(), s)
  P.scene_time = (P.scene_time or 0) + (love.timer.getTime() - t0)
  P.scene_flushes = (P.scene_flushes or 0) + 1
  scene_builder:reset()
  return direct_data
end

function P.draw_scene(comp, t)
  P.render_fps = comp.render_fps or comp.fps
  local g = love.graphics
  g.clear(comp.background[1], comp.background[2], comp.background[3], 1)
  paint_in_order(comp, t, function(node)
    if scene_builder and not scene_owns(node) and not node.initial.perspective then
      P.scene_flush(comp)
    end
  end)
  if scene_builder then P.scene_flush(comp) end
  g.setColor(1, 1, 1, 1)
end

return P
