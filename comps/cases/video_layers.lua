-- Two independent decoders: full-frame plate + floating second clip.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#000000",

  scene = function(s)
    s:video {
      src = "comps/assets/earth_night.webm",
      from = 0, duration = 3, media_start = 8,
    }
    s:rect { x = 0, y = 0, w = 1280, h = 720, color = "#00000033" }
    local card = s:video {
      src = "comps/assets/galileo.webm",
      from = 0, duration = 3, media_start = 1,
      w = 320, h = 320, x = 1480, y = 360, anchor = "center",
      rx = 24, opacity = 0,
    }
    s:text { x = 48, y = 36, text = "16  VIDEO LAYERS", size = 22, color = "#ffffffcc" }
    s:text {
      x = 48, y = 640, text = "two WebM decoders · NASA / JPL public domain", size = 22, color = "#8b97b0",
    }

    s:script(function(t)
      t:tween(card, 0.7, { x = 1040, opacity = 1 }, "backOut")
      t:tween(card, 1.4, { rotation = 0.08, y = 340 }, "sineInOut")
    end)
  end,
}
