-- Film ident: the linker writes the line, the seal turns, the name lands.
local e = require("moonsplice")

local DISPLAY = "comps/assets/fonts/Fraunces.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#08090d",

  scene = function(s)
    s:text { x = 48, y = 36, text = "33  ORNAMENTS", size = 22, color = "#6b7894" }

    local line = s:ornament {
      x = 200, y = 250, w = 880, h = 80, kind = "linker",
      color = "#c9a227", width = 2.2, reveal = 0,
    }
    local seal = s:ornament {
      x = 96, y = 268, w = 120, h = 120, kind = "compass",
      color = "#e8edf7", width = 1.8, reveal = 0, rotation = -0.2,
    }
    local star = s:ornament {
      x = 1064, y = 284, w = 88, h = 88, kind = "star", n = 6,
      color = "#c9a227", width = 2, reveal = 0, scale = 0.6,
    }
    local name = s:text {
      x = 640, y = 400, text = "NORTH", size = 96, font = DISPLAY,
      color = "#f4f6fb", anchor = "center", opacity = 0, scale = 1.08,
    }
    local tag = s:text {
      x = 640, y = 488, text = "pictures", size = 22,
      color = "#8b97b0", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(line, 0.9, { reveal = 1 }, "sineOut") end,
        function()
          t:wait(0.2)
          t:tween(seal, 0.8, { reveal = 1, rotation = 0 }, "cubicOut")
        end,
        function()
          t:wait(0.45)
          t:tween(star, 0.5, { reveal = 1, scale = 1 }, "backOut")
        end
      )
      t:parallel(
        function() t:tween(name, 0.42, { opacity = 1, scale = 1 }, "expoOut") end,
        function()
          t:wait(0.12)
          t:tween(tag, 0.36, { opacity = 1 }, "sineOut")
        end
      )
      t:wait(1.15)
    end)
  end,
}
