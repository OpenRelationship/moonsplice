-- Night still, then the grade. Kawase air, ACES crush, a poster hit, settle.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#05060a",

  scene = function(s)
    local plate = s:fx {
      x = 0, y = 0, w = 1280, h = 720,
      chain = { "kawase", "tonemap", "posterize", "pixelate", "worley", "vignette" },
      blur = 1.1, tonemap = 0.15, posterize = 0, pixelate = 0, worley = 0.06, vignette = 0.22,
    }
    s:rect { parent = plate, x = 0, y = 0, w = 1280, h = 720, color = "#0c1018" }
    s:circle { parent = plate, x = 360, y = 260, r = 150, color = "#3ee0c6" }
    s:circle { parent = plate, x = 920, y = 360, r = 200, color = "#4f6bff" }
    s:circle { parent = plate, x = 640, y = 200, r = 56, color = "#e85aa8" }
    s:text {
      parent = plate, x = 640, y = 340, text = "NIGHT", size = 128,
      font = "comps/assets/fonts/Fraunces.ttf",
      color = "#f4f6fb", anchor = "center",
    }
    s:text {
      parent = plate, x = 640, y = 450, text = "after hours", size = 28,
      color = "#c5cde0", anchor = "center",
    }

    s:script(function(t)
      t:tween(plate, 1.4, { fx_tonemap = 0.9, fx_blur = 2.6, fx_vignette = 0.5 }, "sineInOut")
      t:tween(plate, 0.3, { fx_posterize = 0.75, fx_pixelate = 0.3 }, "expoOut")
      t:tween(plate, 1.0, { fx_posterize = 0.1, fx_pixelate = 0.03, fx_worley = 0.18 }, "sineInOut")
      t:wait(1.0)
    end)
  end,
}
