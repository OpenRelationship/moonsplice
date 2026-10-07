-- Taffy flex solve at compile, then item motion from solved positions.
local e = require("moonsplice")

local COLORS = { "#e84a5f", "#f2b33d", "#3ee0c6", "#4f8cff", "#e85aa8" }

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "12  FLEX", size = 22, color = "#6b7894" }
    s:text {
      x = 640, y = 150, text = "row · space-between · compile-time solve", size = 22,
      color = "#6b7894", anchor = "center",
    }

    local tiles = {}
    for i, color in ipairs(COLORS) do
      tiles[i] = s:rect {
        w = 160, h = 160, rx = 24, color = color, opacity = 0, scale = 0.7,
      }
    end
    s:flex {
      x = 120, y = 250, w = 1040, h = 200,
      dir = "row", justify = "between", align = "center",
      items = tiles,
    }

    s:script(function(t)
      t:stagger(tiles, 0.4, { opacity = 1, scale = 1 }, { each = 0.08, ease = "backOut" })
      t:wait(0.4)
      t:stagger(tiles, 0.35, { scale = 0.88 }, { each = 0.05, from = "end", ease = "sineInOut" })
    end)
  end,
}
