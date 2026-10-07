-- Full HTML document as a viewport texture. Linked CSS + image, no Chrome, no JS.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#06080d",

  scene = function(s)
    s:text { x = 48, y = 36, text = "39  PAGE", size = 22, color = "#6b7894" }

    s:page {
      x = 80, y = 88, w = 1120, h = 560, rx = 20,
      src = "comps/assets/page/index.html",
    }
  end,
}
