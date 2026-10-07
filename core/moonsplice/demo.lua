-- Demo kit: ScreenStudio-style screen demos from static page captures.
-- No recording — the page is a lossless capture (moonsplice-capture), and ALL motion
-- is synthesized: camera pan/zoom (springs on the page image), humanized cursor
-- (arc paths + gentle springs), click ripples, scroll-as-pan. Deterministic,
-- seek-safe, VO-alignable like any comp.
--
--   local demo = require("moonsplice.demo")
--   local d = demo.new(s, { page = "cap/page.png", page_w = 1440, page_h = 3000,
--                           cursor = "assets/cursors/pointer_a.png",
--                           comp_w = 1080, comp_h = 1920 })
--   s:script(function(t)
--     d:zoom(t, { x=0, y=90, w=1440, h=980 }, 1.0)  -- rect in page pixels
--     d:move(t, 128, 320, 0.7)                       -- cursor to page point
--     d:click(t)
--     d:scroll(t, 700, 1.2)                          -- down 700 page px
--   end)
--
-- Camera and cursor beats are sequential by design (camera parked while the
-- cursor travels) — the ScreenStudio grammar. Page-space points convert to
-- screen space using the camera's simulated state at authoring time.

local ease = require("moonsplice.ease")

local D = {}
local Demo = {}
Demo.__index = Demo

local CAM = ease.spring { stiffness = 110, damping = 20 }  -- confident glide
local CURSOR = ease.spring { stiffness = 170, damping = 22 } -- human settle

function D.new(s, opts)
  assert(opts.page and opts.page_w and opts.page_h, "demo.new needs page, page_w, page_h")
  local cw = opts.comp_w or 1080
  local ch = opts.comp_h or 1920
  local s0 = cw / opts.page_w -- establish: fit width, top of page
  local self = setmetatable({
    cw = cw, ch = ch,
    pw = opts.page_w, ph = opts.page_h,
    cam = { x = 0, y = 0, s = s0 }, -- simulated camera (authoring-time mirror)
    cursor_page = { x = opts.page_w / 2, y = opts.page_h / 3 },
    cursor_screen = { x = -100, y = -100 }, -- authoring-time screen mirror
  }, Demo)

  self.page = s:image { src = opts.page, x = 0, y = 0,
    w = opts.page_w * s0, h = opts.page_h * s0 }
  self.ripple = s:circle { x = -100, y = -100, r = 18, color = "#4a90e2aa", opacity = 0 }
  self.cursor = s:image { src = opts.cursor or "assets/cursors/pointer_a.png",
    w = 42, h = 42, x = -100, y = -100, opacity = 0 }
  return self
end

-- page-space -> screen-space under the current simulated camera
function Demo:to_screen(px, py)
  return self.cam.x + px * self.cam.s, self.cam.y + py * self.cam.s
end

local function clamp_cam(self, x, y, s)
  x = math.min(0, math.max(self.cw - self.pw * s, x))
  y = math.min(0, math.max(self.ch - self.ph * s, y))
  return x, y
end

-- glide the camera so `rect` (page px) fills the view with breathing room
function Demo:zoom(t, rect, dur, opts)
  local margin = (opts and opts.margin) or 0.90
  local s = math.min(self.cw / rect.w, self.ch / rect.h) * margin
  local x = self.cw / 2 - (rect.x + rect.w / 2) * s
  local y = self.ch / 2 - (rect.y + rect.h / 2) * s
  x, y = clamp_cam(self, x, y, s)
  t:parallel(
    function() t:tween(self.page, dur, { x = x, y = y }, CAM) end,
    function() t:tween(self.page, dur, { w = self.pw * s, h = self.ph * s }, CAM) end
  )
  -- keep the cursor glued to its page point through the camera move
  self.cam = { x = x, y = y, s = s }
  if self._cursor_shown then
    local nx, ny = self:to_screen(self.cursor_page.x, self.cursor_page.y)
    t.cursor = t.cursor - dur -- same window as the camera glide
    t:parallel(
      function() t:tween(self.cursor, dur, { x = nx, y = ny }, CAM) end
    )
    self.cursor_screen = { x = nx, y = ny }
  end
end

-- pull back to full-width overview at page offset py
function Demo:overview(t, py, dur)
  local s = self.cw / self.pw
  self:zoom(t, { x = 0, y = py or 0, w = self.pw, h = self.ch / s }, dur or 1.0)
end

