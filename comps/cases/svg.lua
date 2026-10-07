-- Wikimedia SVGs rasterized by resvg, then grouped motion.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "18  SVG", size = 22, color = "#6b7894" }

    local rose = s:svg {
      src = "comps/assets/compass.svg",
      x = 360, y = 380, w = 420, h = 420, anchor = "center",
    }
    local atom = s:svg {
      src = "comps/assets/helium_atom.svg",
      x = 920, y = 380, w = 360, h = 360, anchor = "center", opacity = 0.9,
    }
    local mark = s:svg {
      src = "comps/assets/nasa_worm.svg",
      x = 640, y = 96, w = 280, h = 72, anchor = "center", opacity = 0,
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(rose, 2.6, { rotation = 0.7 }, "sineInOut") end,
        function() t:tween(atom, 2.6, { rotation = -0.45, scale = 1.08 }, "sineInOut") end,
        function() t:tween(mark, 0.6, { opacity = 1 }, "sineOut") end
      )
    end)
  end,
}
