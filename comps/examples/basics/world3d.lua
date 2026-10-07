-- Real 3D layer: glam+gltf+wgpu (CPU Lambert if the adapter is missing).
-- Pose from t. Same contract as s:lottie.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#0c1018",

  scene = function(s)
    local world = s:world {
      x = 640, y = 360, w = 1100, h = 620, anchor = "center",
      fov = 0.7, cam_y = 0.4, cam_z = 3.3,
    }
    local cube = s:mesh {
      parent = world, primitive = "cube",
      yaw = 0.35, pitch = -0.2, color = "#4f8cff", scale = 1.2,
    }
    s:mesh {
      parent = world, primitive = "sphere",
      x = 1.35, y = -0.15, z = 0.2, color = "#3ee0c6", scale = 0.55,
    }
    s:light { parent = world, dir = { -0.4, -1, -0.35 }, intensity = 1.1 }

    s:script(function(t)
      t:tween(cube, 1.6, { yaw = math.pi * 0.9 }, "sineInOut")
      t:tween(cube, 1.2, { yaw = math.pi * 0.2, pitch = 0.1 }, "sineInOut")
    end)
  end,
}
