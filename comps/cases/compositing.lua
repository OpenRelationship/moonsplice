-- Surface, soft shadow, group parenting, nested opacity, screen blend + glyphs.
-- Glyphs after a screen layer must stay as type, not solid character blocks.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "04  COMPOSITING", size = 22, color = "#6b7894" }

    local card = s:group { x = 640, y = 360, opacity = 0 }
    s:surface {
      parent = card, x = 0, y = 0, w = 640, h = 320, rx = 32,
      color = "#151c2c", anchor = "center",
      shadow = { blur = 36, dy = 22, alpha = 0.5 },
    }
    s:rect {
      parent = card, x = 0, y = -86, w = 520, h = 2, color = "#ffffff66",
      blend = "screen", anchor = "center",
    }
    s:text {
      parent = card, x = 0, y = -8, text = "LAYER STACK", size = 52,
      color = "#ffffff", anchor = "center",
    }
    s:text {
      parent = card, x = 0, y = 56, text = "shadow · screen · nested opacity", size = 22,
      color = "#8b97b0", anchor = "center",
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(card, 0.7, { opacity = 1, y = 348 }, "backOut") end
      )
      t:tween(card, 0.8, { rotation = 0.04, scale = 1.04 }, "sineInOut")
      t:tween(card, 0.5, { opacity = 0.35, scale = 0.96 }, "sineInOut")
    end)
  end,
}
