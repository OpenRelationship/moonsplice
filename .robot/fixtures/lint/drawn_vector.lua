-- expect: clean
-- A vector node animated only inside draw(v, t): lint must NOT report frozen_span.
local e = require("moonsplice")
return e.comp { width = 1280, height = 720, duration = 4, fps = 30, background = "#000000",
  scene = function(s)
    s:vector { x = 100, y = 100, w = 600, h = 400, draw = function(v, t)
      local p = math.min(1, t / 3.5)
      v:move(0, 200); v:line(600 * p, 200); v:stroke(4, "#ffffff")
    end }
  end }
