-- Mesh displacement: liquid type plus a warped image grid.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2.4, fps = 30,
  background = "#05070c",

  scene = function(s)
    s:text { x = 48, y = 36, text = "25  DISPLACE", size = 22, color = "#6b7894" }

    local plate = s:displace {
      src = "comps/assets/apollo17.jpg",
      x = 40, y = 90, w = 600, h = 540, cols = 28, rows = 20,
      amp = 6, freq = 1.4, rx = 8,
    }
    local liquid = s:displace {
      text = "LIQUID",
      size = 120,
      color = "#e8edf7",
      x = 680, y = 220, w = 560, h = 220,
      cols = 36, rows = 10,
      amp = 0, freq = 1.6,
    }
    s:text {
      x = 680, y = 480, text = "vertex grid · f(t) warp", size = 22, color = "#8b97b0",
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(plate, 2.2, { amp = 22, freq = 2.2 }, "sineInOut") end,
        function() t:tween(liquid, 2.2, { amp = 28 }, "sineInOut") end
      )
    end)
  end,
}
