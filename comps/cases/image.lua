-- Still image decode + Ken Burns on the Apollo 17 Blue Marble.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#05070c",

  scene = function(s)
    local plate = s:image {
      src = "comps/assets/apollo17.jpg",
      x = 640, y = 360, w = 1280, h = 1281, anchor = "center", scale = 1.05,
    }
    s:rect { x = 0, y = 0, w = 1280, h = 720, color = "#00000022" }
    s:text { x = 48, y = 36, text = "17  IMAGE", size = 22, color = "#ffffffcc" }
    local title = s:text {
      x = 48, y = 600, text = "APOLLO 17", size = 52, color = "#e8edf7", opacity = 0,
    }
    s:text {
      x = 48, y = 656, text = "Wikimedia Commons · NASA · public domain", size = 22, color = "#8b97b0",
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(plate, 2.8, { scale = 1.28, y = 340 }, "sineInOut") end,
        function() t:tween(title, 0.6, { opacity = 1 }, "sineOut") end
      )
    end)
  end,
}
