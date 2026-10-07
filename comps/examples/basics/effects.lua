-- Native adjustment pass + compositing primitives.
--
--   cd moonsplice && moonsplice build
--   moonsplice render comps/examples/basics/effects.lua -o /tmp/effects.mp4
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3.2, fps = 30, background = "#10111a",

  scene = function(s)
    local panel = s:surface {
      x = 320, y = 140, w = 640, h = 420, rx = 32, color = "#00000000",
      shadow = { blur = 34, dy = 22, alpha = 0.42 },
    }
    local card = s:vector {
      parent = panel, x = 0, y = 0, w = 640, h = 420,
      effects = { contrast = 1.05, saturate = 1.12, hue_rotate = -8 },
      draw = function(v)
        v:rect(0, 0, 640, 420, { 0.08, 0.09, 0.16, 1 })
        v:radial(110, 100, 430, { 0.30, 0.12, 0.90, 0.94 }, { 0.30, 0.12, 0.90, 0 })
        v:radial(610, 350, 500, { 0.02, 0.74, 0.82, 0.80 }, { 0.02, 0.74, 0.82, 0 })
      end,
    }
    local sheen = s:rect {
      x = 350, y = 190, w = 580, h = 2, color = "#ffffff66",
      blend = "screen", opacity = 0,
    }
    local title = s:text {
      x = 640, y = 340, anchor = "center", text = "COLOR, COMPOSITED",
      size = 54, color = "#ffffff",
    }

    s:script(function(t)
      t:wait(0.1)
      t:parallel(
        function() t:tween(card, 1.1, { effect_hue_rotate = 32 }, "sineInOut") end,
        function() t:tween(sheen, 1.1, { opacity = 1 }, "sineOut") end
      )
      t:tween(card, 0.9, { effect_blur = 8, effect_saturate = 0.35 }, "sineInOut")
      t:tween(card, 1.0, { effect_blur = 0, effect_saturate = 1.15 }, "sineInOut")
    end)
  end,
}
