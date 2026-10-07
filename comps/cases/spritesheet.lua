-- Frame-addressed Aseprite sheet. Same PNG, two clocks.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2.4, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "26  SPRITESHEET", size = 22, color = "#6b7894" }

    local a = s:spritesheet {
      src = "comps/assets/walk.json",
      x = 280, y = 280, w = 192, h = 192, fps = 8, loop = true,
    }
    local b = s:spritesheet {
      src = "comps/assets/walk.json",
      x = 800, y = 280, w = 192, h = 192, fps = 14, loop = true,
    }
    s:text {
      x = 376, y = 520, text = "8 fps", size = 22, color = "#8b97b0", anchor = "center",
    }
    s:text {
      x = 896, y = 520, text = "14 fps", size = 22, color = "#8b97b0", anchor = "center",
    }
    s:text {
      x = 640, y = 600, text = "Aseprite JSON · frame = floor((t − from) · fps) % n",
      size = 22, color = "#6b7894", anchor = "center",
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(a, 2.2, { x = 360 }, "sineInOut") end,
        function() t:tween(b, 2.2, { x = 720 }, "sineInOut") end
      )
    end)
  end,
}
