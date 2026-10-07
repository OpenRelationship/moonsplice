-- Yumion promo, scene 2 (2.5-5.1s): "Groceries got pricey." A shelf tag keeps ticking up.
-- Precomp of promo.lua. 1080x1920, 120 bpm: a beat is 0.5s.
local e = require("moonsplice")
local FONT = "/Users/shinyobjectz/.cache/moonsplice/fonts/"
local INK, INK2, PAPER, TOMATO, CANARY = "#24221D", "#5E594D", "#F8F6EF", "#C8412B", "#F5C842"
local HEAVY = FONT .. "SF-Heavy.ttf"

return e.comp {
  width = 1080, height = 1920, duration = 2.6, fps = 30, background = PAPER, lint_allow = { "blank_frame" },

  nodes = {
    { id = "w1", kind = "text", x = 96, y = 470, text = "Groceries", size = 200, font = HEAVY, color = INK,
      tracking = -8, opacity = 0 },
    { id = "w2", kind = "text", x = 96, y = 680, text = "got", size = 200, font = HEAVY, color = INK,
      tracking = -8, opacity = 0 },
    { id = "w3", kind = "text", x = 96, y = 890, text = "pricey.", size = 200, font = HEAVY, color = TOMATO,
      tracking = -8, opacity = 0 },

    -- a shelf tag, tilted, with a hard ink shadow
    { id = "tag", kind = "group", x = 700, y = 1430, rotation = -0.12, scale = 0 },
    { id = "tag_shadow", kind = "rect", parent = "tag", x = -234, y = -124, w = 480, h = 260, rx = 34, color = INK },
    { id = "tag_edge", kind = "rect", parent = "tag", x = -246, y = -136, w = 480, h = 260, rx = 34, color = INK },
    { id = "tag_fill", kind = "rect", parent = "tag", x = -238, y = -128, w = 464, h = 244, rx = 28, color = CANARY },
    { id = "tag_hole", kind = "circle", parent = "tag", x = -206, y = -98, r = 14, color = INK },
    { id = "tag_price", kind = "text", parent = "tag", x = 16, y = 8, anchor = "center", text = "$3.49", size = 150,
      font = HEAVY, color = INK, tracking = -5 },

    { id = "aside", kind = "text", x = 96, y = 1700, text = "every week, somehow.", size = 60,
      font = FONT .. "SF-Medium.ttf", color = INK2, opacity = 0 },
  },

  keys = {
    -- one word a beat, each slammed in from a little high
    { "w1", "opacity", 0.15, 0 }, { "w1", "opacity", 0.2, 1 }, { "w1", "y", 0.15, 400 }, { "w1", "y", 0.4, 470, "backOut" },
    { "w2", "opacity", 0.65, 0 }, { "w2", "opacity", 0.7, 1 }, { "w2", "y", 0.65, 610 }, { "w2", "y", 0.9, 680, "backOut" },
    { "w3", "opacity", 1.15, 0 }, { "w3", "opacity", 1.2, 1 }, { "w3", "y", 1.15, 820 }, { "w3", "y", 1.4, 890, "backOut" },
    { "w3", "rotation", 1.4, 0 }, { "w3", "rotation", 1.5, -0.04, "quadOut" }, { "w3", "rotation", 1.6, 0.03, "quadInOut" },
    { "w3", "rotation", 1.7, 0, "quadOut" },
    -- the tag swings in on the off beat and jolts each time the price goes up
    { "tag", "scale", 0.9, 0 }, { "tag", "scale", 1.3, 1, "spring(260,12)" },
    { "tag", "rotation", 0.9, 0.3 }, { "tag", "rotation", 1.4, -0.12, "backOut" },
    { "tag", "scale", 1.6, 1 }, { "tag", "scale", 1.65, 1.08, "quadOut" }, { "tag", "scale", 1.8, 1, "quadOut" },
    { "tag", "scale", 2.1, 1 }, { "tag", "scale", 2.15, 1.1, "quadOut" }, { "tag", "scale", 2.3, 1, "quadOut" },
    { "aside", "opacity", 1.9, 0 }, { "aside", "opacity", 2.2, 1, "sineOut" },
  },

  systems = {
    { name = "inflation", order = 1, source = [[
      return function(t)
        local price = t < 1.6 and "$3.49" or t < 2.1 and "$4.29" or "$5.49"
        return { { id = "tag_price", text = price } }
      end ]] },
  },
}
