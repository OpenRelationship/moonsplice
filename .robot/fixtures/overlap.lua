-- must FAIL compile: overlapping tweens on same node.prop
local e = require("moonsplice")
return e.comp {
  width = 320, height = 240, duration = 2,
  scene = function(s)
    local r = s:rect { x = 0, y = 0, w = 10, h = 10, color = "#ffffff" }
    s:script(function(t)
      t:parallel(
        function() t:tween(r, 1.0, { x = 100 }) end,
        function() t:tween(r, 0.5, { x = 50 }) end)
    end)
  end,
}
