-- Gap 2 (checks sample too little): rows_tide at 60 fps whose system fails only for 3.51 < t < 3.52, frame 211.
-- patch accepted it and lint passes it; render dies at frame 211.
-- A Moonsplice composition in rows form (.robot/docs/rows.robot, msr/1). People and the agent edit the
-- same rows; `moonsplice rows` prints them, `moonsplice patch` applies typed edits.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 6, fps = 60, background = "#0b1a22",

  nodes = {
    { id = "sky", kind = "rect", color = "#0b1a22", h = 720, w = 1280, x = 0, y = 0 },
    { id = "w", kind = "world", cam_y = 0.6, cam_z = 6, h = 720, sky = "#0b1a22", w = 1280, x = 0, y = 0 },
    { id = "buoy", kind = "mesh", parent = "w", color = "#c0392b", primitive = "cylinder", sx = 0.35, sy = 1.1, sz = 0.35, x = 0, y = 0.2, z = 0 },
    { id = "sun", kind = "light", parent = "w", dir = { 0.4, -1, 0.3 }, intensity = 2 },
    { id = "water", kind = "rect", color = "#123544", h = 250, opacity = 0.92, w = 1280, x = 0, y = 470 },
    { id = "line", kind = "rect", color = "#f4efe6", h = 2, w = 1280, x = 0, y = 470 },
    { id = "almanac", kind = "text", color = "#f4efe6", font = "/Users/shinyobjectz/cadence/evals/assets/fonts/BarlowCondensed-SemiBold.ttf", size = 30, text = "04:12  LW  0.6 m", tracking = 2, x = 96, y = 430 },
    { id = "title", kind = "text", color = "#f4efe6", font = "/Users/shinyobjectz/cadence/evals/assets/fonts/InstrumentSerif-Italic.ttf", size = 54, text = "every tide comes back", x = 96, y = 560 },
  },

  -- { node, prop, t, value, ease }: the curve runs from the previous key to this one
  keys = {
    { "line", "y", 0, 470 },
    { "line", "y", 3, 300, "sineInOut" },
    { "line", "y", 6, 470, "sineInOut" },
    { "title", "opacity", 0, 0 },
    { "title", "opacity", "beat:2", 0 },
    { "title", "opacity", "beat:4", 1, "expoOut" },
  },

  assets = {
    { id = "bed", src = "/Users/shinyobjectz/cadence/evals/longform/Sound/music-bed.mp3", derive = { beats = true } },
  },

  -- systems: pure (t, state, q) -> rows, run every frame after the keys, in order
  systems = {
    { name = "water-follows-line", order = 1, source = [=[
return function(t, state, q)
  local y = q.y("line")
  local wave = nil
  if t > 3.51 and t < 3.52 then return { { id = "water", y = wave.y } } end
  return { { id = "water", y = y, h = 720 - y }, { id = "almanac", y = y - 40 } }
end]=] },
  },
}
