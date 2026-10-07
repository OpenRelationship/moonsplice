-- A wave hello. Bones are the figure; type is the line. Pose from t, never dt.
local e = require("moonsplice")

local DISPLAY = "comps/assets/fonts/Fraunces.ttf"

local skeleton = {
  loop = true,
  bones = {
    { name = "root", x = 0, y = 0, rotation = -90, length = 0 },
    { name = "hips", parent = "root", length = 18, rotation = 0 },
    { name = "torso", parent = "hips", length = 96, rotation = 0 },
    { name = "head", parent = "torso", length = 36, rotation = 0 },
    { name = "armL", parent = "torso", x = 0, y = 0, length = 72, rotation = 150 },
    { name = "armR", parent = "torso", length = 70, rotation = 28 },
    { name = "foreR", parent = "armR", length = 64, rotation = 18 },
  },
  animations = {
    wave = {
      bones = {
        armR = {
          rotate = {
            { time = 0, angle = 22 },
            { time = 0.55, angle = 68 },
            { time = 1.1, angle = 22 },
            { time = 1.65, angle = 68 },
            { time = 2.2, angle = 22 },
            { time = 3.4, angle = 28 },
          },
        },
        foreR = {
          rotate = {
            { time = 0, angle = 8 },
            { time = 0.55, angle = 52 },
            { time = 1.1, angle = 8 },
            { time = 1.65, angle = 52 },
            { time = 2.2, angle = 8 },
            { time = 3.4, angle = 16 },
          },
        },
        head = {
          rotate = {
            { time = 0, angle = -4 },
            { time = 1.1, angle = 6 },
            { time = 2.2, angle = -2 },
            { time = 3.4, angle = 0 },
          },
        },
      },
    },
  },
}

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "37  SPINE", size = 22, color = "#6b7894" }

    s:rect { x = 280, y = 560, w = 280, h = 3, color = "#243044" }
    s:spine {
      x = 300, y = 140, w = 240, h = 420,
      skeleton = skeleton, animation = "wave",
      color = "#f2c14e",
    }
    local hello = s:text {
      x = 780, y = 360, text = "hey.", size = 120, font = DISPLAY,
      color = "#f4f6fb", opacity = 0, scale = 1.08, anchor = "center",
    }

    s:script(function(t)
      t:wait(0.35)
      t:tween(hello, 0.45, { opacity = 1, scale = 1, x = 760 }, "expoOut")
      t:wait(2.6)
    end)
  end,
}
