-- Solids (.robot/docs/solids.robot): harbour furniture built from scratch by Manifold, as trees of plain
-- values in the comp's assets. A can buoy turned from a profile with its fender ring, lifting eyes
-- and topmark; a mushroom bollard; a stud-less chain of real interlocking links; a clinker-less
-- dinghy whose hull is a shell (an outer hull minus an inner one) with thwarts and a transom. They
-- are built once, cached by the tree's hash, and drawn by Bevy like any mesh. Authored Z-up in metres.
local e = require("moonsplice")
local F = "/Users/shinyobjectz/cadence/evals/assets/fonts/"

-- one chain link: two half tori joined by two straight wires
local LINK = { op = "union",
  { op = "trim", normal = { 1, 0, 0 }, child = { op = "torus", r = 0.05, tube = 0.016, segments = 32 }, move = { 0.035, 0, 0 } },
  { op = "trim", normal = { -1, 0, 0 }, child = { op = "torus", r = 0.05, tube = 0.016, segments = 32 }, move = { -0.035, 0, 0 } },
  { op = "cylinder", h = 0.072, r = 0.016, segments = 16, rotate = { 0, 90, 0 }, move = { 0, 0.05, 0 } },
  { op = "cylinder", h = 0.072, r = 0.016, segments = 16, rotate = { 0, 90, 0 }, move = { 0, -0.05, 0 } },
}

-- the dinghy's outer hull: the lower half of the hull of two ellipsoids, a full stern and a fine bow
local HULL = { op = "trim", normal = { 0, 0, -1 }, child = { op = "hull",
  { op = "sphere", r = 1, scale = { 1.25, 0.62, 0.45 }, move = { -0.35, 0, 0 } },
  { op = "sphere", r = 1, scale = { 0.25, 0.12, 0.45 }, move = { 1.15, 0, 0 } } } }

