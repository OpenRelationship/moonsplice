local e = require("moonsplice")

return e.comp {
  width = 640, height = 240, duration = 1, fps = 30,
  background = "#10111a",
  scene = function(s)
    s:rect { x = 80, y = 40, w = 480, h = 160, color = "#283b66" }
    s:rect { x = 100, y = 70, w = 440, h = 2, color = "#ffffff66", blend = "screen" }
    s:text {
      x = 320, y = 120, anchor = "center",
      text = "COLOR, COMPOSITED", size = 38, color = "#ffffff",
    }
  end,
}