-- humanized cursor travel to a page point: curved approach, spring settle
function Demo:move(t, px, py, dur)
  local ex, ey = self:to_screen(px, py)
  if not self._cursor_shown then
    self._cursor_shown = true
    t:set(self.cursor, { x = ex - 60, y = ey + 90 })
    t:tween(self.cursor, 0.35, { opacity = 1 }, "sineOut")
    self.cursor_screen = { x = ex - 60, y = ey + 90 }
  end
  local sx, sy = self.cursor_screen.x, self.cursor_screen.y
  -- arc waypoint: perpendicular bow, proportional to travel distance
  local mx, my = (sx + ex) / 2, (sy + ey) / 2
  local dx, dy = ex - sx, ey - sy
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist > 1 then
    local bow = math.min(60, dist * 0.18)
    t:path(self.cursor, dur or math.min(1.0, 0.3 + dist / 1400),
      { { mx - dy / dist * bow, my + dx / dist * bow }, { ex, ey } }, CURSOR)
  end
  self.cursor_page = { x = px, y = py }
  self.cursor_screen = { x = ex, y = ey }
end

-- press: cursor dip + expanding ripple at the cursor point
function Demo:click(t)
  t:set(self.ripple, { x = self.cursor_screen.x + 6, y = self.cursor_screen.y + 6 })
  t:tween(self.cursor, 0.09, { scale = 0.82 }, "sineIn")
  t:parallel(
    function() t:tween(self.cursor, 0.16, { scale = 1.0 }, "sineOut") end,
    function()
      t:set(self.ripple, { opacity = 0.6, r = 10 })
      t:parallel(
        function() t:tween(self.ripple, 0.45, { r = 46 }, "sineOut") end,
        function() t:tween(self.ripple, 0.45, { opacity = 0 }, "sineOut") end
      )
    end
  )
end

-- scroll the page under a parked camera (dy in page pixels, downward)
function Demo:scroll(t, dy, dur)
  local y = self.cam.y - dy * self.cam.s
  local _, yc = clamp_cam(self, self.cam.x, y, self.cam.s)
  local ny = self.cursor_page.y * self.cam.s + yc
  t:parallel(
    function() t:tween(self.page, dur or 1.0, { y = yc }, "sineInOut") end,
    function()
      if self._cursor_shown then
        t:tween(self.cursor, dur or 1.0, { y = ny }, "sineInOut")
      end
    end
  )
  self.cam.y = yc
  self.cursor_screen.y = ny
end

function Demo:hold(t, d) t:wait(d) end

-- ============ live mode: recorded capture (tools/record.mjs) as base ============
-- demo.live(s, { dir = "recdir", fps, css_w, css_h, dpr, comp_w, comp_h, cursor })
-- The capture plays as a video layer; the cursor sprite follows the recorded
-- track; the camera is scale/x/y on the video node (uniform zoom keeps the
-- decode at native resolution — lossless punch-ins up to 1:1).
local Live = {}
Live.__index = Live

-- Recording geometry comes from the recorder itself (meta.lua), so one comp
-- retargets to any aspect with no hand-measured numbers. Explicit opts still win.
local function read_meta(dir)
  local f = _MOONSPLICE_IOOPEN and _MOONSPLICE_IOOPEN(dir .. "/meta.lua", "r") or io.open(dir .. "/meta.lua", "r")
  if not f then return nil end
  local src = f:read("*a"); f:close()
  local chunk = loadstring and loadstring(src) or load(src)
  local ok, m = pcall(chunk)
  return ok and m or nil
end

D.read_meta = read_meta

