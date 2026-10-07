-- Yumion promo, scene 6 (16.5-19.1s): Ask Oni "What's for dinner?" Oni thinks for a beat and answers with
-- something cheap and good that everyone can eat. Precomp of promo.lua. 1080x1920, 120 bpm: a beat is 0.5s.
local e = require("moonsplice")
local FONT = "/Users/shinyobjectz/.cache/moonsplice/fonts/"
local INK, PAPER, LEAF = "#24221D", "#F8F6EF", "#7FA848"
local HEAVY, MED = FONT .. "SF-Heavy.ttf", FONT .. "SF-Medium.ttf"

local nodes = {
  { id = "h1", kind = "text", x = 540, y = 250, anchor = "center", text = "Ask Oni,", size = 140, font = HEAVY,
    color = INK, tracking = -6, opacity = 0 },
  { id = "swipe", kind = "rect", x = 90, y = 448, w = 2, h = 32, rx = 16, color = LEAF, rotation = -0.015, opacity = 0 },
  { id = "h2", kind = "text", x = 540, y = 395, anchor = "center", text = "“What’s for dinner?”", size = 116,
    font = HEAVY, color = INK, tracking = -5, opacity = 0 },

  -- the person's question, right
  { id = "q", kind = "group", x = 640, y = 760, scale = 0 },
  { id = "q_fill", kind = "rect", parent = "q", x = -330, y = -64, w = 660, h = 128, rx = 40, color = INK },
  { id = "q_text", kind = "text", parent = "q", x = 0, y = -2, anchor = "center", text = "What can I cook tonight?",
    size = 54, font = MED, color = PAPER },

  -- Oni, left, and the dots while it thinks
  { id = "oni", kind = "group", x = 150, y = 1150, scale = 0 },
  { id = "oni_ring", kind = "circle", parent = "oni", x = 0, y = 0, r = 74, color = INK },
  { id = "oni_disc", kind = "circle", parent = "oni", x = 0, y = 0, r = 66, color = LEAF },
  { id = "oni_face", kind = "svg", parent = "oni", src = "comps/yumion/oni.svg", x = 0, y = -4, w = 100, h = 100,
    anchor = "center" },

  -- Oni's answer
  { id = "a", kind = "group", x = 600, y = 1150, scale = 0 },
  { id = "a_shadow", kind = "rect", parent = "a", x = -350, y = -176, w = 760, h = 380, rx = 40, color = INK },
  { id = "a_edge", kind = "rect", parent = "a", x = -362, y = -188, w = 760, h = 380, rx = 40, color = INK },
  { id = "a_fill", kind = "rect", parent = "a", x = -354, y = -180, w = 744, h = 364, rx = 34, color = PAPER },
  { id = "a_title", kind = "text", parent = "a", x = -310, y = -142, text = "Crispy chickpea tacos", size = 60,
    font = HEAVY, color = INK, tracking = -2 },
  { id = "a_line1", kind = "text", parent = "a", x = -310, y = -50, text = "for 4, $1.85 a serving.", size = 56,
    font = MED, color = INK },
  { id = "a_line2", kind = "text", parent = "a", x = -310, y = 30, text = "No dairy for Grandma Jo,", size = 56,
    font = MED, color = INK },
  { id = "a_line3", kind = "text", parent = "a", x = -310, y = 100, text = "no peanuts for Riley.", size = 56,
    font = MED, color = INK },
}
local keys = {
  { "h1", "opacity", 0.1, 0 }, { "h1", "opacity", 0.15, 1 }, { "h1", "y", 0.1, 200 }, { "h1", "y", 0.35, 250, "backOut" },
  { "h2", "opacity", 0.4, 0 }, { "h2", "opacity", 0.45, 1 }, { "h2", "y", 0.4, 345 }, { "h2", "y", 0.65, 395, "backOut" },
  { "swipe", "opacity", 0.7, 0 }, { "swipe", "opacity", 0.72, 1 },
  { "swipe", "w", 0.7, 2 }, { "swipe", "w", 1.05, 900, "expoOut" },
  { "q", "scale", 0.5, 0 }, { "q", "scale", 0.85, 1, "spring(300,14)" },
  { "oni", "scale", 0.9, 0 }, { "oni", "scale", 1.2, 1, "spring(300,12)" },
  { "a", "scale", 1.5, 0 }, { "a", "scale", 1.9, 1, "spring(260,14)" },
  { "a", "rotation", 1.5, 0.06 }, { "a", "rotation", 1.95, 0, "backOut" },
  { "oni", "y", 1.95, 1150 }, { "oni", "y", 2.1, 1110, "quadOut" }, { "oni", "y", 2.35, 1150, "bounceOut" },
}

-- three dots bounce in turn while Oni thinks (1.1s to 1.5s), then go
for i = 1, 3 do
  local id, at = "dot" .. i, 1.05 + (i - 1) * 0.08
  nodes[#nodes + 1] = { id = id, kind = "circle", x = 270 + (i - 1) * 44, y = 1150, r = 14, color = INK, opacity = 0 }
  keys[#keys + 1] = { id, "opacity", 1.0, 0 }
  keys[#keys + 1] = { id, "opacity", 1.05, 1 }
  keys[#keys + 1] = { id, "y", at, 1150 }
  keys[#keys + 1] = { id, "y", at + 0.12, 1124, "quadOut" }
  keys[#keys + 1] = { id, "y", at + 0.24, 1150, "quadIn" }
  keys[#keys + 1] = { id, "opacity", 1.5, 1 }
  keys[#keys + 1] = { id, "opacity", 1.55, 0 }
end

return e.comp {
  width = 1080, height = 1920, duration = 2.6, fps = 30, background = PAPER, lint_allow = { "blank_frame" },
  nodes = nodes,
  keys = keys,
}
