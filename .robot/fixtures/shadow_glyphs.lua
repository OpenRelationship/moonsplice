local e = require("moonsplice")

return e.comp {
  width = 640, height = 240, duration = 1, fps = 30,
  background = "#10111a",
  scene = function(s)
    s:surface {
      x = 80, y = 40, w = 480, h = 160, rx = 18, color = "#283b66",
      shadow = { blur = 28, dy = 12, alpha = 0.42 },
    }
    s:text {
      x = 320, y = 120, anchor = "center",
      text = "COLOR, COMPOSITED", size = 38, color = "#ffffff",
    }
  end,
}
