-- One word, then the burst. Same seed, two colors — a firework, not two fountains.
local e = require("moonsplice")

local BOLD = "comps/assets/fonts/Roboto-Bold.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.2, fps = 30,
  background = "#07090f",

  scene = function(s)
    s:text { x = 48, y = 36, text = "27  PARTICLES", size = 22, color = "#6b7894" }

    local go = s:text {
      x = 640, y = 300, text = "GO", size = 140, font = BOLD,
      color = "#f4f6fb", anchor = "center", opacity = 0, scale = 0.86,
    }
    s:particles {
      x = 640, y = 340, n = 110, seed = 11, life = 1.7,
      emit = 0.45, emit_window = 0.18,
      heading = -math.pi / 2, spread = 1.35, speed = 300, gravity = 620,
      r = 4.2, color = "#3ee0c6",
    }
    s:particles {
      x = 640, y = 340, n = 110, seed = 11, life = 1.7,
      emit = 0.45, emit_window = 0.18,
      heading = -math.pi / 2, spread = 1.35, speed = 300, gravity = 620,
      r = 4.2, color = "#e85aa8",
    }

    s:script(function(t)
      t:tween(go, 0.32, { opacity = 1, scale = 1 }, "backOut")
      t:wait(2.7)
    end)
  end,
}
