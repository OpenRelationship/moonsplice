-- Same drop, eight easing curves. Seek-safe; no clocks.
local e = require("moonsplice")
local ease = require("moonsplice.ease")

local CURVES = {
  { "linear", "linear" },
  { "quadOut", "quadOut" },
  { "cubic", "cubicInOut" },
  { "sineOut", "sineOut" },
  { "expoOut", "expoOut" },
  { "backOut", "backOut" },
  { "elastic", "elasticOut" },
  { "spring", ease.spring { stiffness = 180, damping = 12 } },
}

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "02  EASES", size = 22, color = "#6b7894" }
    s:rect { x = 80, y = 528, w = 1120, h = 2, color = "#243044" }

    local dots = {}
    for i, curve in ipairs(CURVES) do
      local x = 110 + (i - 1) * 148
      dots[i] = s:circle { x = x, y = 160, r = 22, color = "#3ee0c6" }
      s:text {
        x = x, y = 572, text = curve[1], size = 18,
        color = "#8b97b0", anchor = "center",
      }
    end

    s:script(function(t)
      t:wait(0.15)
      local drops = {}
      for i, curve in ipairs(CURVES) do
        drops[i] = function()
          t:tween(dots[i], 1.55, { y = 520 }, curve[2])
        end
      end
      t:parallel(unpack(drops))
    end)
  end,
}
