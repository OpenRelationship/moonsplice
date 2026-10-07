-- expect: frozen_span
-- A deliberately static vector node: lint must still report frozen_span.
local e = require("moonsplice")
return e.comp { width = 1280, height = 720, duration = 4, fps = 30, background = "#000000",
  scene = function(s)
    s:vector { x = 100, y = 100, w = 600, h = 400, draw = function(v, t)
      v:rect(0, 0, 600, 400, "#ffffff", 20)
    end }
  end }
