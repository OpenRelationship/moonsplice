-- Practical lights behind a title. Bloom is the air, not a labeled demo.
local e = require("moonsplice")

local DISPLAY = "comps/assets/fonts/Fraunces.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.2, fps = 30,
  background = "#07090f",

  scene = function(s)
    s:text { x = 48, y = 36, text = "23  FX", size = 22, color = "#6b7894" }

    local plate = s:fx {
      x = 140, y = 90, w = 1000, h = 540,
      chain = { "bloom", "chroma", "vignette", "grain", "shadertoy" },
      bloom = 0.22, chroma = 0.35, vignette = 0.18, grain = 0.03,
      shadertoy = [[
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
          vec2 uv = fragCoord / iResolution.xy;
          vec4 c = Texel(iChannel0, uv);
          float pulse = 0.94 + 0.06 * sin(iTime * 5.0);
          fragColor = vec4(c.rgb * vec3(1.03, 0.99, 1.05) * pulse, c.a);
        }
      ]],
    }

    s:rect { parent = plate, x = 0, y = 0, w = 1000, h = 540, color = "#0c1018" }
    s:circle { parent = plate, x = 260, y = 200, r = 100, color = "#3ee0c6" }
    s:circle { parent = plate, x = 760, y = 280, r = 130, color = "#4f8cff" }
    s:circle { parent = plate, x = 520, y = 160, r = 40, color = "#e85aa8" }
    s:text {
      parent = plate, x = 500, y = 280, text = "GLOW", size = 108, font = DISPLAY,
      color = "#ffffff", anchor = "center",
    }

    s:script(function(t)
      t:tween(plate, 1.3, { fx_bloom = 0.9, fx_chroma = 3.8, fx_vignette = 0.48 }, "sineInOut")
      t:tween(plate, 1.1, { fx_bloom = 0.38, fx_chroma = 1.1 }, "sineInOut")
      t:wait(0.5)
    end)
  end,
}
