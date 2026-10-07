-- Wrapped + tagged type with a type-on reveal. Font:getWrap via the painter.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2.6, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "24  TYPE WRAP", size = 22, color = "#6b7894" }

    local body = s:text {
      x = 160, y = 180, wrap = 960, leading = 1.28, reveal = 0, size = 42,
      font = "comps/assets/fonts/Roboto-Regular.ttf",
      color = "#c5cde0",
      text = "Type is a {c:#3ee0c6}signal{/c}, not a container. Wrap it to a column, tag the words that should {c:#4f8cff}carry{/c} the cut, then {c:#e85aa8}type on{/c} in seek-safe time — any frame, any order, same glyphs.",
    }
    local note = s:text {
      x = 160, y = 560, text = "wrap + {c:#hex} tags + reveal 0→1", size = 22,
      color = "#6b7894", opacity = 0,
    }

    s:script(function(t)
      t:tween(body, 1.8, { reveal = 1 }, "sineOut")
      t:tween(note, 0.4, { opacity = 1 }, "sineOut")
    end)
  end,
}
