local e = require("moonsplice")

return e.comp {
  width = 640, height = 240, duration = 1, fps = 30,
  background = "#10111a",
  scene = function(s)
    s:vector {
      x = 80, y = 40, w = 480, h = 160,
      effects = { contrast = 1.05, saturate = 1.12, hue_rotate = -8 },
      draw = function(v)
        v:rect(0, 0, 480, 160, { 0.12, 0.18, 0.36, 1 })
      end,
    }
    s:text {
      x = 320, y = 120, anchor = "center",
      text = "COLOR, COMPOSITED", size = 38, color = "#ffffff",
    }
  end,
}
