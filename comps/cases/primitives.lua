-- Rect, circle, rounded corners, color, parallel tweens.
-- Title lives in a reserved right column; shapes cross in the left/center only.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "01  PRIMITIVES", size = 22, color = "#6b7894" }

    local disc = s:circle { x = 220, y = 400, r = 72, color = "#3ee0c6" }
    local slab = s:rect { x = 420, y = 332, w = 240, h = 136, rx = 28, color = "#4f8cff" }
    local title = s:text {
      x = 1040, y = 400, text = "SHAPE", size = 84,
      color = "#e8edf7", opacity = 0, anchor = "center",
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(disc, 1.1, { x = 560, r = 96, color = "#e85aa8" }, "cubicInOut") end,
        function() t:tween(slab, 1.1, { x = 180, rotation = 0.18, rx = 64, color = "#f2b33d" }, "quadOut") end
      )
      t:parallel(
        function() t:tween(title, 0.7, { opacity = 1, size = 96 }, "backOut") end,
        function() t:tween(disc, 0.7, { r = 64, opacity = 0.85 }, "sineOut") end
      )
    end)
  end,
}
