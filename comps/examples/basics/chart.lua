-- Earnings card. Bars reveal last quarter, then mix into this one.
local e = require("moonsplice")

local Q3 = { 18, 21, 17, 24, 22, 20 }
local Q4 = { 21, 26, 29, 27, 34, 40 }

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#0c1018",

  scene = function(s)
    local card = s:group { x = 640, y = 380, opacity = 0, scale = 0.96 }
    s:surface {
      parent = card, x = 0, y = 0, w = 960, h = 460, rx = 36,
      color = "#151c2c", anchor = "center",
      shadow = { blur = 44, dy = 24, alpha = 0.42 },
    }
    s:text {
      parent = card, x = -400, y = -176, text = "Revenue", size = 22,
      color = "#8b97b0", font = "comps/assets/fonts/Roboto-Regular.ttf",
    }
    local amount = s:text {
      parent = card, x = -400, y = -132, text = "$1.8M", size = 64,
      color = "#f4f6fb", font = "comps/assets/fonts/Fraunces.ttf",
    }
    s:text {
      parent = card, x = 310, y = -168, text = "Q3 → Q4", size = 20,
      color = "#3ee0c6", font = "comps/assets/fonts/JetBrainsMono-Regular.ttf",
    }
    local bars = s:chart {
      parent = card, x = -420, y = -32, w = 840, h = 210,
      type = "bar", data = Q3, data1 = Q4, mix = 0, reveal = 0, hue = 198,
    }
    local spark = s:chart {
      parent = card, x = -420, y = -32, w = 840, h = 210,
      type = "line", data = Q3, data1 = Q4, mix = 0, reveal = 0,
      stroke = "rough", seed = 4, color = "#f4f6fb", width = 2.5,
    }

    s:script(function(t)
      t:tween(card, 0.5, { opacity = 1, scale = 1, y = 368 }, "expoOut")
      t:tween(bars, 0.9, { reveal = 1 }, "cubicOut")
      t:tween(spark, 0.8, { reveal = 1 }, "sineOut")
      t:parallel(
        function() t:tween(bars, 1.1, { mix = 1 }, "sineInOut") end,
        function() t:tween(spark, 1.1, { mix = 1 }, "sineInOut") end,
        function()
          t:wait(0.5)
          t:set(amount, { text = "$2.4M" })
        end
      )
      t:wait(0.5)
    end)
  end,
}
