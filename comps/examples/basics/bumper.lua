-- Studio ident. Linker, compass, name — ornaments as motion, not clip art.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#08090d",

  scene = function(s)
    local line = s:ornament {
      x = 200, y = 250, w = 880, h = 80, kind = "linker",
      color = "#c9a227", width = 2.2, reveal = 0,
    }
    local seal = s:ornament {
      x = 96, y = 268, w = 120, h = 120, kind = "compass",
      color = "#e8edf7", width = 1.8, reveal = 0, rotation = -0.18,
    }
    local star = s:ornament {
      x = 1064, y = 284, w = 88, h = 88, kind = "star", n = 6,
      color = "#c9a227", width = 2, reveal = 0, scale = 0.55,
    }
    local name = s:text {
      x = 640, y = 404, text = "NORTH", size = 104,
      font = "comps/assets/fonts/Fraunces.ttf",
      color = "#f4f6fb", anchor = "center", opacity = 0, scale = 1.08,
    }
    local tag = s:text {
      x = 640, y = 496, text = "pictures", size = 22,
      color = "#8b97b0", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:tween(line, 1.0, { reveal = 1 }, "sineOut")
      t:parallel(
        function() t:tween(seal, 0.8, { reveal = 1, rotation = 0 }, "cubicOut") end,
        function() t:tween(star, 0.5, { reveal = 1, scale = 1 }, "backOut") end
      )
      t:tween(name, 0.45, { opacity = 1, scale = 1 }, "expoOut")
      t:tween(tag, 0.35, { opacity = 1 }, "sineOut")
      t:wait(1.2)
    end)
  end,
}
