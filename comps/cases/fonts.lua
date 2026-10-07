-- Public OFL/Apache typefaces, same word, real TTF files.
local e = require("moonsplice")

local WORD = "Renders"
local FAMILIES = {
  { "Roboto", "comps/assets/fonts/Roboto-Regular.ttf" },
  { "Playfair Display", "comps/assets/fonts/PlayfairDisplay.ttf" },
  { "JetBrains Mono", "comps/assets/fonts/JetBrainsMono-Regular.ttf" },
  { "Fraunces", "comps/assets/fonts/Fraunces.ttf" },
}

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "21  FONTS", size = 22, color = "#6b7894" }

    local rows = {}
    for i, fam in ipairs(FAMILIES) do
      local y = 120 + (i - 1) * 140
      s:text {
        x = 56, y = y + 18, text = fam[1], size = 20, color = "#6b7894",
      }
      rows[i] = s:text {
        x = 360, y = y, text = WORD, size = 72,
        color = "#e8edf7", font = fam[2], opacity = 0,
      }
    end

    s:script(function(t)
      t:stagger(rows, 0.45, { opacity = 1, x = 340 }, { each = 0.12, ease = "sineOut" })
    end)
  end,
}
