-- Multi-video + animated video layers: full-frame background + two floating
-- PiP cards with transforms, text choreography. 3 decoders, 10s, 9:16.
local e = require("moonsplice")

return e.comp {
  width = 1080, height = 1920, duration = 10, fps = 30,
  background = "#000000",

  scene = function(s)
    -- background runs the full comp
    local bg = s:video { src = "comps/examples/assets/ocean.mp4", media_start = 1 }
    local dim = s:rect { x = 0, y = 0, w = 1080, h = 1920, color = "#00000000" }

    -- floating cards (anchor center so transforms feel physical)
    local card1 = s:video { src = "comps/examples/assets/city.mp4", from = 1.2, duration = 4.2,
      media_start = 4, w = 560, h = 840, x = -400, y = 780, anchor = "center", opacity = 0 }
    local card2 = s:video { src = "comps/examples/assets/city.mp4", from = 5.6, duration = 4.0,
      media_start = 9, w = 560, h = 840, x = 1480, y = 1050, anchor = "center", opacity = 0 }

    local title = s:text { x = 540, y = 300, text = "TWO WORLDS", size = 110,
      color = "#ffffff", opacity = 0, anchor = "center" }
    local cap1 = s:text { x = 540, y = 1350, text = "the city hums", size = 60,
      color = "#ffd9a0", opacity = 0, anchor = "center" }
    local cap2 = s:text { x = 540, y = 480, text = "the sea breathes", size = 60,
      color = "#a8e6ff", opacity = 0, anchor = "center" }

    s:script(function(t)
      t:parallel(
        function() t:tween(dim, 0.8, { color = "#00000055" }, "sineOut") end,
        function() t:tween(title, 0.9, { opacity = 1, y = 340 }, "backOut") end
      )
      -- card1 flies in, floats, tilts
      t:parallel(
        function() t:tween(card1, 0.7, { x = 540, opacity = 1 }, "backOut") end,
        function() t:tween(cap1, 0.9, { opacity = 1 }, "sineOut") end
      )
      t:parallel(
        function() t:tween(card1, 1.1, { rotation = 0.06, y = 740 }, "sineInOut") end,
        function() t:tween(title, 1.0, { opacity = 0.25 }, "sineInOut") end
      )
      t:tween(card1, 1.1, { rotation = -0.04, y = 800 }, "sineInOut")
      -- card1 out, card2 in from the right
      t:parallel(
        function() t:tween(card1, 0.6, { x = 1600, rotation = 0.15, opacity = 0 }, "sineIn") end,
        function() t:tween(cap1, 0.5, { opacity = 0 }) end
      )
      t:parallel(
        function() t:tween(card2, 0.7, { x = 540, opacity = 1 }, "backOut") end,
        function() t:tween(cap2, 0.9, { opacity = 1 }, "sineOut") end,
        function() t:tween(title, 0.7, { opacity = 1 }, "sineOut") end
      )
      t:parallel(
        function() t:tween(card2, 1.2, { scale = 1.12, rotation = -0.05 }, "sineInOut") end,
        function() t:tween(dim, 1.2, { color = "#00000088" }, "sineInOut") end
      )
      t:tween(card2, 1.0, { scale = 1.0, rotation = 0.03, y = 1000 }, "sineInOut")
      -- outro
      t:parallel(
        function() t:tween(card2, 0.7, { y = 2400, rotation = 0.2, opacity = 0 }, "sineIn") end,
        function() t:tween(cap2, 0.5, { opacity = 0 }) end,
        function() t:tween(title, 0.8, { size = 130, opacity = 0 }, "sineIn") end,
        function() t:tween(dim, 0.9, { color = "#000000ff" }, "sineIn") end
      )
    end)
  end,
}
