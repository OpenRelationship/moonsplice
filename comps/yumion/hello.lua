-- Yumion promo, scene 1 (0.0-2.6s): Oni pops in, the name lands, "Scan any shelf".
-- Precomp of promo.lua. 1080x1920, 120 bpm: a beat is 0.5s.
local e = require("moonsplice")
local FONT = "/Users/shinyobjectz/.cache/moonsplice/fonts/" -- SF instances cut locally (see promo.lua)
local INK, PAPER, LEAF = "#24221D", "#F8F6EF", "#7FA848"

return e.comp {
  width = 1080, height = 1920, duration = 2.6, fps = 30, background = PAPER, lint_allow = { "blank_frame" },

  nodes = {
    { id = "oni", kind = "group", x = 540, y = 820, scale = 0 },
    { id = "oni_shadow", kind = "circle", parent = "oni", x = 14, y = 14, r = 176, color = INK },
    { id = "oni_ring", kind = "circle", parent = "oni", x = 0, y = 0, r = 176, color = INK },
    { id = "oni_disc", kind = "circle", parent = "oni", x = 0, y = 0, r = 162, color = LEAF },
    { id = "oni_face", kind = "svg", parent = "oni", src = "comps/yumion/oni.svg", x = 0, y = -6, w = 240, h = 240,
      anchor = "center" },

    { id = "name", kind = "text", x = 540, y = 1180, anchor = "center", text = "yumion", size = 230,
      font = FONT .. "SF-Heavy.ttf", color = INK, tracking = -9, opacity = 0, scale = 0.7 },

    { id = "chip", kind = "group", x = 540, y = 1400, scale = 0 },
    { id = "chip_shadow", kind = "rect", parent = "chip", x = -246, y = -46, w = 500, h = 104, rx = 52, color = INK },
    { id = "chip_edge", kind = "rect", parent = "chip", x = -254, y = -54, w = 500, h = 104, rx = 52, color = INK },
    { id = "chip_fill", kind = "rect", parent = "chip", x = -248, y = -48, w = 488, h = 92, rx = 46, color = PAPER },
    { id = "chip_dot", kind = "circle", parent = "chip", x = -186, y = -2, r = 30, color = LEAF },
    { id = "chip_oni", kind = "svg", parent = "chip", src = "comps/yumion/oni.svg", x = -186, y = -4, w = 44, h = 44,
      anchor = "center" },
    { id = "chip_text", kind = "text", parent = "chip", x = 30, y = -2, anchor = "center", text = "Scan any shelf",
      size = 56, font = FONT .. "SF-Semibold.ttf", color = INK },
  },

  keys = {
    -- Oni lands on the first beat with a springy overshoot, then bobs on each beat
    { "oni", "scale", 0.1, 0 }, { "oni", "scale", 0.6, 1, "spring(260,12)" },
    { "oni", "rotation", 0.1, -0.5 }, { "oni", "rotation", 0.7, 0, "backOut" },
    { "oni", "y", 1.0, 820 }, { "oni", "y", 1.15, 790, "quadOut" }, { "oni", "y", 1.4, 820, "bounceOut" },
    { "oni", "y", 1.5, 820 }, { "oni", "y", 1.65, 790, "quadOut" }, { "oni", "y", 1.9, 820, "bounceOut" },
    -- the name drops on beat two
    { "name", "opacity", 0.5, 0 }, { "name", "opacity", 0.62, 1 },
    { "name", "scale", 0.5, 0.7 }, { "name", "scale", 0.95, 1, "spring(240,13)" },
    { "name", "y", 0.5, 1240 }, { "name", "y", 0.95, 1180, "expoOut" },
    -- the chip pops on beat three
    { "chip", "scale", 1.0, 0 }, { "chip", "scale", 1.45, 1, "spring(280,13)" },
    { "chip", "rotation", 1.0, 0.12 }, { "chip", "rotation", 1.5, -0.02, "backOut" },
  },
}
