-- Native adjustment pass on a raster-backed vector node.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "10  EFFECTS", size = 22, color = "#6b7894" }

    local panel = s:vector {
      x = 240, y = 140, w = 800, h = 440,
      effects = { contrast = 1.08, saturate = 1.1, hue_rotate = -12 },
      draw = function(v)
        v:rect(0, 0, 800, 440, { 0.08, 0.09, 0.16, 1 }, 28)
        v:radial(160, 120, 420, { 0.90, 0.22, 0.55, 0.92 }, { 0.90, 0.22, 0.55, 0 })
        v:radial(680, 340, 460, { 0.05, 0.78, 0.84, 0.82 }, { 0.05, 0.78, 0.84, 0 })
      end,
    }
    s:text {
      x = 640, y = 360, text = "HUE  BLUR  SAT", size = 48,
      color = "#ffffff", anchor = "center",
    }

    s:script(function(t)
      t:tween(panel, 0.8, { effect_hue_rotate = 40 }, "sineInOut")
      t:tween(panel, 0.6, { effect_blur = 10, effect_saturate = 0.25 }, "sineInOut")
      t:tween(panel, 0.6, { effect_blur = 0, effect_saturate = 1.2 }, "sineInOut")
    end)
  end,
}
