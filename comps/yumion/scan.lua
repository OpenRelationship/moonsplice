-- Yumion promo, scene 3 (5.0-9.1s): "Scan any shelf." A phone rises, its camera frames a cereal box, a
-- scan line sweeps it twice, and it finds it. Precomp of promo.lua. 1080x1920, 120 bpm: a beat is 0.5s.
local e = require("moonsplice")
local FONT = "/Users/shinyobjectz/.cache/moonsplice/fonts/"
local INK, PAPER, LEAF = "#24221D", "#F8F6EF", "#7FA848"
local CANARY, TOMATO, PERI, SHELF = "#F5C842", "#E5533D", "#8C9EFF", "#E4DFCF"
local HEAVY, SEMI = FONT .. "SF-Heavy.ttf", FONT .. "SF-Semibold.ttf"

local nodes = {
  { id = "h1", kind = "text", x = 540, y = 230, anchor = "center", text = "Scan", size = 150, font = HEAVY,
    color = INK, tracking = -6, opacity = 0 },
  { id = "swipe", kind = "rect", x = 150, y = 408, w = 2, h = 34, rx = 17, color = LEAF, rotation = -0.02, opacity = 0 },
  { id = "h2", kind = "text", x = 540, y = 370, anchor = "center", text = "any shelf.", size = 150, font = HEAVY,
    color = INK, tracking = -6, opacity = 0 },

  -- the phone: a group so it rises as one; parts are relative to its centre
  { id = "phone", kind = "group", x = 540, y = 2500 },
  { id = "ph_shadow", kind = "rect", parent = "phone", x = -284, y = -544, w = 600, h = 1120, rx = 96, color = INK },
  { id = "ph_body", kind = "rect", parent = "phone", x = -300, y = -560, w = 600, h = 1120, rx = 96, color = INK },
  { id = "ph_screen", kind = "rect", parent = "phone", x = -284, y = -544, w = 568, h = 1088, rx = 82, color = SHELF },
  -- the shelf the camera sees
  { id = "shelf1", kind = "rect", parent = "phone", x = -284, y = -170, w = 568, h = 14, color = "#CFC8B4" },
  { id = "shelf2", kind = "rect", parent = "phone", x = -284, y = 250, w = 568, h = 14, color = "#CFC8B4" },
  { id = "side_l", kind = "rect", parent = "phone", x = -300, y = -120, w = 120, h = 370, rx = 10, color = PERI },
  { id = "side_r", kind = "rect", parent = "phone", x = 190, y = -100, w = 110, h = 350, rx = 10, color = TOMATO },
  -- the cereal box in the middle (a made-up brand)
  { id = "box_edge", kind = "rect", parent = "phone", x = -146, y = -146, w = 292, h = 400, rx = 14, color = INK },
  { id = "box", kind = "rect", parent = "phone", x = -138, y = -138, w = 276, h = 384, rx = 10, color = CANARY },
  { id = "box_name", kind = "text", parent = "phone", x = 0, y = -60, anchor = "center", text = "OATY", size = 88,
    font = HEAVY, color = INK, tracking = -3 },
  { id = "box_sub", kind = "text", parent = "phone", x = 0, y = 10, anchor = "center", text = "O's", size = 72,
    font = HEAVY, color = "#A8321C" },
  { id = "box_bowl", kind = "circle", parent = "phone", x = 0, y = 150, r = 66, color = PAPER },
  { id = "box_bowl_in", kind = "circle", parent = "phone", x = 0, y = 150, r = 50, color = "#E8B04A" },
  { id = "island", kind = "rect", parent = "phone", x = -90, y = -524, w = 180, h = 50, rx = 25, color = INK },
  -- the store pill at the top of the camera view
  { id = "store_edge", kind = "rect", parent = "phone", x = -200, y = -444, w = 400, h = 76, rx = 38, color = INK },
  { id = "store_fill", kind = "rect", parent = "phone", x = -194, y = -438, w = 388, h = 64, rx = 32, color = PAPER },
  { id = "store", kind = "text", parent = "phone", x = 0, y = -407, anchor = "center", text = "Target", size = 54,
    font = SEMI, color = INK },
  -- the scan line
  { id = "scan", kind = "rect", parent = "phone", x = -180, y = -170, w = 360, h = 10, rx = 5, color = LEAF, opacity = 0 },
  -- found it
  { id = "found", kind = "group", parent = "phone", x = 0, y = 400, scale = 0 },
  { id = "found_edge", kind = "rect", parent = "found", x = -190, y = -50, w = 380, h = 100, rx = 50, color = INK },
  { id = "found_fill", kind = "rect", parent = "found", x = -184, y = -44, w = 368, h = 88, rx = 44, color = LEAF },
  { id = "found_text", kind = "text", parent = "found", x = 0, y = -2, anchor = "center", text = "Found it!", size = 56,
    font = HEAVY, color = INK },
}

