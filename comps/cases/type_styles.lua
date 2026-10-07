-- One cut on screen at a time. Snappy in, gone before the next lands.
-- Regular → italic → bold, then a three-line lockup. No crossfades.
local e = require("moonsplice")

local ROMAN = "comps/assets/fonts/Roboto-Regular.ttf"
local ITALIC = "comps/assets/fonts/Roboto-Italic.ttf"
local BOLD = "comps/assets/fonts/Roboto-Bold.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "22  TYPE STYLES", size = 22, color = "#6b7894" }

    local regular = s:text {
      x = 640, y = 360, text = "regular", size = 108, font = ROMAN,
      color = "#f4f6fb", anchor = "center", opacity = 0, scale = 1.12,
    }
    local italic = s:text {
      x = 640, y = 360, text = "italic", size = 108, font = ITALIC,
      color = "#f4f6fb", anchor = "center", opacity = 0, scale = 1.12,
    }
    local bold = s:kinetic {
      x = 640, y = 360, text = "bold", size = 120, font = BOLD,
      color = "#ffffff", opacity = 0, spacing = 4,
    }

    local lock_r = s:text {
      x = 640, y = 288, text = "regular", size = 44, font = ROMAN,
      color = "#f4f6fb", anchor = "center", opacity = 0,
    }
    local lock_i = s:text {
      x = 640, y = 368, text = "italic", size = 44, font = ITALIC,
      color = "#f4f6fb", anchor = "center", opacity = 0,
    }
    local lock_b = s:text {
      x = 640, y = 460, text = "bold", size = 56, font = BOLD,
      color = "#ffffff", anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:tween(regular, 0.28, { opacity = 1, scale = 1 }, "expoOut")
      t:wait(0.42)
      t:parallel(
        function() t:tween(regular, 0.18, { opacity = 0, y = 300, scale = 0.94 }, "sineIn") end,
        function()
          t:wait(0.06)
          t:tween(italic, 0.28, { opacity = 1, scale = 1 }, "expoOut")
        end
      )
      t:wait(0.42)
      t:parallel(
        function() t:tween(italic, 0.16, { opacity = 0, y = 300, scale = 0.94 }, "sineIn") end,
        function()
          t:wait(0.04)
          t:stagger(bold.chars, 0.22, { opacity = 1, y = 348 }, { each = 0.045, ease = "backOut" })
        end
      )
      t:wait(0.5)
      t:parallel(
        function() t:stagger(bold.chars, 0.16, { opacity = 0, y = 320 }, { each = 0.03, ease = "sineIn" }) end,
        function()
          t:wait(0.12)
          t:tween(lock_r, 0.28, { opacity = 1, y = 268 }, "expoOut")
        end,
        function()
          t:wait(0.22)
          t:tween(lock_i, 0.28, { opacity = 1, y = 348 }, "expoOut")
        end,
        function()
          t:wait(0.32)
          t:tween(lock_b, 0.32, { opacity = 1, y = 440 }, "backOut")
        end
      )
    end)
  end,
}
