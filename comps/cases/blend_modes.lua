-- Blend modes on overlapping discs: the CSS set the renderer composites with, and `add`.
local e = require("moonsplice")

local MODES = { "alpha", "add", "multiply", "screen", "overlay", "difference", "color-dodge", "luminosity" }

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "05  BLEND MODES", size = 22, color = "#6b7894" }

    local fades = {}
    for i, mode in ipairs(MODES) do
      local col = ((i - 1) % 4)
      local row = math.floor((i - 1) / 4)
      local x = 200 + col * 300
      local y = 230 + row * 300
      s:circle { x = x - 28, y = y - 10, r = 64, color = "#3ee0c6" }
      local overlay = s:circle {
        x = x + 28, y = y + 8, r = 64, color = "#e85aa8",
        blend = mode, opacity = 0,
      }
      fades[#fades + 1] = overlay
      s:text {
        x = x, y = y + 96, text = mode, size = 20,
        color = "#8b97b0", anchor = "center",
      }
    end

    s:script(function(t)
      t:stagger(fades, 0.45, { opacity = 1 }, { each = 0.1, ease = "sineOut" })
      t:wait(0.6)
    end)
  end,
}
