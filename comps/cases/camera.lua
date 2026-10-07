-- Shared s:camera drives two perspective cards. Same orbit, different dolly;
-- far card draws first (Z-sort). Look-at is available; this shot uses euler.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "15  CAMERA", size = 22, color = "#6b7894" }
    s:text {
      x = 48, y = 668, text = "one camera · two planes · Z-sort by dolly", size = 20, color = "#6b7894",
    }

    local cam = s:camera { yaw = 0, pitch = 0, fov = 0.62, aperture = 0 }

    local back = s:rect {
      x = 520, y = 360, w = 340, h = 420, rx = 28, anchor = "center",
      color = "#4f6bff", perspective = true, camera = cam, dolly = 0.86,
      persp_margin = 2.2,
    }
    local front = s:rect {
      x = 760, y = 360, w = 280, h = 340, rx = 24, anchor = "center",
      color = "#3ee0c6", perspective = true, camera = cam, dolly = 1.22,
      persp_margin = 2.2,
    }

    s:script(function(t)
      t:wait(0.15)
      t:parallel(
        function() t:tween(cam, 1.35, { yaw = 0.48, pitch = -0.16 }, "sineInOut") end,
        function() t:tween(back, 1.35, { dolly = 0.78 }, "sineInOut") end,
        function() t:tween(front, 1.35, { dolly = 1.38 }, "sineInOut") end
      )
      t:wait(0.35)
      t:parallel(
        function() t:tween(cam, 1.0, { yaw = 0.18, pitch = -0.06 }, "sineInOut") end,
        function() t:tween(back, 1.0, { dolly = 0.92 }, "sineInOut") end,
        function() t:tween(front, 1.0, { dolly = 1.18 }, "sineInOut") end
      )
    end)
  end,
}
