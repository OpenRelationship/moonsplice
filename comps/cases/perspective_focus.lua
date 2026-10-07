-- One assembled UI plane: tilt, open the lens, pull focus onto Publish.
-- Far edge of the page goes soft; the button stays sharp.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "14  PERSPECTIVE · FOCUS", size = 22, color = "#6b7894" }
    s:text {
      x = 48, y = 668, text = "thin-lens defocus · focus_u/v on the Publish button", size = 20, color = "#6b7894",
    }

    -- Publish sits at ~ (602, 418) on a 720×480 page → u=0.836, v=0.871
    local page = s:svg {
      src = "comps/assets/ui_page.svg",
      x = 640, y = 370, w = 720, h = 480, anchor = "center",
      perspective = true, persp_margin = 2.2,
      yaw = 0, pitch = 0, dolly = 1, fov = 0.62,
      aperture = 0, maxcoc = 48,
      focus_u = 0.5, focus_v = 0.5,
      truck_u = 0.5, truck_v = 0.5,
    }

    s:script(function(t)
      t:wait(0.15)
      t:parallel(
        function() t:tween(page, 1.2, { yaw = 0.48, pitch = -0.18, dolly = 1.18 }, "sineInOut") end,
        function() t:tween(page, 1.2, { aperture = 36, fov = 0.72 }, "sineInOut") end,
        function() t:tween(page, 1.2, { focus_u = 0.836, focus_v = 0.871 }, "sineInOut") end,
        function() t:tween(page, 1.2, { truck_u = 0.78, truck_v = 0.82 }, "sineInOut") end
      )
      t:wait(0.45)
      t:parallel(
        function() t:tween(page, 1.05, { yaw = 0.22, pitch = -0.08, dolly = 1.06 }, "sineInOut") end,
        function() t:tween(page, 1.05, { aperture = 18 }, "sineInOut") end
      )
    end)
  end,
}
