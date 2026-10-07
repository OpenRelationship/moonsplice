-- vello_cpu vector layer: gradients, paths, deterministic grain.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "09  VECTOR", size = 22, color = "#6b7894" }

    local field = s:vector {
      x = 160, y = 120, w = 960, h = 500,
      draw = function(v, t)
        v:rect(0, 0, 960, 500, { 0.07, 0.09, 0.14, 1 }, 28)
        v:radial(220 + t * 80, 140, 340, { 0.24, 0.88, 0.78, 0.9 }, { 0.24, 0.88, 0.78, 0 })
        v:radial(760 - t * 60, 360, 380, { 0.31, 0.55, 1.0, 0.85 }, { 0.31, 0.55, 1.0, 0 })
        v:move(80, 420)
        v:curve(240, 280, 480, 520, 880, 300)
        v:stroke(6, { 0.95, 0.70, 0.24, 0.95 })
        v:grain(0.12, 1 + math.floor(t * 24))
      end,
    }

    s:script(function(t)
      t:tween(field, 1.2, { scale = 1.02 }, "sineInOut")
      t:tween(field, 0.8, { scale = 1 }, "sineInOut")
    end)
  end,
}
