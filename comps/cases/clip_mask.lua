-- Live clip_node wipe and clip_invert (content only outside the mask).
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "06  CLIP MASK", size = 22, color = "#6b7894" }

    local wipe = s:rect { x = 160, y = 160, w = 0, h = 200, rx = 16, color = "#00000000" }
    s:text {
      x = 640, y = 260, text = "REVEAL", size = 120,
      color = "#3ee0c6", anchor = "center", clip_node = wipe,
    }

    local pill = s:rect {
      x = 200, y = 470, w = 220, h = 88, rx = 44, color = "#4f8cff",
    }
    s:text {
      x = 640, y = 514, text = "INVERT UNDER PILL", size = 42,
      color = "#e8edf7", anchor = "center",
      clip_node = pill, clip_invert = true,
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(wipe, 1.1, { w = 960 }, "cubicInOut") end,
        function() t:tween(pill, 1.6, { x = 860 }, "sineInOut") end
      )
    end)
  end,
}
