-- A precomp for comps/cases/composition.lua (.robot/docs/rows.robot, "Composition"): a tide card, three
-- seconds long, instanced twice there at different times. It renders on its own too.
local e = require("moonsplice")

return e.comp {
  width = 400, height = 120, duration = 3, fps = 30, background = "#0b1a22",

  nodes = {
    { id = "panel", kind = "rect", x = 0, y = 0, w = 400, h = 120, color = "#0e2a36", rx = 14 },
    { id = "label", kind = "text", x = 24, y = 18, text = "HIGH WATER  05:48", size = 40,
      font = "/Users/shinyobjectz/cadence/evals/assets/fonts/BarlowCondensed-SemiBold.ttf", color = "#f4efe6" },
    { id = "bar", kind = "rect", x = 24, y = 88, w = 10, h = 10, color = "#f2a541", rx = 5 },
  },

  -- { node, prop, t, value, ease }: the curve runs from the previous key to this one
  keys = {
    { "bar", "w", 0.3, 10 }, { "bar", "w", 2.4, 352, "cubicInOut" },
    { "label", "x", 0.1, 60 }, { "label", "x", 0.8, 24, "expoOut" },
    { "label", "opacity", 0.1, 0 }, { "label", "opacity", 0.6, 1, "sineOut" },
  },

  expect = {
    { id = "bar-fills", says = "the tide bar is full by the end of the card", node = "bar", prop = "w", op = ">=", value = 340, at = 2.5 },
  },
}
