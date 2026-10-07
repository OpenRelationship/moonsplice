-- Broadcast bug: one word, outline as the signal, weight as the breath.
local e = require("moonsplice")

local BOLD = "comps/assets/fonts/Roboto-Bold.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#08090d",

  scene = function(s)
    s:text { x = 48, y = 36, text = "38  SDF TYPE", size = 22, color = "#6b7894" }

    s:rect { x = 0, y = 0, w = 1280, h = 720, color = "#0b0d12" }
    local live = s:text {
      x = 640, y = 332, text = "LIVE", size = 188, font = BOLD, anchor = "center",
      color = "#f4f7ff", outline = 0.35, weight = 0,
      outline_color = "#e23d3d",
    }
    local rule = s:rect { x = 640, y = 456, w = 0, h = 6, rx = 3, color = "#e23d3d", anchor = "center" }
    local tag = s:text {
      x = 640, y = 500, text = "on air", size = 22, font = BOLD,
      color = "#e23d3d", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(live, 0.9, { outline = 1.15, weight = 0.28 }, "sineInOut") end,
        function() t:tween(rule, 0.5, { w = 280 }, "expoOut") end,
        function()
          t:wait(0.2)
          t:tween(tag, 0.3, { opacity = 1 }, "sineOut")
        end
      )
      t:tween(live, 1.1, { outline = 0.55, weight = 0.08 }, "sineInOut")
      t:wait(1.0)
    end)
  end,
}
