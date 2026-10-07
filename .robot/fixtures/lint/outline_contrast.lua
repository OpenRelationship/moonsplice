-- expect: clean
-- Black fill with a white outline is legible; contrast must use the outline colour.
local e = require("moonsplice")
return e.comp { width = 1280, height = 720, duration = 3, fps = 30, background = "#000000",
  scene = function(s)
    local w = s:text { x = 640, y = 360, text = "OUTLINE", size = 160, anchor = "center", color = "#000000",
      outline = 0.8, weight = 0, outline_color = "#ffffff" }
    s:script(function(t) t:wait(0.2); t:tween(w, 2.6, { outline = 0.3, weight = 0.2 }, "sineInOut") end)
  end }
