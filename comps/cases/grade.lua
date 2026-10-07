-- One still, one grade. Lights bloom, the picture crushes, a poster sting, settle.
-- New passes only (kawase / aces / posterize / pixelate / worley).
local e = require("moonsplice")

local DISPLAY = "comps/assets/fonts/Fraunces.ttf"
local ROMAN = "comps/assets/fonts/Roboto-Regular.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#05060a",

  scene = function(s)
    s:text { x = 48, y = 36, text = "31  GRADE", size = 22, color = "#6b7894" }

    local plate = s:fx {
      x = 140, y = 88, w = 1000, h = 560,
      chain = { "kawase", "tonemap", "posterize", "pixelate", "worley", "vignette" },
      blur = 1.2, tonemap = 0.2, posterize = 0, pixelate = 0, worley = 0.08, vignette = 0.18,
    }

    s:rect { parent = plate, x = 0, y = 0, w = 1000, h = 560, color = "#0c1018" }
    s:circle { parent = plate, x = 280, y = 220, r = 120, color = "#3ee0c6" }
    s:circle { parent = plate, x = 720, y = 300, r = 160, color = "#4f6bff" }
    s:circle { parent = plate, x = 520, y = 180, r = 48, color = "#e85aa8" }
    s:text {
      parent = plate, x = 500, y = 300, text = "NIGHT", size = 112, font = DISPLAY,
      color = "#f4f6fb", anchor = "center",
    }
    s:text {
      parent = plate, x = 500, y = 400, text = "after hours", size = 28, font = ROMAN,
      color = "#c5cde0", anchor = "center",
    }

    s:script(function(t)
      t:tween(plate, 1.1, { fx_tonemap = 0.85, fx_blur = 2.4, fx_vignette = 0.42 }, "sineInOut")
      t:parallel(
        function() t:tween(plate, 0.28, { fx_posterize = 0.72, fx_pixelate = 0.28 }, "expoOut") end
      )
      t:tween(plate, 0.9, { fx_posterize = 0.12, fx_pixelate = 0.04, fx_worley = 0.2 }, "sineInOut")
      t:wait(0.9)
    end)
  end,
}