function D.live(s, opts)
  local meta = opts.meta or (opts.dir and read_meta(opts.dir)) or {}
  local dpr = opts.dpr or meta.dpr or 2
  local vw = (opts.css_w or meta.width) * dpr
  local vh = (opts.css_h or meta.height) * dpr
  -- comp size defaults to the aspect the recording was captured for
  local cw = opts.comp_w or meta.out_w or 1920
  local ch = opts.comp_h or meta.out_h or 1080
  local frame = opts.frame or {}
  local pad = frame.pad or math.floor(cw * 0.055)
  -- fit BOTH axes: a tall capture in a tall comp must not overflow vertically
  local avail_h = frame.max_h or (ch - 2 * pad)
  local base = math.min((cw - 2 * pad) / vw, avail_h / vh)
  local self = setmetatable({
    cw = cw, ch = ch, vw = vw, vh = vh, dpr = dpr,
    fps = opts.fps or meta.fps or 30, base = base, meta = meta,
    cam = { x = (cw - vw * base) / 2, y = (ch - vh * base) / 2, s = 1 },
  }, Live)

  -- ScreenStudio framing: mesh-gradient backdrop (radial color blobs + film
  -- grain — never a flat/blank background) + soft shadow under a rounded screen.
  local colorlib = require("moonsplice.color")
  local mesh = frame.mesh or { -- defaults echo the ElevenLabs editorial look
    base = "#dfe5e3",
    blobs = {
      { x = 0.12, y = 0.10, r = 0.75, color = "#b89a3f" }, -- warm gold, top-left
      { x = 0.85, y = 0.30, r = 0.80, color = "#8fb8d8" }, -- sky, right
      { x = 0.45, y = 0.95, r = 0.90, color = "#5f97c4" }, -- deep sky, bottom
      { x = 0.55, y = 0.45, r = 0.55, color = "#c9d3c4" }, -- sage, center
    },
    grain = 0.045,
  }
  -- frame.backdrop = false when the comp supplies its own background (the
  -- backdrop is a node, so it would draw over anything created before this call)
  if frame.backdrop ~= false then
    local base_c = colorlib.parse(mesh.base)
    local blobs = {}
    for i, b in ipairs(mesh.blobs) do
      local c = colorlib.parse(b.color)
      blobs[i] = { x = b.x * cw, y = b.y * ch, r = b.r * math.max(cw, ch),
        c0 = { c[1], c[2], c[3], b.alpha or 0.85 }, c1 = { c[1], c[2], c[3], 0 } }
    end
    s:vector {
      w = cw, h = ch,
      draw = function(v)
        v:rect(0, 0, cw, ch, base_c)
        for _, b in ipairs(blobs) do
          v:radial(b.x, b.y, b.r, b.c0, b.c1)
        end
        if (mesh.grain or 0) > 0 then v:grain(mesh.grain, 7) end
      end,
    }
  end
  self.shadows = {}
  self.video = s:video { src = opts.dir .. "/capture.mp4", w = vw, h = vh,
    x = self.cam.x, y = self.cam.y, scale = base, rx = (frame.rx or 24) / base,
    shadow = { blur = (frame.shadow_blur or 60) / base,
               alpha = frame.shadow_alpha or 0.30,
               dy = (frame.shadow_dy or 22) / base } }
  self.track = opts.track -- array {f,x,y,down} in css px
  -- Cursor sprites carry transparent padding: pointer_b.png is 32x32 with the
  -- arrow starting at (8,6), so drawing the sprite AT the click point puts the
  -- visible tip low and to the right. Offset by the hotspot so the tip lands on
  -- the pixel. Size tracks the capture scale, or the cursor grows relative to
  -- the UI on smaller comps and the miss becomes obvious.
  local k = base * self.dpr
  local csz = math.max(24, math.floor(46 * k + 0.5))
  self.cursor_hot = opts.cursor_hotspot or { 8 / 32, 6 / 32 }
  self.cursor_size = csz
  self.cursor = s:image { src = opts.cursor or "assets/cursors/pointer_b.png",
    w = csz, h = csz, x = -100, y = -100, opacity = 0 }
  self.ripple = s:circle { x = -100, y = -100, r = 18, color = "#4a90e2aa", opacity = 0 }

  -- opts.camera turns the capture into a plane in 3D (see core/runtime/persp.lua).
  -- The cursor then has to live ON the surface, or it would float free of the
  -- page the moment the camera tilts. At the identity pose (yaw/pitch/roll = 0,
  -- dolly = 1, truck centred) the projection is exactly the flat render, so 2D
  -- overlays authored against the flat framing still line up perfectly.
  if opts.camera then
    local c = opts.camera
    local v = self.video.initial
    v.perspective = true
    v.persp_margin = c.margin or 1.7
    v.yaw, v.pitch, v.roll = c.yaw or 0, c.pitch or 0, c.roll or 0
    v.dolly, v.fov = c.dolly or 1, c.fov or 0.62
    v.aperture, v.maxcoc = c.aperture or 0, c.maxcoc or 40
    v.focus_u, v.focus_v = 0.5, 0.5
    v.truck_u, v.truck_v = 0.5, 0.5
    v.cursor_src = opts.cursor or "assets/cursors/pointer_b.png"
    v.cursor_w = 46 * self.dpr           -- page px; × base = the flat on-screen size
    v.cursor_u, v.cursor_v, v.cursor_opacity = 0.5, 0.5, 0
    self.surface_cursor = true
    self.cursor.initial.opacity = 0      -- the 2D sprite is unused in camera mode
  end
  return self
end

