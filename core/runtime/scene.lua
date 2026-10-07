-- moonsplice-scene bridge: the single vello rasterizer under the timeline.
-- On by default (MOONSPLICE_SCENE=0 opts out). Nodes the scene crate can paint are streamed
-- into one f32 command list (+ string table) instead of love.graphics calls;
-- the painter flushes the list into one premultiplied RGBA layer whenever a
-- node the crate cannot paint yet comes next in z-order, and at frame end.
local ffi = require("ffi")

ffi.cdef([[
int cs_font_load(const char *path);
int cs_text_measure(int font, float size, const char *text, float ls, float wrap,
                    float leading, float *out);
int cs_image_register(const uint8_t *rgba, uint16_t w, uint16_t h, int premul);
int cs_image_update(int slot, const uint8_t *rgba, uint16_t w, uint16_t h, int premul);
int cs_render(const float *cmds, size_t len, const uint8_t *strings, size_t strings_len,
              uint16_t w, uint16_t h, uint16_t threads, uint8_t *out, size_t out_len);
int cs_render_scaled(const float *cmds, size_t len, const uint8_t *strings, size_t strings_len,
              uint16_t w, uint16_t h, float scale, uint16_t threads, uint8_t *out, size_t out_len);
const char *cs_last_error(void);
int cs_lottie_load(const char *path, float *out);
]])

local S = { available = false, enabled = false }
S.threads = tonumber(os.getenv("MOONSPLICE_SCENE_THREADS") or "0") or 0

local lib
local ok = pcall(function()
  lib = ffi.load(require("native").lib("moonsplice_scene"))
end)
if ok and lib then S.available = true end
-- Default since 2026-09-16 (item 7 of .robot/docs/scene.robot): the rasterizer is on
-- whenever the dylib is present; MOONSPLICE_SCENE=0 selects the love canvas path.
local want = os.getenv("MOONSPLICE_SCENE")
S.enabled = S.available and want ~= "0"
if want == "1" and not S.available then
  io.stderr:write("moonsplice: MOONSPLICE_SCENE=1 but scene dylib not found (build scene/)\n")
end

