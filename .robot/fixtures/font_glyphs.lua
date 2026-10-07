local e = require("moonsplice")

return e.comp {
  width = 640, height = 240, duration = 1, fps = 30,
  background = "#10111a",
  scene = function(s)
    s:text {
      x = 320, y = 120, anchor = "center",
      text = "COLOR, COMPOSITED", size = 54, color = "#ffffff",
    }
  end,
}
