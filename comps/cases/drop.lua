-- Physics bake (rapier2d): colliding glyphs. Simulation runs once at compile; render seeks.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2.4, fps = 30,
  background = "#0c1018",
  lint_allow = { "off_frame", "partial_escape" },

  scene = function(s)
    s:text { x = 48, y = 36, text = "29  DROP", size = 22, color = "#6b7894" }
    s:rect { x = 40, y = 628, w = 1200, h = 16, rx = 8, color = "#1c2538" }

    local glyphs = {}
    local word = "DROP"
    local colors = { "#3ee0c6", "#4f8cff", "#e85aa8", "#f2b33d" }
    for i = 1, #word do
      glyphs[i] = s:text {
        text = word:sub(i, i),
        x = 360 + (i - 1) * 140, y = 120, size = 112,
        color = colors[i], anchor = "center",
        font = "comps/assets/fonts/Roboto-Bold.ttf",
      }
    end

    s:text {
      x = 640, y = 670, text = "t:drop · rapier2d sampled at 1/240 · ordinary x/y/rotation",
      size = 20, color = "#6b7894", anchor = "center",
    }

    s:script(function(t)
      t:drop(glyphs, {
        duration = 2.2, gravity = 1600, ground_y = 620,
        restitution = 0.28, friction = 0.5, spin = 1.8,
      })
    end)
  end,
}
