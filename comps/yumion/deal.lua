-- Yumion promo, scene 5 (13.0-16.6s): "Is it a good deal?" Four stores slide in with their price for the
-- same box; the cheapest lights up. Precomp of promo.lua. 1080x1920, 120 bpm: a beat is 0.5s.
local e = require("moonsplice")
local FONT = "/Users/shinyobjectz/.cache/moonsplice/fonts/"
local INK, INK2, PAPER, LEAF = "#24221D", "#5E594D", "#F8F6EF", "#7FA848"
local HEAVY, SEMI, MED = FONT .. "SF-Heavy.ttf", FONT .. "SF-Semibold.ttf", FONT .. "SF-Medium.ttf"

local nodes = {
  { id = "h1", kind = "text", x = 540, y = 250, anchor = "center", text = "Is it a", size = 150, font = HEAVY,
    color = INK, tracking = -6, opacity = 0 },
  { id = "swipe", kind = "rect", x = 170, y = 452, w = 2, h = 34, rx = 17, color = LEAF, rotation = -0.02, opacity = 0 },
  { id = "h2", kind = "text", x = 540, y = 400, anchor = "center", text = "good deal?", size = 150, font = HEAVY,
    color = INK, tracking = -6, opacity = 0 },
  { id = "note", kind = "text", x = 540, y = 1660, anchor = "center", text = "Every price scored 0-100",
    size = 58, font = MED, color = INK2, opacity = 0 },
  { id = "note2", kind = "text", x = 540, y = 1736, anchor = "center", text = "against stores near you.",
    size = 58, font = MED, color = INK2, opacity = 0 },
}
local keys = {
  { "h1", "opacity", 0.1, 0 }, { "h1", "opacity", 0.15, 1 }, { "h1", "y", 0.1, 200 }, { "h1", "y", 0.35, 250, "backOut" },
  { "h2", "opacity", 0.5, 0 }, { "h2", "opacity", 0.55, 1 }, { "h2", "y", 0.5, 350 }, { "h2", "y", 0.75, 400, "backOut" },
  { "swipe", "opacity", 0.8, 0 }, { "swipe", "opacity", 0.82, 1 },
  { "swipe", "w", 0.8, 2 }, { "swipe", "w", 1.15, 740, "expoOut" },
  { "note", "opacity", 2.4, 0 }, { "note", "opacity", 2.7, 1, "sineOut" },
  { "note2", "opacity", 2.5, 0 }, { "note2", "opacity", 2.8, 1, "sineOut" },
}

-- one row per store, sliding in from the right a quarter beat apart; the first is the best
local stores = { { "Target", "$3.99" }, { "Trader Joe's", "$4.29" }, { "Grocery Outlet", "$4.49" },
  { "Safeway", "$5.49" } }
for i, s in ipairs(stores) do
  local id, y, at = "row" .. i, 700 + (i - 1) * 210, 0.6 + (i - 1) * 0.12
  nodes[#nodes + 1] = { id = id, kind = "group", x = 540 + 1200, y = y }
  nodes[#nodes + 1] = { id = id .. "_shadow", kind = "rect", parent = id, x = -436, y = -72, w = 888, h = 160, rx = 30,
    color = INK }
  nodes[#nodes + 1] = { id = id .. "_edge", kind = "rect", parent = id, x = -448, y = -84, w = 888, h = 160, rx = 30,
    color = INK }
  nodes[#nodes + 1] = { id = id .. "_fill", kind = "rect", parent = id, x = -440, y = -76, w = 872, h = 144, rx = 24,
    color = PAPER }
  nodes[#nodes + 1] = { id = id .. "_name", kind = "text", parent = id, x = -400, y = -38, text = s[1], size = 62,
    font = SEMI, color = INK }
  nodes[#nodes + 1] = { id = id .. "_price", kind = "text", parent = id, x = 168, y = -50, text = s[2], size = 86,
    font = HEAVY, color = INK, tracking = -3 }
  keys[#keys + 1] = { id, "x", at, 1740 }
  keys[#keys + 1] = { id, "x", at + 0.45, 540, "expoOut" }
end
-- the best row: the green fill comes up on beat four, the row nudges, and a badge pops on its corner
keys[#keys + 1] = { "row1_fill", "color", 1.6, PAPER }
keys[#keys + 1] = { "row1_fill", "color", 1.75, LEAF, "sineOut" }
keys[#keys + 1] = { "row1", "scale", 1.6, 1 }
keys[#keys + 1] = { "row1", "scale", 1.7, 1.05, "quadOut" }
keys[#keys + 1] = { "row1", "scale", 1.95, 1, "backOut" }
nodes[#nodes + 1] = { id = "best", kind = "group", x = 880, y = 600, scale = 0, rotation = 0.1 }
nodes[#nodes + 1] = { id = "best_edge", kind = "rect", parent = "best", x = -150, y = -44, w = 300, h = 88, rx = 44,
  color = INK }
nodes[#nodes + 1] = { id = "best_fill", kind = "rect", parent = "best", x = -144, y = -38, w = 288, h = 76, rx = 38,
  color = PAPER }
nodes[#nodes + 1] = { id = "best_text", kind = "text", parent = "best", x = 0, y = -2, anchor = "center",
  text = "Best price", size = 54, font = HEAVY, color = INK }
keys[#keys + 1] = { "best", "scale", 1.85, 0 }
keys[#keys + 1] = { "best", "scale", 2.25, 1, "spring(300,12)" }

return e.comp {
  width = 1080, height = 1920, duration = 3.6, fps = 30, background = PAPER, lint_allow = { "blank_frame" },
  nodes = nodes,
  keys = keys,
}
