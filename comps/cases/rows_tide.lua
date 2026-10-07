-- Rows form (.robot/docs/rows.robot): one waterline keyed like a tide, an almanac line that a system keeps on
-- it, a title whose arrival is bound to the music's first beat, and a buoy in a Bevy world, all rows.
local e = require("moonsplice")
local F = "/Users/shinyobjectz/cadence/evals/assets/fonts/"

return e.comp {
  width = 1280, height = 720, duration = 6, fps = 30, background = "#0b1a22",

  assets = {
    { id = "bed", src = "/Users/shinyobjectz/cadence/evals/longform/Sound/music-bed.mp3", derive = { beats = true } },
  },

  nodes = {
    { id = "sky", kind = "rect", x = 0, y = 0, w = 1280, h = 720, color = "#0b1a22" },
    { id = "w", kind = "world", x = 0, y = 0, w = 1280, h = 720, cam_y = 0.6, cam_z = 6, sky = "#0b1a22" },
    { id = "buoy", kind = "mesh", parent = "w", primitive = "cylinder", x = 0, y = 0.2, z = 0, sx = 0.35, sy = 1.1, sz = 0.35, color = "#c0392b" },
    { id = "sun", kind = "light", parent = "w", dir = { 0.4, -1, 0.3 }, intensity = 2 },
    { id = "water", kind = "rect", x = 0, y = 470, w = 1280, h = 250, color = "#123544", opacity = 0.92 },
    { id = "line", kind = "rect", x = 0, y = 470, w = 1280, h = 2, color = "#f4efe6" },
    { id = "almanac", kind = "text", x = 96, y = 430, text = "04:12  LW  0.6 m", size = 30,
      font = F .. "BarlowCondensed-SemiBold.ttf", color = "#f4efe6", tracking = 2 },
    { id = "title", kind = "text", x = 96, y = 560, text = "every tide comes back", size = 54,
      font = F .. "InstrumentSerif-Italic.ttf", color = "#f4efe6" },
  },

  keys = {
    { "line", "y", 0, 470 }, { "line", "y", 3, 300, "sineInOut" }, { "line", "y", 6, 470, "sineInOut" },
    { "title", "opacity", 0, 0 }, { "title", "opacity", "beat:2", 0 }, { "title", "opacity", "beat:4", 1, "expoOut" },
  },

  systems = {
    { name = "water-follows-line", order = 1, source = [[
      return function(t, state, q)
        local y = q.y("line")
        return {
          { id = "water", y = y, h = 720 - y },
          { id = "almanac", y = y - 40 },
        }
      end ]] },
  },
}
