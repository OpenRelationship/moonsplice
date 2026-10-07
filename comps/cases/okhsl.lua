-- A palette is a product: eight even steps, then the word rides the ramp.
-- OKHSL is for brand, not for another comparison chart (that's the HSLuv eval).
local e = require("moonsplice")

local DISPLAY = "comps/assets/fonts/Fraunces.ttf"
local pal = e.palette { h = 268, n = 8, s = 64, l0 = 34, l1 = 80 }

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#0b0c10",

  scene = function(s)
    s:text { x = 48, y = 36, text = "30  OKHSL", size = 22, color = "#6b7894" }

    local chips = {}
    for i, c in ipairs(pal) do
      chips[i] = s:rect {
        x = 168 + (i - 1) * 124, y = 188, w = 104, h = 10, rx = 8,
        color = c, opacity = 0,
      }
    end

    local word = s:text {
      x = 640, y = 400, text = "AURORA", size = 108, font = DISPLAY,
      color = pal[1], color_space = "okhsl",
      anchor = "center", opacity = 0, scale = 1.06,
    }
    local note = s:text {
      x = 640, y = 520, text = "eight steps, one hue", size = 22,
      color = "#8b97b0", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:stagger(chips, 0.45, { opacity = 1, h = 72, y = 156 }, { each = 0.06, ease = "backOut" })
      t:wait(0.12)
      t:parallel(
        function() t:tween(word, 0.4, { opacity = 1, scale = 1 }, "expoOut") end,
        function() t:tween(note, 0.4, { opacity = 1 }, "sineOut") end
      )
      t:tween(word, 1.8, { color = pal[8] }, "sineInOut")
      t:wait(0.35)
    end)
  end,
}