-- the four corners of the scan frame: an L at each, as two thin bars
local corners = { { -170, -180, 1, 1 }, { 170, -180, -1, 1 }, { -170, 290, 1, -1 }, { 170, 290, -1, -1 } }
for i, c in ipairs(corners) do
  local x, y, sx, sy = c[1], c[2], c[3], c[4]
  nodes[#nodes + 1] = { id = "cn" .. i .. "a", kind = "rect", parent = "phone", x = sx > 0 and x or x - 70,
    y = sy > 0 and y or y - 12, w = 70, h = 12, rx = 6, color = PAPER }
  nodes[#nodes + 1] = { id = "cn" .. i .. "b", kind = "rect", parent = "phone", x = sx > 0 and x or x - 12,
    y = sy > 0 and y or y - 70, w = 12, h = 70, rx = 6, color = PAPER }
end

return e.comp {
  width = 1080, height = 1920, duration = 4.1, fps = 30, background = PAPER, lint_allow = { "blank_frame" },
  nodes = nodes,
  keys = {
    { "h1", "opacity", 0.1, 0 }, { "h1", "opacity", 0.15, 1 }, { "h1", "y", 0.1, 180 }, { "h1", "y", 0.35, 230, "backOut" },
    { "h2", "opacity", 0.5, 0 }, { "h2", "opacity", 0.55, 1 }, { "h2", "y", 0.5, 320 }, { "h2", "y", 0.75, 370, "backOut" },
    { "swipe", "opacity", 0.8, 0 }, { "swipe", "opacity", 0.82, 1 }, { "swipe", "w", 0.8, 2 }, { "swipe", "w", 1.2, 780, "expoOut" },
    -- the phone rises on beat two and settles
    { "phone", "y", 0.4, 2500 }, { "phone", "y", 1.1, 1180, "spring(170,16)" },
    { "phone", "rotation", 0.4, 0.08 }, { "phone", "rotation", 1.2, 0, "backOut" },
    -- two sweeps of the scan line, then the find
    { "scan", "opacity", 1.3, 0 }, { "scan", "opacity", 1.35, 1 },
    { "scan", "y", 1.3, -170 }, { "scan", "y", 1.8, 280, "sineInOut" }, { "scan", "y", 2.3, -170, "sineInOut" },
    { "scan", "y", 2.8, 280, "sineInOut" },
    { "scan", "opacity", 2.8, 1 }, { "scan", "opacity", 2.9, 0 },
    { "box", "color", 2.85, CANARY }, { "box", "color", 2.9, "#FFF1B0" }, { "box", "color", 3.1, CANARY, "sineOut" },
    { "found", "scale", 2.9, 0 }, { "found", "scale", 3.3, 1, "spring(300,13)" },
    { "found", "rotation", 2.9, -0.2 }, { "found", "rotation", 3.35, 0.03, "backOut" },
  },
}
