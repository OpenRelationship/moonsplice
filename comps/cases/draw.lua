-- Custom love.graphics draw fn: pure f(t), no clocks, no per-frame GPU alloc.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 2, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "08  CUSTOM DRAW", size = 22, color = "#6b7894" }

    s:draw(function(t, g)
      local cx, cy = 640, 390
      local turn = t * 1.15
      g.setLineWidth(2)
      for i = 1, 18 do
        local a = turn + i * (math.pi * 2 / 18)
        local u = i / 18
        g.setColor(0.24 + 0.4 * u, 0.88 - 0.3 * u, 0.78, 0.85)
        g.line(cx, cy, cx + math.cos(a) * 220, cy + math.sin(a) * 220)
      end
      g.setColor(0.95, 0.70, 0.24, 1)
      local scan = 180 + (920 * ((t / 2) % 1))
      g.rectangle("fill", scan, 250, 6, 280, 3, 3)
      g.setColor(0.91, 0.93, 0.97, 1)
      g.circle("line", cx, cy, 90)
    end)
  end,
}
