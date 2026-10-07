-- Classic <script> mutates the document at resolve, then Blitz paints the dump.
-- JS never runs in evaluate(t).
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#06080d",

  scene = function(s)
    s:text { x = 48, y = 36, text = "40  PAGE BAKE", size = 22, color = "#6b7894" }

    s:page {
      x = 80, y = 88, w = 1120, h = 560, rx = 20,
      src = "comps/assets/page/bake.html",
      bake = true,
    }
  end,
}