return e.comp {
  width = 1280, height = 720, duration = 6, fps = 30, background = "#10161c",

  assets = {
    { id = "buoy", solid = { op = "union",
      { op = "revolve", segments = 64,
        profile = { { 0, 0 }, { 0.42, 0 }, { 0.46, 0.08 }, { 0.46, 1.0 }, { 0.3, 1.25 }, { 0.12, 1.32 }, { 0, 1.32 } } },
      { op = "torus", r = 0.47, tube = 0.035, move = { 0, 0, 0.55 } },
      { op = "radial", n = 6, child = { op = "capsule", r = 0.03, h = 0.42, move = { 0.465, 0, 0.32 } } },
      { op = "difference", move = { 0, 0, 1.29 },
        { op = "torus", r = 0.09, tube = 0.025, rotate = { 90, 0, 0 } },
        { op = "cube", size = { 1, 1, 1 }, move = { 0, 0, -0.5 } } },
    } },
    { id = "topmark", solid = { op = "union",
      { op = "cylinder", r = 0.025, h = 0.5, center = false },
      { op = "cylinder", r1 = 0.2, r2 = 0, h = 0.32, move = { 0, 0, 0.46 }, center = false },
    } },
    { id = "bollard", solid = { op = "smooth", angle = 50, smoothness = 0.3, refine = 2,
      child = { op = "revolve", segments = 48,
        profile = { { 0, 0 }, { 0.32, 0 }, { 0.32, 0.06 }, { 0.2, 0.12 }, { 0.16, 0.5 }, { 0.17, 0.62 },
                    { 0.28, 0.72 }, { 0.28, 0.8 }, { 0.12, 0.86 }, { 0, 0.86 } } } } },
    { id = "chain", parts = 15, solid = { op = "repeat", n = 15, union = false,
      step = { rotate = { 90, 0, 0 }, move = { 0.118, 0, 0 } }, child = LINK } },
    { id = "dinghy", solid = { op = "union",
      -- the shell: the hull's lower half less the same, shrunk and raised
      { op = "difference",
        HULL,
        { op = "trim", normal = { 0, 0, -1 }, move = { 0, 0, 0.05 }, child = { op = "hull",
          { op = "sphere", r = 1, scale = { 1.2, 0.57, 0.3 }, move = { -0.35, 0, 0 } },
          { op = "sphere", r = 1, scale = { 0.22, 0.09, 0.3 }, move = { 1.13, 0, 0 } } } } },
      -- thwarts and transom, cut to the hull's own shape so nothing pokes through the planking
      { op = "intersection", HULL, { op = "union",
        { op = "box", size = { 0.18, 1.4, 0.04 }, move = { -0.1, 0, -0.08 } },
        { op = "box", size = { 0.18, 1.4, 0.04 }, move = { 0.55, 0, -0.08 } },
        { op = "box", size = { 0.05, 1.4, 0.6 }, move = { -1.5, 0, -0.3 } } } },
    } },
  },

  nodes = {
    { id = "quay", kind = "world", x = 0, y = 0, w = 1280, h = 720,
      cam_x = 4.6, cam_y = 2.4, cam_z = 5.6, look_x = 0.45, look_y = 0.2, look_z = 0.2, fov = 0.6,
      background = "#1c1a22", ambient = 380, ambient_color = "#a8bccc", bloom = 0.12, tonemapping = "agx",
      fog = { color = "#2a2430", start = 8, ["end"] = 22 } },
    { id = "sky", kind = "mesh", parent = "quay", primitive = "plane", size = { 60, 1, 16 }, y = 2, z = -14,
      pitch = 1.5708, color = "#b85a32", emissive = "#b85a32", emissive_strength = 1.2, unlit = true },
    { id = "sea", kind = "mesh", parent = "quay", primitive = "plane", size = { 40, 1, 40 }, y = -0.35,
      color = "#22495a", metallic = 0.3, roughness = 0.08 },
    { id = "deck", kind = "mesh", parent = "quay", primitive = "box", size = { 3.2, 0.5, 6 }, x = -1.6, y = -0.25, z = 0,
      color = "#6f6458", roughness = 0.9 },
    { id = "edge", kind = "mesh", parent = "quay", primitive = "box", size = { 0.24, 0.1, 6 }, x = -0.08, y = 0.05, z = 0,
      color = "#8a8172", roughness = 0.85 },
    { id = "bollard", kind = "mesh", parent = "quay", src = "asset:bollard", x = -0.6, y = 0, z = -0.9,
      color = "#2b3036", metallic = 0.6, roughness = 0.45 },
    { id = "chain", kind = "mesh", parent = "quay", src = "asset:chain", x = -0.42, y = 0.02, z = -0.75, yaw = -0.35,
      color = "#3c3631", metallic = 0.85, roughness = 0.4 },
    { id = "buoy", kind = "mesh", parent = "quay", src = "asset:buoy", x = 1.15, y = -0.6, z = -0.6,
      color = "#b8322a", roughness = 0.45 },
    { id = "topmark", kind = "mesh", parent = "quay", src = "asset:topmark", x = 1.15, y = 0.77, z = -0.6,
      color = "#1d2125", roughness = 0.5 },
    { id = "dinghy", kind = "mesh", parent = "quay", src = "asset:dinghy", x = 1.4, y = -0.02, z = 1.4, yaw = 0.5,
      color = "#d9cfbd", roughness = 0.55 },
    { id = "key", kind = "light", parent = "quay", dir = { -0.45, -0.55, -0.7 }, intensity = 3.2, color = "#ffd8b0" },
    { id = "sun", kind = "light", parent = "quay", dir = { 0.3, -0.25, 0.9 }, intensity = 2.6, color = "#ff9a5c" },

    { id = "band", kind = "rect", x = 0, y = 616, w = 1280, h = 104, color = "#0b1218f2" },
    { id = "title", kind = "text", x = 48, y = 636, text = "Solids", size = 40,
      font = F .. "InstrumentSerif-Regular.ttf", color = "#f4efe6" },
    { id = "spec", kind = "text", x = 48, y = 684, text = "buoy  ·  bollard  ·  chain  ·  dinghy  —  built by Manifold from trees in the comp",
      size = 22, font = F .. "BarlowCondensed-Medium.ttf", color = "#ffc477", tracking = 1 },
  },

  keys = {
    { "quay", "cam_x", 0.2, 4.6 }, { "quay", "cam_x", 6, 2.4, "sineInOut" },
    { "quay", "cam_z", 0.2, 5.6 }, { "quay", "cam_z", 6, 6.3, "sineInOut" },
  },

  systems = {
    { name = "swell", order = 1, source = [[
      return function(t)
        local bob = 0.05 * math.sin(t * 2.1) + 0.02 * math.sin(t * 3.7 + 1)
        local lean = 0.06 * math.sin(t * 1.6)
        return {
          { id = "sea", y = -0.35 + 0.02 * math.sin(t * 0.9) },
          { id = "buoy", y = -0.6 + bob, roll = lean },
          { id = "topmark", x = 1.15 + math.sin(lean) * 1.37, y = 0.77 + bob, roll = lean },
          { id = "dinghy", y = -0.02 + 0.6 * bob, roll = 0.04 * math.sin(t * 1.3 + 0.8), pitch = 0.02 * math.sin(t * 1.1) },
        }
      end ]] },
  },
}
