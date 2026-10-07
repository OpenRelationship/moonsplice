-- Bevy's renderer from rows (.robot/docs/rows.robot): PBR materials, emissive and bloom, point and spot
-- lights with shadows, fog. The torus and sphere are nodes under the world; the ring of pillars,
-- the floor and the lights are entities a system returns from t every frame (render/src/world.rs).
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 6, fps = 30, background = "#07090d",

  nodes = {
    { id = "world", kind = "world", x = 0, y = 0, w = 1280, h = 720,
      cam_x = 0, cam_y = 2.6, cam_z = 9, look_y = 0.6, fov = 0.62,
      background = "#07090d", bloom = 0.22, ambient = 60, tonemapping = "agx",
      fog = { color = "#0b1016", start = 8, ["end"] = 30 } },
    { id = "torus", kind = "mesh", parent = "world", primitive = "torus", y = 1.3, scale = 1.6, color = "#e9e1cf",
      metallic = 1, roughness = 0.18, detail = 48 },
    { id = "core", kind = "mesh", parent = "world", primitive = "sphere", y = 1.3, scale = 0.55, color = "#ff7a3d",
      emissive = "#ff7a3d", emissive_strength = 10, detail = 32 },
    { id = "title", kind = "text", x = 48, y = 36, text = "WORLD  ·  BEVY", size = 18, color = "#8a96a8", ls = 3 },
    { id = "caption", kind = "text", x = 48, y = 668, text = "PBR · emissive + bloom · spot shadows · fog · 26 rows from t",
      size = 15, color = "#5b6676" },
  },

  keys = {
    { "world", "cam_x", 0, 0 }, { "world", "cam_x", 6, 3.2, "sineInOut" },
    { "world", "cam_z", 0, 9 }, { "world", "cam_z", 6, 7.4, "sineInOut" },
  },

  systems = {
    { name = "ring", order = 1, source = [[
      return function(t)
        local rows = {}
        for k = 0, 23 do
          local a = k / 24 * math.pi * 2 + t * 0.12
          local hgt = 0.6 + 1.6 * (0.5 + 0.5 * math.sin(k * 1.7 + t * 1.3))
          rows[#rows + 1] = {
            id = "pillar" .. k, parent = "world", shape = "cube",
            pos = { math.cos(a) * 4.2, hgt / 2, math.sin(a) * 4.2 }, yaw = -a,
            size = { 0.32, hgt, 0.32 }, color = "#1b2129", metallic = 0.6, roughness = 0.35,
            emissive = k % 6 == 0 and "#ff7a3d" or nil, emissive_strength = 6,
          }
        end
        rows[#rows + 1] = { id = "floor", parent = "world", shape = "plane", size = { 30, 1, 30 }, color = "#10141a", roughness = 0.9 }
        rows[#rows + 1] = { id = "spot", parent = "world", light = "spot", pos = { 0, 6, 0.5 }, dir = { 0, -1, -0.1 },
          intensity = 2400000, range = 30, angle = 0.55, color = "#ffe2c4", shadows = true }
        rows[#rows + 1] = { id = "rim", parent = "world", light = "point", pos = { -3, 1.2, -3 }, intensity = 600000,
          range = 12, color = "#3d7bff" }
        return rows
      end ]] },
  },
}
