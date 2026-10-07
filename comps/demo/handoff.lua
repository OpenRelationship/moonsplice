-- A title over real footage. The caption is deliberately mistimed: the agent's job is to
-- move it onto the moment the bottle actually changes hands, which it finds in the fact
-- log perceived from this very clip -- never by looking at the picture.
local e = require("moonsplice")

local CLIP = "vision/cache/clips/person_7876232.mp4"

return e.comp {
  width = 960, height = 506, duration = 14.32, fps = 25,
  background = "#000000",

  scene = function(s)
    s:video { src = CLIP, x = 0, y = 0, w = 960, h = 506, from = 0, duration = 14.32 }
    s:rect { x = 0, y = 386, w = 960, h = 120, color = "#0a0e14cc" }
    s:captions {
      x = 480, y = 430, size = 34, color = "#f4f6fb", anchor = "center",
      cues = { { 1.00, 3.00, "handover" } },
    }
  end,
}
