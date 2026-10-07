-- Yumion promo, scene 4 (9.0-13.1s): "Price and health, on one card." The card pops, both numbers count to
-- their scores, and the verdicts tick in. Precomp of promo.lua. 1080x1920, 120 bpm: a beat is 0.5s.
local e = require("moonsplice")
local FONT = "/Users/shinyobjectz/.cache/moonsplice/fonts/"
local INK, INK2, PAPER, LEAF, GOOD = "#24221D", "#5E594D", "#F8F6EF", "#7FA848", "#2C7A35"
local HEAVY, SEMI, MED = FONT .. "SF-Heavy.ttf", FONT .. "SF-Semibold.ttf", FONT .. "SF-Medium.ttf"

return e.comp {
  width = 1080, height = 1920, duration = 4.1, fps = 30, background = PAPER, lint_allow = { "blank_frame" },

  nodes = {
    { id = "h1", kind = "text", x = 540, y = 250, anchor = "center", text = "Price and health,", size = 120,
      font = HEAVY, color = INK, tracking = -5, opacity = 0 },
    { id = "swipe", kind = "rect", x = 250, y = 418, w = 2, h = 30, rx = 15, color = LEAF, rotation = -0.015, opacity = 0 },
    { id = "h2", kind = "text", x = 540, y = 380, anchor = "center", text = "on one card.", size = 120,
      font = HEAVY, color = INK, tracking = -5, opacity = 0 },

    -- the card: a group so it pops as one; parts relative to its centre
    { id = "card", kind = "group", x = 540, y = 1060, scale = 0 },
    { id = "c_shadow", kind = "rect", parent = "card", x = -444, y = -214, w = 912, h = 452, rx = 40, color = INK },
    { id = "c_edge", kind = "rect", parent = "card", x = -458, y = -228, w = 912, h = 452, rx = 40, color = INK },
    { id = "c_fill", kind = "rect", parent = "card", x = -450, y = -220, w = 896, h = 436, rx = 34, color = PAPER },
    { id = "l_price", kind = "text", parent = "card", x = -400, y = -180, text = "PRICE", size = 54, font = SEMI,
      color = INK2, tracking = 6 },
    { id = "l_health", kind = "text", parent = "card", x = 128, y = -180, text = "HEALTH", size = 54, font = SEMI,
      color = INK2, tracking = 6 },
    { id = "price", kind = "text", parent = "card", x = -405, y = -110, text = "$9.99", size = 190, font = HEAVY,
      color = INK, tracking = -6 },
    { id = "health", kind = "text", parent = "card", x = 168, y = -110, text = "0", size = 190, font = HEAVY,
      color = INK, tracking = -6 },
    { id = "v_price", kind = "text", parent = "card", x = -400, y = 110, text = "Good value · 100", size = 58,
      font = SEMI, color = GOOD, opacity = 0 },
    { id = "v_health", kind = "text", parent = "card", x = 228, y = 110, text = "Good", size = 58, font = SEMI,
      color = GOOD, opacity = 0 },

    -- a stamp in the corner, and what was scanned
    { id = "stamp", kind = "group", x = 975, y = 1290, scale = 0, rotation = 0.3 },
    { id = "st_edge", kind = "circle", parent = "stamp", x = 0, y = 0, r = 74, color = INK },
    { id = "st_fill", kind = "circle", parent = "stamp", x = 0, y = 0, r = 66, color = LEAF },
    { id = "st_oni", kind = "svg", parent = "stamp", src = "comps/yumion/oni.svg", x = 0, y = -4, w = 100, h = 100,
      anchor = "center" },
    { id = "what", kind = "text", x = 540, y = 1440, anchor = "center", text = "Oaty O's · 12 oz · shelf at Target",
      size = 56, font = MED, color = INK2, opacity = 0 },
  },

  keys = {
    { "h1", "opacity", 0.1, 0 }, { "h1", "opacity", 0.15, 1 }, { "h1", "y", 0.1, 200 }, { "h1", "y", 0.35, 250, "backOut" },
    { "h2", "opacity", 0.5, 0 }, { "h2", "opacity", 0.55, 1 }, { "h2", "y", 0.5, 330 }, { "h2", "y", 0.75, 380, "backOut" },
    { "swipe", "opacity", 0.8, 0 }, { "swipe", "opacity", 0.82, 1 }, { "swipe", "w", 0.8, 2 }, { "swipe", "w", 1.15, 590, "expoOut" },
    -- the card pops on beat two, then counts for two beats
    { "card", "scale", 0.5, 0 }, { "card", "scale", 1.0, 1, "spring(240,13)" },
    { "card", "rotation", 0.5, -0.15 }, { "card", "rotation", 1.0, 0, "backOut" },
    { "v_price", "opacity", 2.1, 0 }, { "v_price", "opacity", 2.3, 1, "sineOut" },
    { "v_price", "y", 2.1, 140 }, { "v_price", "y", 2.4, 110, "backOut" },
    { "v_health", "opacity", 2.35, 0 }, { "v_health", "opacity", 2.55, 1, "sineOut" },
    { "v_health", "y", 2.35, 140 }, { "v_health", "y", 2.65, 110, "backOut" },
    { "card", "scale", 2.0, 1 }, { "card", "scale", 2.08, 1.04, "quadOut" }, { "card", "scale", 2.3, 1, "quadOut" },
    { "stamp", "scale", 2.5, 0 }, { "stamp", "scale", 2.9, 1, "spring(300,12)" },
    { "stamp", "rotation", 2.5, 0.6 }, { "stamp", "rotation", 3.0, -0.12, "backOut" },
    { "what", "opacity", 2.7, 0 }, { "what", "opacity", 3.0, 1, "sineOut" },
  },

  systems = {
    -- both numbers run from 1.0s to 2.0s, eased out, and land together
    { name = "count", order = 1, source = [[
      return function(t)
        local k = ease("expoOut", clamp((t - 1.0) / 1.0, 0, 1))
        local cents = math.floor(lerp(999, 399, k) + 0.5)
        local score = math.floor(lerp(0, 72, k) + 0.5)
        return { { id = "price", text = string.format("$%d.%02d", math.floor(cents / 100), cents % 100) },
                 { id = "health", text = tostring(score) } }
      end ]] },
  },
}
