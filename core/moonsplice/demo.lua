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

-- what the parts share, and the parts (they load after this table is registered as moonsplice.demo)
D._ = {
  CAM = CAM, ease = ease,
}
package.loaded["moonsplice.demo"] = D
require("moonsplice.demolive")

return D
