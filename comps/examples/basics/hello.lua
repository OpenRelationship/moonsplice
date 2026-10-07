local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#14161f",

  scene = function(s)
    local dot = s:circle { id = "dot", x = 180, y = 360, r = 60, color = "#f28c33" }
    local bar = s:rect { id = "bar", x = 0, y = 600, w = 220, h = 56, rx = 12, color = "#409fe8" }
    local title = s:text {
      id = "title", x = 640, y = 360, text = "moonsplice", size = 120,
      color = "#ffffff", opacity = 0, anchor = "center",
    }

    s:script(function(t)
      t:parallel(
        function() t:tween(dot, 1.2, { x = 1100, color = "#e84a5f" }, "cubicInOut") end,
        function() t:tween(bar, 1.2, { x = 1060, w = 160 }, "quadOut") end
      )
      t:tween(dot, 0.6, { r = 140, opacity = 0.15 }, "expoOut")
      t:parallel(
        function() t:tween(title, 0.8, { opacity = 1 }, "sineOut") end,
        function() t:tween(title, 0.8, { size = 140 }, "backOut") end
      )
      t:wait(0.4)
      t:tween(title, 0.8, { y = 200 }, "cubicInOut")
    end)
  end,
}
