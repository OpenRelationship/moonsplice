-- Every fx pass the rasterizer runs itself, one panel each. The shadertoy
-- panel is the GLSL escape hatch (canvas path) for comparison.
local e = require("moonsplice")
local names = { "bloom", "glow", "blur", "vignette", "chroma", "grain",
                "tonemap", "pixelate", "posterize", "filmgrain", "kawase", "shadertoy" }
return e.comp {
  width = 1280, height = 720, duration = 2.5, fps = 30, background = "#07090f",
  scene = function(s)
    local plates = {}
    for i, name in ipairs(names) do
      local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
      local plate = s:fx {
        x = 20 + col * 315, y = 20 + row * 230, w = 300, h = 210, chain = { name },
        bloom = 0.8, glow = 0.9, blur = 6, vignette = 0.6, chroma = 4, grain = 0.2,
        tonemap = 1, pixelate = 0.5, posterize = 0.6,
        shadertoy = [[
          void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            vec2 uv = fragCoord / iResolution.xy; vec4 c = Texel(iChannel0, uv);
            fragColor = vec4(c.rgb * vec3(1.2, 0.8, 0.8), c.a); }
        ]],
      }
      plates[#plates + 1] = plate
      s:rect { parent = plate, x = 0, y = 0, w = 300, h = 210, color = "#141a2a" }
      s:circle { parent = plate, x = 90, y = 100, r = 60, color = "#3ee0c6" }
      s:circle { parent = plate, x = 210, y = 120, r = 50, color = "#ffffff" }
      s:text { parent = plate, x = 150, y = 170, text = name, size = 30, color = "#ffd166", anchor = "center" }
    end
    s:script(function(t)
      t:wait(0.2)
      t:tween(plates[1], 1.0, { fx_bloom = 0.2 }, "sineInOut")
      t:tween(plates[5], 1.0, { fx_chroma = 1 }, "sineInOut")
      t:wait(0.3)
    end)
  end,
}
