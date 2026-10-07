-- Brand ramp as the picture. Eight even OKHSL steps, then the name rides them.
local e = require("moonsplice")

local pal = e.palette { h = 268, n = 8, s = 64, l0 = 34, l1 = 80 }

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#0b0c10",

  scene = function(s)
    local chips = {}
    for i, c in ipairs(pal) do
      chips[i] = s:rect {
        x = 168 + (i - 1) * 124, y = 200, w = 104, h = 10, rx = 8,
        color = c, opacity = 0,
      }
    end
    local word = s:text {
      x = 640, y = 400, text = "AURORA", size = 112,
      font = "comps/assets/fonts/Fraunces.ttf",
      color = pal[1], color_space = "okhsl",
      anchor = "center", opacity = 0, scale = 1.06,
    }
    local note = s:text {
      x = 640, y = 524, text = "e.palette  ·  one hue, even lightness",
      size = 20, color = "#8b97b0", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:stagger(chips, 0.5, { opacity = 1, h = 80, y = 160 }, { each = 0.07, ease = "backOut" })
      t:parallel(
        function() t:tween(word, 0.45, { opacity = 1, scale = 1 }, "expoOut") end,
        function() t:tween(note, 0.4, { opacity = 1 }, "sineOut") end
      )
      t:tween(word, 2.0, { color = pal[8] }, "sineInOut")
      t:wait(0.55)
    end)
  end,
}
