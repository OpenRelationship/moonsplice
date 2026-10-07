-- One ball, one floor, bounceOut. Steal the curve, not a comparison grid.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3.2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:rect { x = 240, y = 548, w = 800, h = 3, color = "#243044" }
    local ball = s:circle { x = 640, y = 120, r = 36, color = "#3ee0c6" }
    local word = s:text {
      x = 640, y = 620, text = "landed", size = 36,
      font = "comps/assets/fonts/Fraunces.ttf",
      color = "#f4f6fb", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:wait(0.25)
      t:tween(ball, 1.6, { y = 512 }, "bounceOut")
      t:parallel(
        function() t:tween(ball, 0.22, { scale = 1.08 }, "backOut") end,
        function() t:tween(word, 0.3, { opacity = 1, y = 604 }, "expoOut") end
      )
      t:tween(ball, 0.35, { scale = 1 }, "sineOut")
      t:wait(0.5)
    end)
  end,
}
