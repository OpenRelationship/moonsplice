-- One drop, one floor, bounceOut. The comparison grid already lives in eases.
local e = require("moonsplice")

local DISPLAY = "comps/assets/fonts/Fraunces.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "34  BOUNCE", size = 22, color = "#6b7894" }

    s:rect { x = 240, y = 548, w = 800, h = 3, color = "#243044" }
    local ball = s:circle { x = 640, y = 120, r = 34, color = "#3ee0c6", scale = 1 }
    local word = s:text {
      x = 640, y = 620, text = "landed", size = 36, font = DISPLAY,
      color = "#f4f6fb", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:wait(0.2)
      t:tween(ball, 1.55, { y = 514 }, "bounceOut")
      t:parallel(
        function() t:tween(ball, 0.22, { scale = 1.08 }, "backOut") end,
        function() t:tween(word, 0.28, { opacity = 1, y = 604 }, "expoOut") end
      )
      t:tween(ball, 0.35, { scale = 1 }, "sineOut")
      t:wait(0.55)
    end)
  end,
}
