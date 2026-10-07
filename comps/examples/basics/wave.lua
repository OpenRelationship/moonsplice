-- Wave hello. Skeleton pose from t; the line is the cut.
local e = require("moonsplice")

local skeleton = {
  loop = true,
  bones = {
    { name = "root", x = 0, y = 0, rotation = -90, length = 0 },
    { name = "hips", parent = "root", length = 18 },
    { name = "torso", parent = "hips", length = 96 },
    { name = "head", parent = "torso", length = 36 },
    { name = "armL", parent = "torso", length = 72, rotation = 150 },
    { name = "armR", parent = "torso", length = 70, rotation = 28 },
    { name = "foreR", parent = "armR", length = 64, rotation = 18 },
  },
  animations = {
    wave = {
      bones = {
        armR = {
          rotate = {
            { time = 0, angle = 22 }, { time = 0.55, angle = 68 },
            { time = 1.1, angle = 22 }, { time = 1.65, angle = 68 },
            { time = 2.2, angle = 22 }, { time = 3.6, angle = 28 },
          },
        },
        foreR = {
          rotate = {
            { time = 0, angle = 8 }, { time = 0.55, angle = 52 },
            { time = 1.1, angle = 8 }, { time = 1.65, angle = 52 },
            { time = 2.2, angle = 8 }, { time = 3.6, angle = 16 },
          },
        },
      },
    },
  },
}

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:rect { x = 280, y = 560, w = 280, h = 3, color = "#243044" }
    s:spine {
      x = 300, y = 140, w = 240, h = 420,
      skeleton = skeleton, animation = "wave", color = "#f2c14e",
    }
    local hello = s:text {
      x = 800, y = 360, text = "hey.", size = 128,
      font = "comps/assets/fonts/Fraunces.ttf",
      color = "#f4f6fb", opacity = 0, scale = 1.08, anchor = "center",
    }

    s:script(function(t)
      t:wait(0.4)
      t:tween(hello, 0.5, { opacity = 1, scale = 1, x = 780 }, "expoOut")
      t:wait(2.9)
    end)
  end,
}
