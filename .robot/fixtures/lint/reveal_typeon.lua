-- expect: clean
-- Type-on via reveal is motion; must not read as frozen.
local e = require("moonsplice")
return e.comp { width = 1280, height = 720, duration = 4, fps = 30, background = "#000000",
  scene = function(s)
    local b = s:text { x = 100, y = 200, wrap = 900, size = 40, reveal = 0, color = "#ffffff",
      text = "A paragraph that types on over the whole comp so nothing is ever static for long." }
    s:script(function(t) t:wait(0.2); t:tween(b, 3.6, { reveal = 1 }, "linear") end)
  end }
