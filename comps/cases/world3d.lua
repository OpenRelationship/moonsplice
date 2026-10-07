-- Real 3D as a Lottie-shaped layer: pose from t, raster into ImageData.
-- Built-in cube + sphere plus a tiny original cube.gltf. No Bevy/Godot loop.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "16  WORLD 3D", size = 22, color = "#6b7894" }
    s:text {
      x = 48, y = 668, text = "glTF cube · unit sphere · camera look-at from t", size = 20, color = "#6b7894",
    }

    local world = s:world {
      x = 640, y = 360, w = 960, h = 540, anchor = "center",
      fov = 0.72, cam_x = 0, cam_y = 0.45, cam_z = 3.4,
      look_x = 0, look_y = 0, look_z = 0,
    }
    local logo = s:mesh {
      parent = world, src = "comps/assets/cube.gltf",
      x = -0.85, y = 0, z = 0, yaw = 0.2, color = "#4f8cff", scale = 1.15,
    }
    s:mesh {
      parent = world, primitive = "sphere",
      x = 1.05, y = -0.05, z = 0.15, color = "#e85aa8", scale = 0.85,
    }
    s:light { parent = world, dir = { -0.45, -1, -0.4 }, intensity = 1.15 }

    s:script(function(t)
      t:wait(0.12)
      t:parallel(
        function() t:tween(logo, 1.5, { yaw = math.pi * 0.85, pitch = -0.2 }, "sineInOut") end,
        function() t:tween(world, 1.5, { cam_x = 0.55, look_x = 0.2 }, "sineInOut") end
      )
      t:wait(0.2)
      t:parallel(
        function() t:tween(logo, 1.05, { yaw = math.pi * 0.35 }, "sineInOut") end,
        function() t:tween(world, 1.05, { cam_x = 0.1, look_x = 0 }, "sineInOut") end
      )
    end)
  end,
}