-- fonts: path -> id (0 = bundled NotoSans, matching love's default)
local font_ids = {}
function S.font_id(path)
  if not path then return 0 end
  local id = font_ids[path]
  if id then return id end
  local p = path:match("^/") and path
    or ((os.getenv("MOONSPLICE_CWD") or ".") .. "/" .. path)
  id = lib.cs_font_load(p)
  assert(id >= 0, "moonsplice-scene: font not found: " .. path)
  font_ids[path] = id
  return id
end

local measure_cache = {}
local mbuf = ffi.new("float[2]")
function S.measure(font, size, text, ls, wrap, leading)
  local key = table.concat({ font, size, text, ls or 0, wrap or 0, leading or 0 }, "\1")
  local m = measure_cache[key]
  if m then return m[1], m[2] end
  assert(lib.cs_text_measure(font, size, text, ls or 0, wrap or 0, leading or 0, mbuf) == 0,
    "moonsplice-scene: measure failed")
  m = { mbuf[0], mbuf[1] }
  measure_cache[key] = m
  return m[1], m[2]
end

-- builder: growable f32 command buffer + byte string table, reused per frame
local Builder = {}
Builder.__index = Builder

function S.new_builder()
  return setmetatable({
    cap = 4096, len = 0, buf = ffi.new("float[?]", 4096),
    scap = 4096, slen = 0, sbuf = ffi.new("uint8_t[?]", 4096),
    pending = false,
  }, Builder)
end

function Builder:reset() self.len, self.slen, self.pending = 0, 0, false end

local function push(b, ...)
  local n = select("#", ...)
  if b.len + n > b.cap then
    local ncap = b.cap * 2
    while b.len + n > ncap do ncap = ncap * 2 end
    local nbuf = ffi.new("float[?]", ncap)
    ffi.copy(nbuf, b.buf, b.len * 4)
    b.buf, b.cap = nbuf, ncap
  end
  for i = 1, n do
    b.buf[b.len] = select(i, ...)
    b.len = b.len + 1
  end
end

function Builder:str(s)
  local n = #s
  if self.slen + n > self.scap then
    local ncap = self.scap * 2
    while self.slen + n > ncap do ncap = ncap * 2 end
    local nbuf = ffi.new("uint8_t[?]", ncap)
    ffi.copy(nbuf, self.sbuf, self.slen)
    self.sbuf, self.scap = nbuf, ncap
  end
  local off = self.slen
  ffi.copy(self.sbuf + off, s, n)
  self.slen = self.slen + n
  return off, n
end

local function col(c)
  if type(c) == "string" then c = require("moonsplice.color").parse(c) end
  c = c or { 1, 1, 1, 1 }
  return c[1], c[2], c[3], c[4] or 1
end

-- absolute affine [a b c d e f]: x' = a*x + c*y + e ; y' = b*x + d*y + f
function Builder:transform(m) push(self, 100, m[1], m[2], m[3], m[4], m[5], m[6]); self.pending = true end

-- runs: array of { text=, color=, bold=, italic= }; opts: ls, wrap, leading, align(0/1/2),
-- outline (px), outline_color, embolden (px), opacity
function Builder:text(font, size, x, y, runs, opts)
  opts = opts or {}
  local op = opts.opacity or 1
  local orr, og, ob, oa = col(opts.outline_color or { 0, 0, 0, 1 })
  push(self, 101, font, size, x, y, opts.ls or 0, opts.wrap or 0, opts.leading or 0,
    opts.align or 0, opts.outline or 0, orr, og, ob, oa * op, opts.embolden or 0, #runs)
  for _, r in ipairs(runs) do
    local off, n = self:str(r.text)
    local cr, cg, cb, ca = col(r.color)
    push(self, off, n, cr, cg, cb, ca * op, r.bold and 1 or 0, r.italic and 1 or 0)
  end
  self.pending = true
end

-- vector-compatible primitives (same opcodes as moonsplice-vector)
function Builder:rect(x, y, w, h, c, rad)
  if rad and rad > 0 then push(self, 1, x, y, w, h, rad, col(c)) else push(self, 0, x, y, w, h, col(c)) end
  self.pending = true
end
function Builder:circle(cx, cy, r, c) push(self, 2, cx, cy, r, col(c)); self.pending = true end
function Builder:clear(c) push(self, 102, col(c)); self.pending = true end
function Builder:image(id, x, y, w, h, rx, alpha) push(self, 103, id, x, y, w, h, rx or 0, alpha or 1); self.pending = true end
-- a Lottie (S.lottie) at Lottie frame `frame`, its own box scaled into (x, y, w, h)
function Builder:lottie(id, frame, x, y, w, h, alpha) push(self, 116, id, frame, x, y, w, h, alpha or 1); self.pending = true end
function Builder:clip_push(x, y, w, h, rx) push(self, 104, x, y, w, h, rx or 0) end
-- a perspective plane (core/runtime/persp.lua P.params): content until 105 is the flat page, drawn
-- in node space at (ox, oy, w, h); it is warped through the camera and composited in its place
function Builder:persp_push(p, ox, oy, w, h)
  local Hi = p.Hi
  push(self, 114, ox, oy, w, h, p.sw, p.sh, Hi[1], Hi[2], Hi[3], Hi[4], Hi[5], Hi[6], Hi[7], Hi[8], Hi[9],
    p.R20, p.R21, p.Dz, p.focusW, p.aperture, p.maxcoc)
end
-- s:displace: content until 105 is the flat page at node-space (ox, oy, w, h)
function Builder:displace_push(ox, oy, w, h, cols, rows, t, amp, freq)
  push(self, 115, ox, oy, w, h, cols, rows, t, amp, freq)
end
-- everything except the box: `clip_invert`
function Builder:clip_push_outside(x, y, w, h, rx) push(self, 113, x, y, w, h, rx or 0) end
function Builder:clip_pop() push(self, 105) end
function Builder:pop() push(self, 105) end
-- { mix, compose }: mix is peniko's Mix in its own order, compose 1 is Plus (`add`).
local BLEND = { alpha = { 0, 0 }, normal = { 0, 0 }, multiply = { 1, 0 }, screen = { 2, 0 }, overlay = { 3, 0 },
  darken = { 4, 0 }, lighten = { 5, 0 }, ["color-dodge"] = { 6, 0 }, ["color-burn"] = { 7, 0 },
  ["hard-light"] = { 8, 0 }, ["soft-light"] = { 9, 0 }, difference = { 10, 0 }, exclusion = { 11, 0 },
  hue = { 12, 0 }, saturation = { 13, 0 }, color = { 14, 0 }, luminosity = { 15, 0 }, add = { 0, 1 } }
S.BLEND = BLEND
function Builder:blend_push(mode) local b = BLEND[mode] or BLEND.alpha; push(self, 107, b[1], b[2]) end
local FILTER = { effect_blur = 0, effect_brightness = 1, effect_contrast = 2, effect_saturate = 3, effect_grayscale = 4,
  effect_sepia = 5, effect_invert = 6, effect_opacity = 7, effect_hue_rotate = 8 }
S.FILTER = FILTER
function Builder:filter_push(kind, amount) push(self, 108, kind, amount) end
function Builder:opacity_push(a) push(self, 110, a) end
-- the moonsplice-effects chain (love parity): blur brightness contrast saturate grayscale sepia invert opacity hue
-- box = { x, y, w, h } in the current transform space: the effect runs on that box only
function Builder:fx_push(blur, brightness, contrast, saturate, grayscale, sepia, invert, opacity, hue, box)
  push(self, 111, blur or 0, brightness or 1, contrast or 1, saturate or 1, grayscale or 0, sepia or 0, invert or 0, opacity or 1, hue or 0,
    box[1], box[2], box[3], box[4])
end
-- the s:fx chain on the CPU (opcode 112): passes = { {kind, amount, extra}, … }, box as fx_push
S.CHAIN = { bloom = 1, glow = 2, blur = 3, vignette = 4, chroma = 5, chromasep = 5, grain = 6,
  tonemap = 7, aces = 7, pixelate = 8, posterize = 9, filmgrain = 10, kawase = 11, worley = 12 }
-- passes: { id, amount, t } on the CPU, or { src = glsl, t = t } for the comp's own shader (13)
function Builder:chain_push(passes, box)
  push(self, 112, #passes, box[1], box[2], box[3], box[4])
  for _, p in ipairs(passes) do
    if p.src then
      local off, n = self:str(p.src)
      push(self, 13, off, n, p.t or 0)
    else
      push(self, p[1], p[2], p[3] or 0, 0)
    end
  end
end
-- vector-node builder surface (same verbs as core/runtime/vector.lua)
function Builder:move(x, y) push(self, 3, x, y) end
function Builder:line(x, y) push(self, 4, x, y) end
function Builder:curve(x1, y1, x2, y2, x, y) push(self, 5, x1, y1, x2, y2, x, y) end
function Builder:fill(c) push(self, 6, col(c)); self.pending = true end
function Builder:stroke(width, c) push(self, 7, width, col(c)); self.pending = true end
function Builder:polyline(pts, width, c)
  if #pts < 4 then return end
  self:move(pts[1], pts[2])
  for i = 3, #pts, 2 do self:line(pts[i], pts[i + 1]) end
  self:stroke(width or 2, c)
end
function Builder:gradient(x, y, w, h, x0, y0, x1, y1, c0, c1)
  push(self, 8, x, y, w, h, x0, y0, x1, y1); push(self, col(c0)); push(self, col(c1)); self.pending = true
end
function Builder:radial(cx, cy, r, c0, c1) push(self, 9, cx, cy, r); push(self, col(c0)); push(self, col(c1)); self.pending = true end
-- grain is scoped to the current vector node's box (set by the painter)
function Builder:grain(amount, seed)
  local b = self.grain_box
  if b then push(self, 106, amount, seed or 1, b[1], b[2], b[3], b[4]) end
end

-- dynamic images (html textures, frames): one slot per node, updated on change
-- premul: true when the buffer is already premultiplied (blitz, vello, canvases)
function S.image_slot(node, imagedata, changed, premul)
  local w, h = imagedata:getDimensions()
  local ptr = ffi.cast("const uint8_t*", imagedata:getFFIPointer())
  local pm = premul and 1 or 0
  if node._scene_slot == nil or node._scene_w ~= w or node._scene_h ~= h then
    node._scene_slot = lib.cs_image_register(ptr, w, h, pm)
    node._scene_w, node._scene_h = w, h
    assert(node._scene_slot >= 0, "moonsplice-scene: image register failed")
  elseif changed then
    assert(lib.cs_image_update(node._scene_slot, ptr, w, h, pm) == 0, "moonsplice-scene: image update failed")
  end
  return node._scene_slot
end

-- images: registered once per file path from a love ImageData
local image_ids = {}
function S.image_id(path, imagedata)
  local id = image_ids[path]
  if id then return id end
  local w, h = imagedata:getDimensions()
  id = lib.cs_image_register(ffi.cast("const uint8_t*", imagedata:getFFIPointer()), w, h, 0)
  assert(id >= 0, "moonsplice-scene: image register failed: " .. path)
  image_ids[path] = id
  return id
end

-- Lotties: loaded once per path. { id, first, last, fps, w, h }: frames [first, last) at fps.
local lotties = {}
local lbuf = ffi.new("float[5]")
function S.lottie(path)
  local l = lotties[path]
  if l then return l end
  local id = lib.cs_lottie_load(path, lbuf)
  if id < 0 then error("moonsplice: lottie: " .. ffi.string(lib.cs_last_error()), 0) end
  l = { id = id, first = lbuf[0], last = lbuf[1], fps = lbuf[2], w = lbuf[3], h = lbuf[4] }
  lotties[path] = l
  return l
end

-- `scale` maps scene units onto the output: a preview of a 1920x1080 composition into a
-- 960x540 buffer passes 0.5. Absent or 1 is the render, unchanged and to the byte.
--
-- MOONSPLICE_SCENE_DUMP=dir writes each frame's stream as it is handed over: <n>.cmds (the f32s),
-- <n>.str (the string table), <n>.meta ("w h scale"). The browser build of scene/ replays these
-- and is held to the same hashes (tools/scene-wasm).
local dump_dir, dump_n = os.getenv("MOONSPLICE_SCENE_DUMP"), 0
function S.render(b, w, h, out_ptr, out_len, scale)
  if dump_dir then
    local open = _MOONSPLICE_IOOPEN or io.open
    local function put(ext, bytes)
      local f = assert(open(("%s/%05d.%s"):format(dump_dir, dump_n, ext), "wb"))
      f:write(bytes); f:close()
    end
    put("cmds", ffi.string(b.buf, b.len * 4))
    put("str", b.slen > 0 and ffi.string(b.sbuf, b.slen) or "")
    put("meta", ("%d %d %s"):format(w, h, tostring(scale or 1)))
    dump_n = dump_n + 1
  end
  local rc = lib.cs_render_scaled(b.buf, b.len, b.sbuf, b.slen, w, h, scale or 1, S.threads,
    ffi.cast("uint8_t*", out_ptr), out_len)
  if rc ~= 0 then
    local why = ffi.string(lib.cs_last_error())
    error("moonsplice-scene: render failed" .. (why ~= "" and (": " .. why) or ""), 0)
  end
end

return S
