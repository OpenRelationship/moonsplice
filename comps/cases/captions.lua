-- Broadcast lower third. The bar writes, then the line changes with the VO.
-- Cues are timeline steps — seek lands on the right sentence.
local e = require("moonsplice")

local ROMAN = "comps/assets/fonts/Roboto-Regular.ttf"
local BOLD = "comps/assets/fonts/Roboto-Bold.ttf"

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "35  CAPTIONS", size = 22, color = "#6b7894" }

    -- Quiet plate so the third has something to sit on.
    s:rect { x = 0, y = 0, w = 1280, h = 720, color = "#10141c" }
    s:text {
      x = 640, y = 280, text = "cut 04", size = 18, font = ROMAN,
      color = "#6b7894", anchor = "center",
    }

    local bar = s:rect { x = 80, y = 528, w = 0, h = 4, rx = 2, color = "#3ee0c6" }
    local speaker = s:text {
      x = 80, y = 548, text = "EDITOR", size = 16, font = BOLD,
      color = "#3ee0c6", opacity = 0,
    }
    s:captions {
      x = 80, y = 578, size = 36, font = ROMAN, color = "#f4f6fb",
      cues = {
        { 0.55, 1.45, "Hold the cut." },
        { 1.45, 2.45, "Let the type land." },
        { 2.45, 3.6, "Then get out." },
      },
    }

    s:script(function(t)
      t:wait(0.15)
      t:parallel(
        function() t:tween(bar, 0.4, { w = 640 }, "expoOut") end,
        function() t:tween(speaker, 0.3, { opacity = 1 }, "sineOut") end
      )
      t:wait(3.05)
    end)
  end,
}
