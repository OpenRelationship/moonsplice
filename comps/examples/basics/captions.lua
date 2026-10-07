-- Lower third. Bar writes, then the line tracks the VO as cue steps.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#10141c",

  scene = function(s)
    s:text {
      x = 640, y = 260, text = "cut 04", size = 18,
      color = "#6b7894", anchor = "center",
    }
    local bar = s:rect { x = 80, y = 528, w = 0, h = 4, rx = 2, color = "#3ee0c6" }
    local speaker = s:text {
      x = 80, y = 548, text = "EDITOR", size = 16,
      font = "comps/assets/fonts/Roboto-Bold.ttf",
      color = "#3ee0c6", opacity = 0,
    }
    s:captions {
      x = 80, y = 578, size = 36,
      font = "comps/assets/fonts/Roboto-Regular.ttf",
      color = "#f4f6fb",
      cues = {
        { 0.6, 1.6, "Hold the cut." },
        { 1.6, 2.7, "Let the type land." },
        { 2.7, 4.0, "Then get out." },
      },
    }

    s:script(function(t)
      t:wait(0.2)
      t:parallel(
        function() t:tween(bar, 0.45, { w = 640 }, "expoOut") end,
        function() t:tween(speaker, 0.3, { opacity = 1 }, "sineOut") end
      )
      t:wait(3.35)
    end)
  end,
}
