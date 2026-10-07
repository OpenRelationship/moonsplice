-- A kick on a mark. Same baked curve drives the disc and a row of meters.
-- Seek-safe: the envelope is samples, not a clock.
local e = require("moonsplice")

local BOLD = "comps/assets/fonts/Roboto-Bold.ttf"

local kicks = {}
for i = 1, 180 do
  local x = (i - 1) / 50
  -- Four-on-the-floor with a decaying click.
  local beat = math.abs(math.sin(x * math.pi * 2))
  kicks[i] = beat ^ 6
end

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#07090f",

  scene = function(s)
    s:text { x = 48, y = 36, text = "36  PULSE", size = 22, color = "#6b7894" }

    local ring = s:circle { x = 640, y = 300, r = 110, color = "#1a2740", scale = 1 }
    local disc = s:circle { x = 640, y = 300, r = 52, color = "#4f8cff", scale = 1 }
    s:text {
      x = 640, y = 300, text = "KICK", size = 22, font = BOLD,
      color = "#f4f6fb", anchor = "center",
    }

    local meters = {}
    for i = 1, 12 do
      meters[i] = s:rect {
        x = 272 + (i - 1) * 64, y = 560, w = 36, h = 16, rx = 6,
        color = i % 3 == 0 and "#e85aa8" or "#3ee0c6",
        anchor = "center",
      }
    end

    s:script(function(t)
      t:follow(disc, "scale", kicks, { duration = 3.6, gain = 0.42, base = 1 })
      t:follow(ring, "scale", kicks, { duration = 3.6, gain = 0.18, base = 1 })
      for i, bar in ipairs(meters) do
        local slice = {}
        local off = (i - 1) * 3
        for k = 1, #kicks do
          slice[k] = kicks[((k + off - 1) % #kicks) + 1]
        end
        t:follow(bar, "h", slice, { duration = 3.6, gain = 72, base = 16 })
      end
      t:wait(3.5)
    end)
  end,
}