-- css point -> normalized page coords, for truck/focus targets
function Live:uv(css_x, css_y)
  return css_x / (self.vw / self.dpr), css_y / (self.vh / self.dpr)
end

-- Screen point of the recorded cursor at frame f, INCLUDING the camera when one
-- is active. During a synthesized drag the camera is contractually at an
-- unrotated, centre-trucked pose, where the projection is a pure zoom about the
-- frame centre — so the drop pixel is just the flat point scaled by dolly.
function Live:screen_at(f)
  local sx, sy = self:track_at(f)
  if self.video.initial.perspective then
    local dolly = self.video:get("dolly") or 1
    sx = self.cw / 2 + (sx - self.cw / 2) * dolly
    sy = self.ch / 2 + (sy - self.ch / 2) * dolly
  end
  return sx, sy
end

-- ---------- synthesized drag-and-drop ----------
-- A fake file drop that lands on the real upload frame. EVERY dimension here is
-- derived from the recording's own scale (css px -> comp px via base*dpr), so
-- it is correct at any aspect by construction. Authoring these as comp-space
-- constants is what breaks when the comp width changes: the ghost scales with
-- the frame while a hard-coded carry offset does not, and they drift apart.
-- Sizes below are in CSS pixels of the captured page — the same units you would
-- read off the real UI.
function Live:drag(s, opts)
  opts = opts or {}
  assert(opts.thumb, "demo: drag{ thumb = 'path.png' } required")
  local k = self.base * self.dpr                 -- css px -> comp px
  local tw = (opts.thumb_w or 150) * k
  local th = tw * (opts.thumb_ratio or 0.5625)
  local cw = self.cursor_size or (46 * k)        -- matches the recorded cursor
  local d = {
    -- the ghost rides below-right of the cursor tip, like a real OS drag image
    ox = (opts.offset_x or 74) * k,
    oy = (opts.offset_y or 42) * k,
    cw = cw,
    hot = opts.cursor_hotspot or { 0.5, 0.5 },   -- closed hand: palm centre
    ghost = s:image { src = opts.thumb, w = tw, h = th, anchor = "center",
      x = -tw, y = -th, opacity = 0, rotation = opts.tilt or 0.07 },
    cursor = s:image { src = opts.cursor or "assets/cursors/hand_closed.png",
      w = cw, h = cw, x = -cw, y = -cw, opacity = 0 },
    pulse = s:circle { x = -cw, y = -cw, r = 10, color = "#ffffff00" },
  }
  return d
end

-- Carry the ghost in and drop it on frame `f`, then hand the cursor off to the
-- recorded track on the exact same pixel so it never blinks out.
function Live:drag_play(t, d, f, opts)
  opts = opts or {}
  local dur = opts.duration or 0.92
  local land = opts.land
  if land then t:wait(math.max(0, land - dur - t.cursor)) end
  local hx, hy = self:screen_at(f)
  local fx = opts.from_x or (self.cw * 0.84)
  local fy = opts.from_y or (self.ch * 0.80)
  local cx = d.cw * d.hot[1]
  local cy = d.cw * d.hot[2]

  t:set(d.ghost, { x = fx + d.ox, y = fy + d.oy, opacity = 0.95 })
  t:set(d.cursor, { x = fx - cx, y = fy - cy, opacity = 1 })
  t:parallel(                                    -- one rigid unit, fixed offset
    function() t:path(d.ghost, dur, { { hx + d.ox, hy + d.oy } }, opts.ease) end,
    function() t:path(d.cursor, dur, { { hx - cx, hy - cy } }, opts.ease) end,
    function() t:tween(d.ghost, dur, { rotation = 0 }, opts.ease) end
  )

  local c0 = t.cursor
  t:set(d.cursor, { opacity = 0 })
  if self.surface_cursor then
    local u, v = self:track_uv(f)
    t:set(self.video, { cursor_u = u, cursor_v = v, cursor_opacity = 1 })
  else
    local sx, sy = self:cursor_xy(hx, hy)
    t:set(self.cursor, { x = sx, y = sy, opacity = 1 })
  end
  t:parallel(
    function() t:tween(d.ghost, 0.12, { scale = 0.82, opacity = 0 }, "quadIn") end,
    function()
      t:set(d.pulse, { x = hx + d.ox, y = hy + d.oy, r = d.cw * 0.6, color = "#ffffffbb" })
      t:parallel(
        function() t:tween(d.pulse, 0.5, { r = d.cw * 3.6 }, "cubicOut") end,
        function() t:tween(d.pulse, 0.5, { color = "#ffffff00" }, "cubicOut") end
      )
    end
  )
  t.cursor = c0                                  -- pulse rides alongside
  return hx, hy
