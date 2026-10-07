-- must FAIL compile: script exceeds static duration
local e = require("moonsplice")
return e.comp {
  width = 320, height = 240, duration = 1,
  scene = function(s)
    local r = s:rect { x = 0, y = 0, w = 10, h = 10, color = "#ffffff" }
    s:script(function(t) t:tween(r, 2.0, { x = 100 }) end)
  end,
}
