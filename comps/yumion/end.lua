-- Yumion promo, scene 7 (19.0-22.0s): the end card. Oni, the name, the line, and where to get it.
-- Precomp of promo.lua. 1080x1920, 120 bpm: a beat is 0.5s.
local e = require("moonsplice")
local FONT = "/Users/shinyobjectz/.cache/moonsplice/fonts/"
local INK, INK2, PAPER, LEAF = "#24221D", "#5E594D", "#F8F6EF", "#7FA848"
local HEAVY, SEMI, MED = FONT .. "SF-Heavy.ttf", FONT .. "SF-Semibold.ttf", FONT .. "SF-Medium.ttf"

return e.comp {
  width = 1080, height = 1920, duration = 3.0, fps = 30, background = PAPER, lint_allow = { "blank_frame" },

  nodes = {
    { id = "oni", kind = "group", x = 540, y = 640, scale = 0 },
    { id = "oni_shadow", kind = "circle", parent = "oni", x = 14, y = 14, r = 196, color = INK },
    { id = "oni_ring", kind = "circle", parent = "oni", x = 0, y = 0, r = 196, color = INK },
    { id = "oni_disc", kind = "circle", parent = "oni", x = 0, y = 0, r = 182, color = LEAF },
    { id = "oni_face", kind = "svg", parent = "oni", src = "comps/yumion/oni.svg", x = 0, y = -6, w = 270, h = 270,
      anchor = "center" },

    { id = "name", kind = "text", x = 540, y = 1020, anchor = "center", text = "yumion", size = 230,
      font = HEAVY, color = INK, tracking = -9, opacity = 0 },
    { id = "swipe", kind = "rect", x = 230, y = 1222, w = 2, h = 26, rx = 13, color = LEAF, rotation = -0.01, opacity = 0 },
    { id = "line", kind = "text", x = 540, y = 1190, anchor = "center", text = "Price and health, on one card.",
      size = 62, font = SEMI, color = INK, opacity = 0 },

    { id = "cta", kind = "group", x = 540, y = 1420, scale = 0 },
    { id = "cta_shadow", kind = "rect", parent = "cta", x = -330, y = -66, w = 672, h = 140, rx = 70, color = LEAF },
    { id = "cta_fill", kind = "rect", parent = "cta", x = -342, y = -78, w = 672, h = 140, rx = 70, color = INK },
    { id = "cta_text", kind = "text", parent = "cta", x = -6, y = -8, anchor = "center", text = "Free on the App Store",
      size = 58, font = HEAVY, color = PAPER, tracking = -1 },

    { id = "url", kind = "text", x = 540, y = 1600, anchor = "center", text = "yumion.com", size = 62,
      font = MED, color = INK2, opacity = 0 },
  },

  keys = {
    { "oni", "scale", 0.05, 0 }, { "oni", "scale", 0.5, 1, "spring(240,12)" },
    { "oni", "rotation", 0.05, 0.6 }, { "oni", "rotation", 0.6, 0, "backOut" },
    { "name", "opacity", 0.4, 0 }, { "name", "opacity", 0.5, 1 },
    { "name", "y", 0.4, 1080 }, { "name", "y", 0.8, 1020, "expoOut" },
    { "line", "opacity", 0.8, 0 }, { "line", "opacity", 1.0, 1, "sineOut" },
    { "swipe", "opacity", 1.0, 0 }, { "swipe", "opacity", 1.02, 1 },
    { "swipe", "w", 1.0, 2 }, { "swipe", "w", 1.35, 620, "expoOut" },
    { "cta", "scale", 1.3, 0 }, { "cta", "scale", 1.7, 1, "spring(280,13)" },
    { "url", "opacity", 1.7, 0 }, { "url", "opacity", 2.0, 1, "sineOut" },
    -- Oni hops on beats five and six
    { "oni", "y", 2.0, 640 }, { "oni", "y", 2.15, 600, "quadOut" }, { "oni", "y", 2.4, 640, "bounceOut" },
    { "oni", "y", 2.5, 640 }, { "oni", "y", 2.65, 600, "quadOut" }, { "oni", "y", 2.9, 640, "bounceOut" },
  },
}
