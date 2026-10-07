-- Decode path: Wikimedia public-domain WebM, cover-cropped, plus type overlay.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#000000",

  scene = function(s)
    s:video {
      src = "comps/assets/earth_night.webm",
      from = 0, duration = 3, media_start = 2,
    }
    s:rect { x = 0, y = 520, w = 1280, h = 200, color = "#00000099" }
    s:text { x = 48, y = 36, text = "15  VIDEO", size = 22, color = "#ffffffcc" }
    local title = s:text {
      x = 48, y = 560, text = "EARTH AT NIGHT", size = 48, color = "#e8edf7", opacity = 0,
    }
    s:text {
      x = 48, y = 620, text = "Wikimedia Commons · NASA · public domain", size = 22, color = "#8b97b0",
    }

    s:script(function(t)
      t:tween(title, 0.6, { opacity = 1, y = 548 }, "sineOut")
    end)
  end,
}
