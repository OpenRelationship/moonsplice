-- Same word, three fills. RGB muddies; the perceptual ramps keep the hue.
local e = require("moonsplice")

local BOLD = "comps/assets/fonts/Roboto-Bold.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "28  HSLUV", size = 22, color = "#6b7894" }

    local function row(y, space, label)
      local bar = s:rect {
        x = 160, y = y, w = 960, h = 88, rx = 16,
        color = "#ff0033", color_space = space,
      }
      s:text {
        x = 200, y = y + 28, text = "chroma", size = 40, font = BOLD, color = "#ffffff",
      }
      s:text {
        x = 980, y = y + 32, text = label, size = 18, color = "#ffffffcc",
      }
      return bar
    end

    local rgb = row(168, "rgb", "RGB")
    local oklab = row(312, "oklab", "OKLab")
    local hsl = row(456, "hsluv", "HSLuv")

    s:script(function(t)
      t:wait(0.15)
      t:parallel(
        function() t:tween(rgb, 2.7, { color = "#00e5ff" }, "linear") end,
        function() t:tween(oklab, 2.7, { color = "#00e5ff" }, "linear") end,
        function() t:tween(hsl, 2.7, { color = "#00e5ff" }, "linear") end
      )
    end)
  end,
}
