-- A quarterly card: bars land, the line draws, the mix is last quarter → this one.
-- One surface, one number, no chart zoo.
local e = require("moonsplice")

local DISPLAY = "comps/assets/fonts/Fraunces.ttf"
local MONO = "comps/assets/fonts/JetBrainsMono-Regular.ttf"
local ROMAN = "comps/assets/fonts/Roboto-Regular.ttf"

local Q3 = { 18, 21, 17, 24, 22, 20 }
local Q4 = { 21, 26, 29, 27, 34, 40 }

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "32  CHART", size = 22, color = "#6b7894" }

    local card = s:group { x = 640, y = 392, opacity = 0, scale = 0.96 }
    s:surface {
      parent = card, x = 0, y = 0, w = 920, h = 440, rx = 32,
      color = "#151c2c", anchor = "center",
      shadow = { blur = 40, dy = 22, alpha = 0.45 },
    }
    s:text {
      parent = card, x = -380, y = -168, text = "Revenue", size = 22, font = ROMAN,
      color = "#8b97b0",
    }
    local amount = s:text {
      parent = card, x = -380, y = -128, text = "$1.8M", size = 56, font = DISPLAY,
      color = "#f4f6fb",
    }
    s:text {
      parent = card, x = 300, y = -160, text = "Q3 → Q4", size = 20, font = MONO,
      color = "#3ee0c6",
    }

    local bars = s:chart {
      parent = card, x = -400, y = -40, w = 800, h = 200,
      type = "bar", data = Q3, data1 = Q4, mix = 0, reveal = 0, hue = 198,
    }
    local spark = s:chart {
      parent = card, x = -400, y = -40, w = 800, h = 200,
      type = "line", data = Q3, data1 = Q4, mix = 0, reveal = 0,
      stroke = "rough", seed = 4, color = "#e8edf7", width = 2.4,
    }

    s:script(function(t)
      t:tween(card, 0.45, { opacity = 1, scale = 1, y = 380 }, "expoOut")
      t:parallel(
        function() t:tween(bars, 0.85, { reveal = 1 }, "cubicOut") end,
        function()
          t:wait(0.28)
          t:tween(spark, 0.9, { reveal = 1 }, "sineOut")
        end
      )
      t:parallel(
        function() t:tween(bars, 1.0, { mix = 1 }, "sineInOut") end,
        function() t:tween(spark, 1.0, { mix = 1 }, "sineInOut") end,
        function()
          t:wait(0.45)
          t:set(amount, { text = "$2.4M" })
        end
      )
      t:wait(0.55)
    end)
  end,
}
