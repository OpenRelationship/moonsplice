-- UI pieces start stacked on a page, then lift toward camera on their own Z.
-- Each svg is its own perspective plane; same orbit, different dolly.
local e = require("moonsplice")

local OX, OY = 640, 380
local PW, PH = 720, 480
local left, top = OX - PW / 2, OY - PH / 2

local function plane(s, src, x, y, w, h)
  return s:svg {
    src = src, x = x, y = y, w = w, h = h, anchor = "center",
    perspective = true, persp_margin = 2.1,
    yaw = 0, pitch = 0, dolly = 1, aperture = 0, fov = 0.62,
  }
end

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "13  PERSPECTIVE · EXPLODE", size = 22, color = "#6b7894" }
    s:text {
      x = 48, y = 668, text = "layers lift in Z from their page origins", size = 20, color = "#6b7894",
    }

    local chrome = plane(s, "comps/assets/ui_chrome.svg", left + 160 + 280, OY, 560, 480)
    local sidebar = plane(s, "comps/assets/ui_sidebar.svg", left + 80, top + 240, 160, 480)
    local card = plane(s, "comps/assets/ui_card.svg", left + 336, top + 170, 280, 180)
    local button = plane(s, "comps/assets/ui_button.svg", left + 602, top + 418, 180, 52)

    s:script(function(t)
      t:wait(0.2)
      t:parallel(
        function() t:tween(chrome, 1.4, { yaw = 0.42, pitch = -0.16, dolly = 0.88 }, "sineInOut") end,
        function() t:tween(sidebar, 1.4, { yaw = 0.42, pitch = -0.16, dolly = 1.12 }, "sineInOut") end,
        function() t:tween(card, 1.4, { yaw = 0.42, pitch = -0.16, dolly = 1.28 }, "sineInOut") end,
        function() t:tween(button, 1.4, { yaw = 0.42, pitch = -0.16, dolly = 1.48 }, "sineInOut") end
      )
      t:wait(0.4)
      t:parallel(
        function() t:tween(chrome, 0.9, { yaw = 0.18, pitch = -0.06, dolly = 0.96 }, "sineInOut") end,
        function() t:tween(sidebar, 0.9, { yaw = 0.18, pitch = -0.06, dolly = 1.06 }, "sineInOut") end,
        function() t:tween(card, 0.9, { yaw = 0.18, pitch = -0.06, dolly = 1.16 }, "sineInOut") end,
        function() t:tween(button, 0.9, { yaw = 0.18, pitch = -0.06, dolly = 1.28 }, "sineInOut") end
      )
    end)
  end,
}
