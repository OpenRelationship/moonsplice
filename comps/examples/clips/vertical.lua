-- 9:16 short — two-clip cut with text overlays. Footage: Pexels (local assets).
local e = require("moonsplice")

return e.comp {
  width = 1080, height = 1920, duration = 8, fps = 30,
  background = "#000000",

  scene = function(s)
    -- footage (cover-cropped to frame at resolve time)
    s:video { src = "comps/examples/assets/ocean.mp4", from = 0, duration = 4, media_start = 2 }
    s:video { src = "comps/examples/assets/city.mp4", from = 4, duration = 4, media_start = 3 }

    -- bottom scrim for text legibility
    local scrim = s:rect { x = 0, y = 1200, w = 1080, h = 720, color = "#00000000" }

    -- act 1: ocean
    local kicker1 = s:text { x = 540, y = 1380, text = "FIND YOUR", size = 64,
      color = "#9fd8ff", opacity = 0, anchor = "center" }
    local title1 = s:text { x = 540, y = 1500, text = "CALM", size = 200,
      color = "#ffffff", opacity = 0, anchor = "center" }
    local bar1 = s:rect { x = 340, y = 1640, w = 0, h = 10, rx = 5, color = "#9fd8ff" }

    -- act 2: city
    local kicker2 = s:text { x = 540, y = 1380, text = "THEN CHASE THE", size = 64,
      color = "#ffb46b", opacity = 0, anchor = "center" }
    local title2 = s:text { x = 540, y = 1500, text = "LIGHTS", size = 200,
      color = "#ffffff", opacity = 0, anchor = "center" }
    local bar2 = s:rect { x = 340, y = 1640, w = 0, h = 10, rx = 5, color = "#ffb46b" }

    -- watermark
    local wm = s:text { x = 540, y = 1820, text = "made with moonsplice", size = 40,
      color = "#ffffff88", opacity = 0, anchor = "center" }

    s:script(function(t)
      t:tween(scrim, 0.6, { color = "#000000aa" }, "sineOut")
      t:parallel(
        function() t:tween(kicker1, 0.5, { opacity = 1, y = 1360 }, "sineOut") end,
        function()
          t:wait(0.15)
          t:tween(title1, 0.6, { opacity = 1, size = 220 }, "backOut")
        end,
        function() t:tween(bar1, 0.7, { w = 400 }, "cubicInOut") end,
        function() t:tween(wm, 0.8, { opacity = 1 }) end
      )
      t:wait(1.6)
      -- act 1 out, hard cut at 4.0
      t:parallel(
        function() t:tween(kicker1, 0.4, { opacity = 0 }) end,
        function() t:tween(title1, 0.4, { opacity = 0, y = 1460 }, "sineIn") end,
        function() t:tween(bar1, 0.4, { w = 0, x = 740 }, "sineIn") end
      )
      t:wait(0.65) -- align act 2 entrance to the 4.0s hard cut
      t:parallel(
        function() t:tween(kicker2, 0.5, { opacity = 1, y = 1360 }, "sineOut") end,
        function()
          t:wait(0.15)
          t:tween(title2, 0.6, { opacity = 1, size = 220 }, "backOut")
        end,
        function() t:tween(bar2, 0.7, { w = 400 }, "cubicInOut") end
      )
      t:wait(1.9)
      t:parallel(
        function() t:tween(kicker2, 0.5, { opacity = 0 }) end,
        function() t:tween(title2, 0.5, { opacity = 0 }, "sineIn") end,
        function() t:tween(bar2, 0.5, { w = 0, x = 740 }, "sineIn") end,
        function() t:tween(wm, 0.5, { opacity = 0 }) end,
        function() t:tween(scrim, 0.5, { color = "#000000ff" }, "sineIn") end
      )
    end)
  end,
}
