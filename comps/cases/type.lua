-- Static type plus kinetic per-character stagger.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "03  TYPE", size = 22, color = "#6b7894" }

    local kicker = s:text {
      x = 640, y = 220, text = "GLYPH ATLAS", size = 28,
      color = "#3ee0c6", opacity = 0, anchor = "center",
    }
    local word = s:kinetic {
      x = 640, y = 360, text = "PIXELS", size = 112,
      color = "#e8edf7", opacity = 0, spacing = 8,
    }
    local note = s:text {
      x = 640, y = 500, text = "staggered characters · measured widths", size = 22,
      color = "#6b7894", opacity = 0, anchor = "center",
    }

    s:script(function(t)
      t:tween(kicker, 0.35, { opacity = 1 }, "sineOut")
      t:stagger(word.chars, 0.4, { opacity = 1, y = 340 }, { each = 0.07, ease = "backOut" })
      t:tween(note, 0.4, { opacity = 1 }, "sineOut")
    end)
  end,
}
