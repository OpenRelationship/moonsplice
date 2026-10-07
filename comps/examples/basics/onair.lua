-- On-air bug. Outline is the signal; weight is the breath.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#08090d",

  scene = function(s)
    local live = s:text {
      x = 640, y = 332, text = "LIVE", size = 196,
      font = "comps/assets/fonts/Roboto-Bold.ttf",
      color = "#f4f7ff", outline = 0.3, weight = 0,
      outline_color = "#e23d3d", anchor = "center",
    }
    local rule = s:rect {
      x = 640, y = 460, w = 0, h = 6, rx = 3, color = "#e23d3d", anchor = "center",
    }
    local tag = s:text {
      x = 640, y = 504, text = "on air", size = 22,
      font = "comps/assets/fonts/Roboto-Bold.ttf",
      color = "#e23d3d", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(live, 1.0, { outline = 1.2, weight = 0.3 }, "sineInOut") end,
        function() t:tween(rule, 0.5, { w = 300 }, "expoOut") end,
        function()
          t:wait(0.2)
          t:tween(tag, 0.3, { opacity = 1 }, "sineOut")
        end
      )
      t:tween(live, 1.2, { outline = 0.5, weight = 0.06 }, "sineInOut")
      t:wait(1.1)
    end)
  end,
}
