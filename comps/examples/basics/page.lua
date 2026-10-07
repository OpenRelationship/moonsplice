-- Full HTML document painted to a viewport (linked CSS/images). No Chrome, no JS.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#06080d",

  scene = function(s)
    s:page {
      x = 0, y = 0, w = 1280, h = 720,
      src = "comps/assets/page/index.html",
    }
  end,
}
