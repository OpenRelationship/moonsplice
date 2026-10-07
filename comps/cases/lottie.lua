-- ThorVG Lottie: official Apache-2.0 sample, frame-addressed (seek-safe).
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "19  LOTTIE", size = 22, color = "#6b7894" }
    s:text {
      x = 640, y = 640, text = "Airbnb lottie-android · AndroidWave.json · Apache-2.0", size = 20,
      color = "#6b7894", anchor = "center",
    }

    local wave = s:lottie {
      src = "comps/assets/android_wave.json",
      x = 640, y = 360, w = 400, h = 400, anchor = "center",
      from = 0, duration = 3, loop = true,
    }

    s:script(function(t)
      t:tween(wave, 1.2, { scale = 1.08 }, "sineInOut")
      t:tween(wave, 1.2, { scale = 1 }, "sineInOut")
    end)
  end,
}