end

-- recorded cursor position at frame f, as normalized page coords
function Live:track_uv(f)
  local best = self.track[1]
  for _, e in ipairs(self.track) do
    if e.f <= f then best = e else break end
  end
  return self:uv(best.x, best.y)
end

-- camera tween applied to the screen AND its shadow stack
function Live:cam_tween(t, x, y, s, dur)
  local c0 = t.cursor
  t:tween(self.video, dur, { x = x, y = y, scale = s }, CAM)
  for i, sh in ipairs(self.shadows) do
    t.cursor = c0
    t:tween(sh, dur, { x = x - i * 4, y = y + i * 5, scale = s }, CAM)
  end
  t.cursor = c0 + dur
end

function Live:to_screen(css_x, css_y)
  local k = self.base * self.cam.s * self.dpr
  return self.cam.x + css_x * k, self.cam.y + css_y * k
end

-- screen point -> cursor NODE position, so the sprite's tip sits on the point
function Live:cursor_xy(sx, sy)
  return sx - self.cursor_hot[1] * self.cursor_size,
         sy - self.cursor_hot[2] * self.cursor_size
end

-- drive the cursor sprite along the recorded track for [f0, f1).
-- `offset` shifts recorded time into comp time (comp_t = f/fps + offset), so a
-- synthesized intro can precede the recording without the cursor jumping.
-- screen position of the recorded cursor at frame f (last sample at or before f)
function Live:track_at(f)
  local best
  for _, e in ipairs(self.track) do
    if e.f <= f then best = e else break end
  end
  best = best or self.track[1]
  return self:to_screen(best.x, best.y)
end

function Live:play_track(t, f0, f1, offset)
  offset = offset or 0
  local first = true
  for _, e in ipairs(self.track) do
    if e.f >= f0 and e.f < f1 then
      local sx, sy = self:to_screen(e.x, e.y)
      local at = e.f / self.fps + offset
      local su, sv = self:uv(e.x, e.y)
      if first then
        first = false
        t:wait(math.max(0, at - t.cursor))
        if self.surface_cursor then
          t:set(self.video, { cursor_u = su, cursor_v = sv, cursor_opacity = 1,
            focus_u = su, focus_v = sv })
        else
          local cx, cy = self:cursor_xy(sx, sy)
          t:set(self.cursor, { x = cx, y = cy, opacity = 1 })
        end
      else
        local dur = at - t.cursor
        if dur > 0.01 then
          if self.surface_cursor then
            -- focus rides with the cursor; a lag here would leave it behind on
            -- a fast traverse, which is the whole shot
            t:tween(self.video, dur,
              { cursor_u = su, cursor_v = sv, focus_u = su, focus_v = sv }, "linear")
          else
            local cx, cy = self:cursor_xy(sx, sy)
            t:tween(self.cursor, dur, { x = cx, y = cy }, "linear")
          end
        end
      end
      if e.down and not self._was_down and not self.surface_cursor then
        t:set(self.ripple, { x = sx + 6, y = sy + 6, opacity = 0.6, r = 10 })
        local c0 = t.cursor
        t:parallel(
          function() t:tween(self.ripple, 0.45, { r = 46 }, "sineOut") end,
          function() t:tween(self.ripple, 0.45, { opacity = 0 }, "sineOut") end
        )
        t.cursor = c0 -- ripple rides alongside; don't consume track time
      end
      self._was_down = e.down
    end
  end
end

-- cinematic zoom to a css-px rect of the capture (camera = scale + x/y)
function Live:zoom(t, rect, dur)
  local k = self.dpr
  local rw, rh = rect.w * k * self.base, rect.h * k * self.base
  local target_s = math.min(self.cw / rw, self.ch / rh) * 0.92
  local x = self.cw / 2 - (rect.x + rect.w / 2) * k * self.base * target_s
  local y = self.ch / 2 - (rect.y + rect.h / 2) * k * self.base * target_s
  self:cam_tween(t, x, y, self.base * target_s, dur)
  self.cam = { x = x, y = y, s = target_s }
end

-- pull back to the framed fit-width overview
function Live:overview(t, dur)
  local pad = self.cam0_pad or (self.cw - self.vw * self.base) / 2
  local y = (self.ch - self.vh * self.base) / 2
  self:cam_tween(t, pad, y, self.base, dur)
  self.cam = { x = pad, y = y, s = 1 }
end

return D
