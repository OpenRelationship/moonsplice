-- Path (Catmull-Rom), wiggle, and stagger. All seek-safe.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "07  MOTION", size = 22, color = "#6b7894" }

    local traveler = s:circle { x = 160, y = 220, r = 18, color = "#f2b33d" }
    local drift = s:circle { x = 1040, y = 220, r = 28, color = "#4f8cff" }

    local bars = {}
    for i = 1, 8 do
      bars[i] = s:rect {
        x = 180 + (i - 1) * 120, y = 560, w = 72, h = 24, rx = 8,
        color = "#3ee0c6", anchor = "center",
      }
    end

    s:script(function(t)
      t:wiggle(drift, "y", { duration = 2, amp = 36, freq = 2.2, seed = 11 })
      t:parallel(
        function()
          t:path(traveler, 1.8, {
            { 420, 140 }, { 700, 300 }, { 980, 180 }, { 1120, 260 },
          }, "sineInOut")
        end,
        function()
          t:stagger(bars, 0.45, { h = 180, y = 480 }, { each = 0.08, ease = "backOut" })
        end
      )
    end)
  end,
}
