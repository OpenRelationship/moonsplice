-- Exercises the LÖVE main backbuffer with opaque and transparent primitives,
-- text, rounded geometry, and a Canvas-backed Moonsplice render pass. Run in normal
-- and shuffled hash modes; the hashes must be identical for a renderer build.
local e = require("moonsplice")

return e.comp {
  width = 320, height = 180, duration = 1, fps = 30,
  background = "#10131c",

  scene = function(s)
    local circle = s:circle { id = "circle", x = 54, y = 90, r = 34, color = "#ff6b6b" }
    local panel = s:rect { id = "panel", x = 110, y = 36, w = 170, h = 108, rx = 16, color = "#4584e8" }
    s:text { x = 195, y = 90, text = "headless", size = 28, color = "#ffffff", anchor = "center" }

    s:script(function(t)
      t:parallel(
        function() t:tween(circle, 0.5, { x = 266, opacity = 0.45 }, "sineInOut") end,
        function() t:tween(panel, 0.5, { y = 52, color = "#6d4ee8" }, "quadOut") end
      )
      t:parallel(
        function() t:tween(circle, 0.5, { x = 54, opacity = 1 }, "sineInOut") end,
        function() t:tween(panel, 0.5, { y = 36, color = "#4584e8" }, "quadIn") end
      )
    end)
  end,
}
