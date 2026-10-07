-- Bound input: scene reads s.input.bg (string path) from sidecar / --inputs JSON.
local e = require("moonsplice")
return e.comp {
  width = 64, height = 64, duration = 0.1, fps = 10,
  background = "#000000",
  inputs = {
    bg = { kind = "image" },
  },
  scene = function(s)
    s:image { src = s.input.bg, x = 0, y = 0, w = 64, h = 64 }
  end,
}
