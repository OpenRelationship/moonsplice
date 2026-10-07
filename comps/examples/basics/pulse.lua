-- Kick on a mark. Baked energy, not a clock — same curve on the disc and the meters.
local e = require("moonsplice")

local kicks = {}
for i = 1, 200 do
  local x = (i - 1) / 50
  kicks[i] = math.abs(math.sin(x * math.pi * 2)) ^ 6
end

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#07090f",

  scene = function(s)
    local ring = s:circle { x = 640, y = 300, r = 120, color = "#1a2740" }
    local disc = s:circle { x = 640, y = 300, r = 56, color = "#4f8cff" }
    s:text {
      x = 640, y = 300, text = "KICK", size = 22,
      font = "comps/assets/fonts/Roboto-Bold.ttf",
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
      t:follow(disc, "scale", kicks, { duration = 4, gain = 0.42, base = 1 })
      t:follow(ring, "scale", kicks, { duration = 4, gain = 0.18, base = 1 })
      for i, bar in ipairs(meters) do
        local slice = {}
        local off = (i - 1) * 3
        for k = 1, #kicks do
          slice[k] = kicks[((k + off - 1) % #kicks) + 1]
        end
        t:follow(bar, "h", slice, { duration = 4, gain = 80, base = 16 })
      end
      t:wait(3.9)
    end)
  end,
}
