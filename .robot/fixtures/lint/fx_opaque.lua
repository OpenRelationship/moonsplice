-- expect: fx_opaque
local e = require("moonsplice")
return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30, background = "#000000",
  scene = function(s)
    local plate = s:fx { x = 100, y = 100, w = 600, h = 400, chain = { "bloom", "shadertoy" },
      shadertoy = "void mainImage(out vec4 fragColor, in vec2 fragCoord) { fragColor = Texel(iChannel0, fragCoord / iResolution.xy); }" }
    local r = s:rect { parent = plate, x = 0, y = 0, w = 600, h = 400, color = "#ff0000" }
    s:script(function(t) t:tween(r, 1, { x = 100 }, "sineInOut"); t:wait(1) end)
  end,
}
