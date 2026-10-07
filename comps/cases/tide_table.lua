-- Tide Table, the video eval's seed (rows form, .robot/docs/rows.robot). Harbour footage at dusk with a slow
-- push; an almanac whose four tides arrive on the music's beats; and beside it the harbour mouth in
-- Bevy: a can buoy on its mooring chain riding the tide below the harbour wall, its lamp flashing
-- Fl R 4s, the wall's tide staff behind it, swell crests running in under a sunset matched to the
-- footage. The water level follows the almanac's curve, and the 2D gauge bar follows the water.
local e = require("moonsplice")
local F = "/Users/shinyobjectz/cadence/evals/assets/fonts/"
local FOOT = "/Users/shinyobjectz/cadence/evals/longform/Footage/"
local SOUND = "/Users/shinyobjectz/cadence/evals/longform/Sound/"

return e.comp {
  width = 1280, height = 720, duration = 8, fps = 30, background = "#081218",

  assets = {
    { id = "bed", src = SOUND .. "music-bed.mp3", derive = { beats = true } },
  },

  nodes = {
    { id = "harbour", kind = "video", src = FOOT .. "07-harbour-sunset-boats.mp4", x = 640, y = 360, w = 1280, h = 720,
      anchor = "center", media_start = 22 },
    { id = "shade", kind = "rect", x = 0, y = 0, w = 1280, h = 720, color = "#081218", opacity = 0.45 },

    -- the almanac
    { id = "field", kind = "rect", x = 64, y = 64, w = 560, h = 592, color = "#081218f2", rx = 6 },
    { id = "kicker", kind = "text", x = 104, y = 104, text = "TIDE TABLE  ·  MOUSEHOLE", size = 20,
      font = F .. "BarlowCondensed-Medium.ttf", color = "#f2a541", tracking = 3 },
    { id = "date", kind = "text", x = 104, y = 140, text = "Tuesday 7 October", size = 64,
      font = F .. "InstrumentSerif-Regular.ttf", color = "#f4efe6" },
    { id = "rule", kind = "rect", x = 104, y = 236, w = 2, h = 2, color = "#f2a541" },
    { id = "t1", kind = "text", x = 104, y = 268, text = "04:12   LOW    0.6 m", size = 40,
      font = F .. "IBMPlexMono-Regular.ttf", color = "#f4efe6", opacity = 0 },
    { id = "t2", kind = "text", x = 104, y = 352, text = "10:31   HIGH   4.1 m", size = 40,
      font = F .. "IBMPlexMono-Regular.ttf", color = "#f4efe6", opacity = 0 },
    { id = "t3", kind = "text", x = 104, y = 436, text = "16:40   LOW    0.8 m", size = 40,
      font = F .. "IBMPlexMono-Regular.ttf", color = "#f4efe6", opacity = 0 },
    { id = "t4", kind = "text", x = 104, y = 520, text = "22:58   HIGH   3.9 m", size = 40,
      font = F .. "IBMPlexMono-Regular.ttf", color = "#f4efe6", opacity = 0 },
    { id = "now", kind = "rect", x = 84, y = 268, w = 6, h = 44, color = "#f2a541", opacity = 0 },

    -- the harbour mouth
    { id = "gauge", kind = "world", x = 656, y = 64, w = 560, h = 592, rx = 6,
      cam_x = 2.6, cam_y = 2.3, cam_z = 8.4, look_x = -0.2, look_y = 1.0, look_z = -1.5, fov = 0.55,
      background = "#1a1418", ambient = 260, ambient_color = "#9ab8d0", bloom = 0.16, tonemapping = "agx",
      fog = { color = "#2a1f22", start = 7, ["end"] = 26 } },
    { id = "sky", kind = "mesh", parent = "gauge", primitive = "plane", size = { 60, 1, 14 }, y = 2, z = -20,
      pitch = 1.5708, color = "#c8642e", emissive = "#c8642e", emissive_strength = 1.4, unlit = true },
    { id = "sea", kind = "mesh", parent = "gauge", primitive = "plane", size = { 40, 1, 40 }, y = 0,
      color = "#24505f", metallic = 0.2, roughness = 0.1 },
    { id = "wall", kind = "mesh", parent = "gauge", primitive = "box", size = { 24, 3, 1.6 }, y = 0, z = -7.5,
      color = "#3b3834", roughness = 0.95 },
    { id = "coping", kind = "mesh", parent = "gauge", primitive = "box", size = { 24.2, 0.16, 1.8 }, y = 1.58, z = -7.5,
      color = "#6b665d", roughness = 0.85 },
    { id = "staff", kind = "mesh", parent = "gauge", primitive = "box", size = { 0.22, 2.4, 0.06 }, x = 0.9, y = 0.3, z = -6.67,
      color = "#d9d2c3", roughness = 0.95 },
    { id = "post", kind = "mesh", parent = "gauge", primitive = "cylinder", size = { 0.08, 1.6, 0.08 }, x = -3.2, y = 2.45, z = -7.2,
      color = "#22262a", metallic = 0.7, roughness = 0.4 },
    { id = "lantern", kind = "mesh", parent = "gauge", primitive = "sphere", scale = 0.22, x = -3.2, y = 3.3, z = -7.2,
      color = "#ffcf8a", emissive = "#ffb35c", emissive_strength = 14 },
    { id = "body", kind = "mesh", parent = "gauge", primitive = "cylinder", size = { 0.9, 1.2, 0.9 },
      color = "#b8322a", roughness = 0.45 },
    { id = "band", kind = "mesh", parent = "body", y = 0.27, primitive = "cylinder", size = { 0.93, 0.2, 0.93 },
      color = "#ece6da", roughness = 0.5 },
    { id = "topmark", kind = "mesh", parent = "body", y = 0.9, primitive = "cone", size = { 0.42, 0.55, 0.42 },
      color = "#b8322a", roughness = 0.45 },
    { id = "lamp", kind = "mesh", parent = "body", y = 1.27, primitive = "sphere", scale = 0.15,
      color = "#ff5a3d", emissive = "#ff5a3d", emissive_strength = 0 },
    { id = "sun", kind = "light", parent = "gauge", dir = { 0.35, -0.22, 0.9 }, intensity = 0.8, color = "#ffb27a" },
    { id = "fill", kind = "light", parent = "gauge", dir = { -0.4, -0.55, -0.75 }, intensity = 0.9, color = "#9ab8d0" },

    { id = "level", kind = "rect", x = 1232, y = 64, w = 6, h = 592, color = "#24505f" },
    { id = "mark", kind = "rect", x = 1226, y = 400, w = 18, h = 3, color = "#f2a541" },
    { id = "band2d", kind = "rect", x = 656, y = 600, w = 560, h = 56, color = "#081218f2" },
    { id = "caption", kind = "text", x = 680, y = 614, text = "Harbour mouth  ·  chart datum  ·  Fl R 4s", size = 24,
      font = F .. "BarlowCondensed-Medium.ttf", color = "#e9e1cf", tracking = 1 },
    { id = "music", kind = "audio", src = SOUND .. "music-bed.mp3", at = 0, duration = 8, volume = 0.7,
      fade_in = 0.4, fade_out = 1.2 },
  },

  -- what this piece is, whatever an edit does to it: the almanac and its four tides, high water
  -- shown by the end, and the buoy's lamp keeping its light (lint: expect_failed)
  expect = {
    { id = "almanac", says = "the almanac panel is there", node = "field" },
    { id = "tide-1", says = "the 04:12 low water row reads", node = "t1", prop = "text", op = "has", value = "04:12" },
    { id = "tide-2", says = "the 10:31 high water row reads", node = "t2", prop = "text", op = "has", value = "10:31" },
    { id = "tide-3", says = "the 16:40 low water row reads", node = "t3", prop = "text", op = "has", value = "16:40" },
    { id = "tide-4", says = "the 22:58 high water row reads", node = "t4", prop = "text", op = "has", value = "22:58" },
    { id = "high-shown", says = "the 22:58 row is on screen at high water", node = "t4", prop = "opacity", at = 8, op = ">=", value = 0.9 },
    { id = "lamp-flashes", says = "the buoy's lamp flashes (Fl R 4s)", node = "lamp", prop = "emissive_strength", t0 = 0, t1 = 8, holds = "ever", op = ">", value = 1 },
    { id = "harbour-mouth", says = "the harbour mouth is in 3D", node = "gauge" },
  },

  keys = {
    { "harbour", "scale", 0.2, 1 }, { "harbour", "scale", 8, 1.08, "sineInOut" },
    { "rule", "w", 0.3, 2 }, { "rule", "w", 1.2, 480, "expoOut" },
    { "t1", "opacity", "beat:2", 0 }, { "t1", "opacity", "beat:3", 1, "cubicOut" },
    { "t2", "opacity", "beat:4", 0 }, { "t2", "opacity", "beat:5", 1, "quadOut" },
    { "t3", "opacity", "beat:6", 0 }, { "t3", "opacity", "beat:7", 1, "sineOut" },
    { "t4", "opacity", "beat:8", 0 }, { "t4", "opacity", "beat:9", 1, "expoOut" },
    { "now", "opacity", "beat:9", 0 }, { "now", "opacity", "beat:10", 1, "cubicOut" },
    { "now", "y", "beat:10", 268 }, { "now", "y", "beat:14", 352, "cubicInOut" },
    { "gauge", "cam_x", 0.2, 2.4 }, { "gauge", "cam_x", 8, 1.2, "sineInOut" },
    { "gauge", "cam_z", 0.2, 8.4 }, { "gauge", "cam_z", 8, 7.6, "sineInOut" },
  },

  systems = {
    { name = "shared", order = 0, source = [[
      -- the tide as the almanac states it: low water at 0 s rising to high water at 8 s, metres of rise
      local S = {}
      function S.tide(t) return 0.5 - 0.5 * math.cos(math.pi * math.min(1, t / 8)) end
      S.RISE = 1.3
      return S ]] },
    { name = "harbour-mouth", order = 1, source = [[
      return function(t)
        local level = shared.tide(t) * shared.RISE
        local bob = 0.07 * math.sin(t * 2.1) + 0.03 * math.sin(t * 3.7 + 1)
        local lean = 0.05 * math.sin(t * 1.7)   -- the buoy leans as one piece, about its waterline
        local y = level + bob
        local flash = ((t % 4) < 0.5) and 10 or 0          -- Fl R 4s
        local rows = {
          { id = "sea", y = level },
          -- the body pivots about the waterline (0.35 below its centre); band, topmark and lamp are its
          -- children, so they lean with it. A positive roll tips the top toward -x.
          { id = "body", x = -math.sin(lean) * 0.35, y = y + math.cos(lean) * 0.35, roll = lean },
          { id = "lamp", emissive_strength = flash },
          { id = "glow", parent = "gauge", light = "point", pos = { -math.sin(lean) * 1.7, y + math.cos(lean) * 1.7, 0 }, color = "#ff5a3d",
            intensity = flash > 0 and 90000 or 0, range = 7 },
          { id = "quaylight", parent = "gauge", light = "point", pos = { -3.2, 3.1, -6.6 }, color = "#ffb35c",
            intensity = 140000, range = 10, shadows = true },
        }
        -- the staff's metre bands, 0 to 5 m from chart datum
        for m = 0, 5 do
          rows[#rows + 1] = { id = "mband" .. m, parent = "gauge", shape = "box", pos = { 0.9, -0.8 + m * 0.4, -6.63 },
            size = { 0.23, 0.05, 0.02 }, color = "#b8322a" }
        end
        -- the mooring chain: links from the buoy's foot down into the water, hanging toward the wall
        for k = 1, 9 do
          local d = k * 0.17
          rows[#rows + 1] = { id = "link" .. k, parent = "gauge", shape = "torus",
            pos = { 0.05 * k, y - 0.28 - d, -0.12 * k }, scale = 0.09, yaw = (k % 2) * 1.5708, pitch = 1.5708,
            color = "#3a3530", metallic = 0.8, roughness = 0.5 }
        end
        -- swell crests running in toward the camera, and the sun's glint on the water
        for k = 0, 11 do
          local z = -6.5 + ((k * 0.7 + t * 0.6) % 8.4)
          local a = 0.5 + 0.5 * math.sin(t * 1.4 + k)
          rows[#rows + 1] = { id = "crest" .. k, parent = "gauge", shape = "box",
            pos = { math.sin(k * 2.3) * 1.5, level + 0.015, z }, size = { 5 + 3 * a, 0.015, 0.03 + 0.03 * a },
            color = "#2e5a68", roughness = 0.9, metallic = 0 }
        end
        for k = 0, 7 do
          local z = -15 + k * 0.9
          rows[#rows + 1] = { id = "glint" .. k, parent = "gauge", shape = "box",
            pos = { -1.6 + 0.3 * math.sin(t * 2 + k * 1.7), level + 0.02, z },
            size = { 0.25 + 0.5 * (0.5 + 0.5 * math.sin(t * 3.1 + k * 2.3)), 0.01, 0.9 },
            color = "#ff9a4d", emissive = "#ff9a4d", emissive_strength = 3, unlit = true }
        end
        return rows
      end ]] },
    { name = "gauge-bar", order = 2, source = [[
      return function(t)
        return { { id = "mark", y = 640 - 560 * shared.tide(t) } }
      end ]] },
  },
}
