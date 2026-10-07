-- 3D camera on a screen capture — orbit + real defocus, all post.
--
--   moonsplice render comps/examples/demos/screen3d.lua -o comps/examples/out/screen3d.mp4
--
-- Nothing here was re-recorded: this is the SAME capture the dubbing demo uses.
-- `perspective = true` turns a video node's surface into a plane in 3D. Because
-- it is a plane, the transform is a homography the fragment shader runs
-- backwards (screen px -> page px), which is exact at any angle and yields the
-- camera-space depth of every pixel for free.
--
-- That depth buys the thing a 2D tool cannot fake: when the page is tilted, its
-- far edge is genuinely further from the lens, so it genuinely defocuses. Focus
-- rides the recorded cursor while we are pushed in, and the lens opens up to
-- wide/deep when we pull back — the grammar of a real camera, not a zoom.
--
-- Animatable camera props: yaw, pitch, roll, dolly, fov, aperture, maxcoc,
-- focus_u, focus_v (focus_* are normalized page coords, 0..1).
local e = require("moonsplice")
local ease = require("moonsplice.ease")

local REC = "/tmp/rec_a169"
local META = dofile(REC .. "/meta.lua")
local TRACK = dofile(REC .. "/cursor.lua")
local FPS = 30
local W, H = 1920, 1080

-- the capture, laid out flat and centred; the 3D camera works on top of it
local PW = 1330
local PH = math.floor(PW * (META.height / META.width) + 0.5)
local REC_LEN = META.frames / FPS   -- the capture runs out; camera keeps going
local DUR = 12.6

local GLIDE = ease.cubicBezier(0.4, 0, 0.2, 1)
local SWING = ease.cubicBezier(0.5, 0, 0.25, 1)

-- recorded cursor position -> normalized page coords, so focus can follow it
local function cursor_uv(t)
  local f = math.max(0, math.min(META.frames - 1, math.floor(t * FPS)))
  local best = TRACK[1]
  for _, c in ipairs(TRACK) do
    if c.f <= f then best = c else break end
  end
  return best.x / META.width, best.y / META.height
end

return e.comp {
  width = W, height = H, duration = DUR, fps = FPS, background = "#101014",

  scene = function(s)
    s:vector {
      w = W, h = H,
      draw = function(v, t)
        v:rect(0, 0, W, H, { 0.05, 0.05, 0.07, 1 })
        local a = math.sin(t * 0.18) * 60
        v:radial(300 + a, 180, 1500, { 0.16, 0.10, 0.30, 0.95 }, { 0.16, 0.10, 0.30, 0 })
        v:radial(1700 - a, 900, 1450, { 0.07, 0.22, 0.30, 0.92 }, { 0.07, 0.22, 0.30, 0 })
        v:radial(960, 540, 800, { 0.55, 0.45, 0.75, 0.16 }, { 0.55, 0.45, 0.75, 0 })
        v:grain(0.05, 5)
      end,
    }

    local screen = s:video {
      src = REC .. "/capture.mp4", w = PW, h = PH,
      x = W / 2, y = H / 2, anchor = "center", rx = 18,
      from = 0, duration = DUR, media_start = 0,
      perspective = true, persp_margin = 2.2,
      -- the cursor is composited INTO the page before the warp, so it tilts
      -- with the surface and goes soft with it — like a baked-in recording
      cursor_src = "assets/cursors/pointer_b.png", cursor_w = 40,
      cursor_u = 0.5, cursor_v = 0.4,
      -- establishing: near head-on, wide lens, everything sharp
      yaw = -0.34, pitch = 0.15, roll = 0.02,
      dolly = 0.92, fov = 0.62,
      aperture = 0, maxcoc = 44, focus_u = 0.5, focus_v = 0.5,
    }

    s:script(function(t)
      -- PASS 1: the cursor rides the recorded track, and focus trails it by a
      -- hair. Keep the lag small: on a fast traverse a big lag leaves focus
      -- behind, and the whole point is that the pointer stays sharp.
      -- Recorded from t=0, then the head rewinds so the camera runs over it.
      local STEP = 3                       -- keyframe every 0.1s
      local function ride(node_props, lag)
        t.cursor = lag
        local pu, pv = nil, nil
        for k = 1, #TRACK, STEP do
          local c = TRACK[k]
          local u, v = c.x / META.width, c.y / META.height
          local dst = {}
          for prop, which in pairs(node_props) do
            dst[prop] = (which == "u") and u or v
          end
          if pu == nil then
            t:set(screen, dst)
          else
            t:tween(screen, STEP / FPS, dst, "linear")
          end
          pu, pv = u, v
        end
      end
      local head = t.cursor
      ride({ cursor_u = "u", cursor_v = "v" }, 0)
      t.cursor = head
      ride({ focus_u = "u", focus_v = "v" }, 0.10)
      t.cursor = head

      -- PASS 2: the camera.
      -- 1. drift out of the establishing angle toward square-on
      t:parallel(
        function() t:tween(screen, 2.2, { yaw = -0.07, pitch = 0.05, roll = 0 }, GLIDE) end,
        function() t:tween(screen, 2.2, { dolly = 1.02 }, GLIDE) end
      )

      -- 2. push in and open the aperture. Focus is already riding the cursor,
      --    so the pointer stays sharp while the tilted page falls away.
      t:parallel(
        function() t:tween(screen, 1.3, { dolly = 1.52, yaw = 0.30, pitch = -0.13 }, GLIDE) end,
        function() t:tween(screen, 1.3, { fov = 0.78 }, GLIDE) end,
        function() t:tween(screen, 1.3, { aperture = 50 }, GLIDE) end
      )

      -- 3. orbit while the recording does its work (upload -> language -> send)
      local LEG = 1.05
      for _, ang in ipairs { { 0.42, -0.17 }, { 0.06, 0.15 }, { -0.36, -0.10 }, { 0.10, 0.14 } } do
        t:parallel(
          function() t:tween(screen, LEG, { yaw = ang[1], pitch = ang[2] }, SWING) end,
          function() t:tween(screen, LEG, { roll = ang[2] * 0.25 }, SWING) end
        )
      end

      -- 4. pull back to wide and deep — aperture closes, everything sharp again
      t:parallel(
        function() t:tween(screen, 2.3, { dolly = 0.95, yaw = 0.20, pitch = 0.11, roll = -0.03 }, GLIDE) end,
        function() t:tween(screen, 2.3, { fov = 0.60 }, GLIDE) end,
        function() t:tween(screen, 2.3, { aperture = 0 }, GLIDE) end
      )
      t:tween(screen, 1.2, { yaw = 0.04, pitch = 0.03, roll = 0 }, GLIDE)
    end)
  end,
}
