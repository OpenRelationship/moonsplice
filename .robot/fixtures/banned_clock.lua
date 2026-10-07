-- must FAIL load: comps get no clock
local e = require("moonsplice")
local now = os.time()
return e.comp {
  width = 320, height = 240, duration = 1,
  scene = function(s) s:rect { x = now % 100, y = 0, w = 10, h = 10, color = "#ffffff" } end,
}
