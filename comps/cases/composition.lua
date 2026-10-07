-- Composition (.robot/docs/rows.robot, "Composition"), in rows form: a reel (a track of three clips joined by a
-- crossfade and a wipe), a clip whose speed ramps while it loops, two fading groups of overlapping
-- circles (one plain, one isolated), a precomp instanced twice at different times and speeds, and
-- stripes seen through a text matte.
local e = require("moonsplice")
local F = "/Users/shinyobjectz/cadence/evals/assets/fonts/"

return e.comp {
  width = 1280, height = 720, duration = 8, fps = 30, background = "#0b1a22",

  nodes = {
    -- the reel: a track lays its clips end to end; the track's crossfade joins dawn and noon, and
    -- dusk brings its own wipe
    { id = "reel", kind = "track", x = 40, y = 40, w = 720, h = 405,
      transition = { kind = "crossfade", duration = 0.6 } },
    { id = "dawn", kind = "clip", parent = "reel", duration = 3.2 },
    { id = "dawn_bg", kind = "rect", parent = "dawn", x = 0, y = 0, w = 720, h = 405, color = "#1b3a4e" },
    { id = "dawn_sun", kind = "circle", parent = "dawn", x = 540, y = 300, r = 46, color = "#f2a541" },
    { id = "dawn_title", kind = "text", parent = "dawn", x = 48, y = 280, text = "Dawn", size = 84,
      font = F .. "InstrumentSerif-Italic.ttf", color = "#f4efe6" },
    { id = "noon", kind = "clip", parent = "reel", duration = 3 },
    { id = "noon_bg", kind = "rect", parent = "noon", x = 0, y = 0, w = 720, h = 405, color = "#4a2b14" },
    { id = "noon_wake", kind = "rect", parent = "noon", x = 0, y = 300, w = 80, h = 4, color = "#f4efe6", opacity = 0.6 },
    { id = "noon_boat", kind = "rect", parent = "noon", x = -120, y = 268, w = 120, h = 32, color = "#f4efe6", rx = 6 },
    { id = "noon_title", kind = "text", parent = "noon", x = 48, y = 60, text = "Noon", size = 84,
      font = F .. "InstrumentSerif-Italic.ttf", color = "#f4efe6" },
    { id = "dusk", kind = "clip", parent = "reel", duration = 2.9,
      transition = { kind = "wipe", duration = 0.5, dir = "right" } },
    { id = "dusk_bg", kind = "rect", parent = "dusk", x = 0, y = 0, w = 720, h = 405, color = "#3b2a4f" },
    { id = "dusk_moon", kind = "circle", parent = "dusk", x = 600, y = 160, r = 30, color = "#e8e4f0" },
    { id = "dusk_title", kind = "text", parent = "dusk", x = 48, y = 280, text = "Dusk", size = 84,
      font = F .. "InstrumentSerif-Italic.ttf", color = "#f4efe6" },

    -- a speed ramp: the clip's speed is keyed in comp time and integrated; the ball crosses its lane
    -- once every two local seconds, so it crawls, races, then slows
    { id = "ramp_label", kind = "text", x = 820, y = 24, text = "speed 0.3 → 2.4 → 0.6, looping", size = 24,
      font = F .. "JetBrainsMono-Regular.ttf", color = "#d5e0e6" },
    { id = "ramp", kind = "clip", x = 820, y = 70, start = 0.2, duration = 7.6, loop = true, length = 2 },
    { id = "ramp_lane", kind = "rect", parent = "ramp", x = 0, y = 28, w = 400, h = 4, color = "#2c5468" },
    { id = "ramp_ball", kind = "circle", parent = "ramp", x = 10, y = 30, r = 16, color = "#f2a541" },

    -- isolation: both groups fade together; only the isolated one fades as one picture, so its
    -- circles do not show through each other
    { id = "plain_label", kind = "text", x = 820, y = 150, text = "group", size = 24,
      font = F .. "JetBrainsMono-Regular.ttf", color = "#d5e0e6" },
    { id = "iso_label", kind = "text", x = 1050, y = 150, text = "isolate = true", size = 24,
      font = F .. "JetBrainsMono-Regular.ttf", color = "#d5e0e6" },
    { id = "plain", kind = "group", x = 900, y = 262 },
    { id = "plain_a", kind = "circle", parent = "plain", x = -30, y = -15, r = 50, color = "#e05a47" },
    { id = "plain_b", kind = "circle", parent = "plain", x = 30, y = -15, r = 50, color = "#f2a541" },
    { id = "plain_c", kind = "circle", parent = "plain", x = 0, y = 35, r = 50, color = "#4fa8f2" },
    { id = "iso", kind = "group", x = 1130, y = 262, isolate = true },
    { id = "iso_a", kind = "circle", parent = "iso", x = -30, y = -15, r = 50, color = "#e05a47" },
    { id = "iso_b", kind = "circle", parent = "iso", x = 30, y = -15, r = 50, color = "#f2a541" },
    { id = "iso_c", kind = "circle", parent = "iso", x = 0, y = 35, r = 50, color = "#4fa8f2" },

    -- a precomp, twice: card1 plays the card once; card2 starts later at 1.5x and holds its last frame
    { id = "cards_label", kind = "text", x = 820, y = 380, text = "precomp × 2", size = 24,
      font = F .. "JetBrainsMono-Regular.ttf", color = "#d5e0e6" },
    { id = "card1", kind = "precomp", src = "composition_card.lua", x = 820, y = 420, start = 0.4 },
    { id = "card2", kind = "precomp", src = "composition_card.lua", x = 820, y = 570, start = 3.8, speed = 1.5, hold = "end" },

    -- a track matte: the stripes show only through the letters of TIDE (its alpha)
    { id = "word", kind = "text", x = 40, y = 452, text = "TIDE", size = 220,
      font = F .. "BarlowCondensed-SemiBold.ttf", color = "#ffffff" },
    { id = "waves", kind = "group", x = 0, y = 0, matte = "word" },
    { id = "wave1", kind = "rect", parent = "waves", x = 0, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave2", kind = "rect", parent = "waves", x = 36, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave3", kind = "rect", parent = "waves", x = 72, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave4", kind = "rect", parent = "waves", x = 108, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave5", kind = "rect", parent = "waves", x = 144, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave6", kind = "rect", parent = "waves", x = 180, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave7", kind = "rect", parent = "waves", x = 216, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave8", kind = "rect", parent = "waves", x = 252, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave9", kind = "rect", parent = "waves", x = 288, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave10", kind = "rect", parent = "waves", x = 324, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave11", kind = "rect", parent = "waves", x = 360, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave12", kind = "rect", parent = "waves", x = 396, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave13", kind = "rect", parent = "waves", x = 432, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave14", kind = "rect", parent = "waves", x = 468, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave15", kind = "rect", parent = "waves", x = 504, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave16", kind = "rect", parent = "waves", x = 540, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave17", kind = "rect", parent = "waves", x = 576, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave18", kind = "rect", parent = "waves", x = 612, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "wave19", kind = "rect", parent = "waves", x = 648, y = 440, w = 36, h = 280, color = "#4fa8f2" },
    { id = "wave20", kind = "rect", parent = "waves", x = 684, y = 440, w = 36, h = 280, color = "#f4efe6" },
    { id = "matte_label", kind = "text", x = 500, y = 600, text = "alpha matte", size = 24,
      font = F .. "JetBrainsMono-Regular.ttf", color = "#d5e0e6" },
  },

  -- { node, prop, t, value, ease }: the curve runs from the previous key to this one. Keys on a
  -- clip's children are in its local time; keys on the clip itself (ramp.speed, card1.opacity) are
  -- in its parent's.
  keys = {
    { "dawn_sun", "y", 0.15, 300 }, { "dawn_sun", "y", 3.2, 150, "sineOut" },
    { "dawn_title", "x", 0.15, 90 }, { "dawn_title", "x", 1, 48, "expoOut" },
    { "noon_boat", "x", 0, -120 }, { "noon_boat", "x", 3, 720 },
    { "noon_title", "y", 0, 90 }, { "noon_title", "y", 1, 60, "expoOut" },
    { "dusk_moon", "y", 0, 170 }, { "dusk_moon", "y", 2.9, 90, "sineInOut" },
    { "dusk_title", "x", 0, 90 }, { "dusk_title", "x", 1, 48, "expoOut" },
    { "ramp", "speed", 0.2, 0.3 }, { "ramp", "speed", 4.6, 2.4, "sineInOut" }, { "ramp", "speed", 7.8, 0.6, "sineInOut" },
    { "ramp_ball", "x", 0, 10 }, { "ramp_ball", "x", 2, 390 },
    { "plain", "opacity", 0.2, 1 }, { "plain", "opacity", 2, 0.4, "sineInOut" }, { "plain", "opacity", 4, 1, "sineInOut" },
    { "plain", "opacity", 6, 0.4, "sineInOut" }, { "plain", "opacity", 7.8, 1, "sineInOut" },
    { "iso", "opacity", 0.2, 1 }, { "iso", "opacity", 2, 0.4, "sineInOut" }, { "iso", "opacity", 4, 1, "sineInOut" },
    { "iso", "opacity", 6, 0.4, "sineInOut" }, { "iso", "opacity", 7.8, 1, "sineInOut" },
    { "card1", "opacity", 3, 1 }, { "card1", "opacity", 3.4, 0, "sineIn" },
    { "waves", "x", 0.1, 0 }, { "waves", "x", 7.9, -144 },
  },

  -- systems: pure (t, state, q) -> rows, run every frame after the keys, in order
  systems = {
    -- runs in noon's local time, only while noon plays: the wake trails the boat and breathes
    { name = "noon-wake", order = 1, clip = "noon", source = [[
      return function(t, state, q)
        return { { id = "noon_wake", x = q.x("noon_boat") - 90, w = 80 + 20 * math.sin(t * 6) } }
      end ]] },
  },
}
