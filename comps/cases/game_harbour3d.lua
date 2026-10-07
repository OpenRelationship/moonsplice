-- Harbour Run in 3D (the game eval's seed): the same game as game_harbour.lua, drawn by Bevy at
-- 100 px to the metre under a three-quarter camera. Below, the 2D original's notes.
-- Harbour Run in rows (.robot/docs/rows.robot): a game, and with no input log a film of itself
-- (.robot/docs/design.robot, amendment 2026-10-06). The fold is two systems, game.init and game.step; the HUD is
-- text nodes a system fills from the state; the sea and the launch are a vector whose draw is code
-- in a row; the course's geometry is `shared`. Rapier does the water: thrust is an impulse along
-- the heading, drag and helm are damping and spin. Buoys keep their real light characteristics
-- (Fl R 4s, Fl G 4s). With no log the autopilot plays; the first key a player presses takes the helm.
--   moonsplice play comps/cases/game_harbour.lua      -- up: thrust, left/right: helm
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 22, fps = 30, background = "#06121c",

  game = { rate = 60 },

  nodes = {
    { id = "harbour", kind = "world", x = 0, y = 0, w = 1280, h = 720,
      cam_x = 4.2, cam_y = 9, cam_z = 27, look_x = 4.2, look_y = 0, look_z = 20, fov = 0.72,
      background = "#2a1c22", ambient = 260, ambient_color = "#8fb0c8", bloom = 0.2, tonemapping = "agx",
      fog = { color = "#3a2a2c", start = 12, ["end"] = 42 } },
    { id = "sea", kind = "mesh", parent = "harbour", primitive = "plane", size = { 60, 1, 50 }, x = 17, z = 11,
      color = "#1f4a5c", metallic = 0.2, roughness = 0.1 },
    { id = "sky", kind = "mesh", parent = "harbour", primitive = "plane", size = { 120, 1, 24 }, x = 17, y = 4, z = -18,
      pitch = 1.5708, color = "#b4542a", emissive = "#b4542a", emissive_strength = 1.2, unlit = true },
    { id = "dusk", kind = "light", parent = "harbour", dir = { 0.95, -0.3, -0.1 }, intensity = 0.35, color = "#ffb27a" },
    { id = "moon", kind = "light", parent = "harbour", dir = { -0.3, -0.8, -0.5 }, intensity = 0.3, color = "#9ab8d0" },
    { id = "hudband", kind = "rect", x = 0, y = 0, w = 1280, h = 152, color = "#0b1218f7" },
    { id = "legendband", kind = "rect", x = 0, y = 652, w = 1280, h = 68, color = "#0b1218e6" },
    { id = "doneband", kind = "rect", x = 440, y = 270, w = 400, h = 150, color = "#0b1218fa", rx = 6, opacity = 0 },
    -- the almanac: set like a tide table, tabular figures, no boxes
    { id = "name", kind = "text", x = 40, y = 34, text = "HARBOUR RUN", size = 20, color = "#e9e1cf", tracking = 3 },
    { id = "gate_label", kind = "text", x = 40, y = 54, text = "GATE", size = 20, color = "#a9bcc6", tracking = 2 },
    { id = "time_label", kind = "text", x = 160, y = 54, text = "ELAPSED", size = 20, color = "#a9bcc6", tracking = 2 },
    { id = "knots_label", kind = "text", x = 300, y = 54, text = "KNOTS", size = 20, color = "#a9bcc6", tracking = 2 },
    { id = "gate", kind = "text", x = 40, y = 94, text = "1/8", size = 30, color = "#e9e1cf" },
    { id = "time", kind = "text", x = 160, y = 94, text = "00:00.0", size = 30, color = "#e9e1cf" },
    { id = "knots", kind = "text", x = 300, y = 94, text = "0.0", size = 30, color = "#e9e1cf" },
    { id = "mode", kind = "text", x = 1090, y = 34, text = "AUTOPILOT", size = 20, color = "#f2a541", tracking = 3 },
    { id = "done", kind = "text", x = 640, y = 320, text = "", size = 64, color = "#e9e1cf", anchor = "center", opacity = 0 },
    { id = "done2", kind = "text", x = 640, y = 380, text = "MOORED", size = 22, color = "#f2a541", tracking = 4, anchor = "center", opacity = 0 },
    { id = "legend", kind = "text", x = 40, y = 668, text = "Fl R 4s   Fl G 4s      UP thrust   LEFT RIGHT helm", size = 20, color = "#c7d3d9", tracking = 1 },
  },

  -- what this game is, whatever an edit does to it: the course is run to the end and moored,
  -- the HUD reads, the harbour is in 3D (lint: expect_failed)
  expect = {
    { id = "harbour-3d", says = "the harbour is drawn in 3D", node = "harbour" },
    { id = "all-gates", says = "the launch runs all eight gates", node = "gate", prop = "text", t0 = 0, t1 = 22, holds = "ever", op = "has", value = "8/8" },
    { id = "moored", says = "the run ends moored, its time on the card", node = "done2", prop = "opacity", at = 22, op = ">=", value = 0.9 },
    { id = "hud-time", says = "the elapsed time reads", node = "time" },
    { id = "hud-gate", says = "the gate count reads", node = "gate" },
    { id = "legend", says = "the lights and keys are explained", node = "legend", prop = "text", op = "has", value = "Fl R 4s" },
  },
  systems = {
    { name = "shared", order = 0, source = [==[
local S = {}
S.W, S.H = 1280, 720
S.WORLD_W, S.WORLD_H = 3400, 2200
S.GAP = 190
S.START = { 420, 2000 }
S.GATES = {
  { 760, 1640 }, { 1250, 1180 }, { 1580, 640 }, { 2250, 480 },
  { 2800, 960 }, { 2600, 1620 }, { 1900, 1820 }, { 1150, 1900 },
}
for i, gt in ipairs(S.GATES) do
  local p = S.GATES[i - 1] or S.START
  local n = S.GATES[i + 1] or { gt[1] * 2 - p[1], gt[2] * 2 - p[2] }
  gt[3] = math.atan2(n[2] - p[2], n[1] - p[1])
end
S.SAND, S.NIGHT, S.DEEP = "#e9e1cf", "#06121c", "#0b2431"
S.AMBER, S.RED, S.GREEN = "#f2a541", "#e5484d", "#46c37b"
function S.gate_buoys(g)
  local cx, cy, a = g[1], g[2], g[3]
  local nx, ny = -math.sin(a), math.cos(a) -- across the course
  return cx - nx * S.GAP / 2, cy - ny * S.GAP / 2, cx + nx * S.GAP / 2, cy + ny * S.GAP / 2
end
function S.wrap(a)
  while a > math.pi do a = a - 2 * math.pi end
  while a < -math.pi do a = a + 2 * math.pi end
  return a
end
function S.clock(t)
  if not t then return "--:--.-" end
  return string.format("%02d:%04.1f", math.floor(t / 60), t % 60)
end
return S ]==] },
    { name = "game.init", order = 1, source = [==[
local S = shared
local W, H, WORLD_W, WORLD_H, GAP, GATES = S.W, S.H, S.WORLD_W, S.WORLD_H, S.GAP, S.GATES
local SAND, NIGHT, DEEP, AMBER, RED, GREEN = S.SAND, S.NIGHT, S.DEEP, S.AMBER, S.RED, S.GREEN
local gate_buoys, wrap = S.gate_buoys, S.wrap
return function(st, g)
    local w = g.physics { gravity = 0 }
    st.w = w
    st.boat = w:box { x = 420, y = 2000, w = 64, h = 24, angle = -0.7, damping = 1.6,
      angular_damping = 5, density = 2, restitution = 0.3 }
    for _, gt in ipairs(GATES) do
      local x1, y1, x2, y2 = gate_buoys(gt)
      w:ball { x = x1, y = y1, r = 13, kind = "static", restitution = 0.6 }
      w:ball { x = x2, y = y2, r = 13, kind = "static", restitution = 0.6 }
    end
    -- the quay walls
    w:box { x = WORLD_W / 2, y = -40, w = WORLD_W, h = 80, kind = "static" }
    w:box { x = WORLD_W / 2, y = WORLD_H + 40, w = WORLD_W, h = 80, kind = "static" }
    w:box { x = -40, y = WORLD_H / 2, w = 80, h = WORLD_H, kind = "static" }
    w:box { x = WORLD_W + 40, y = WORLD_H / 2, w = 80, h = WORLD_H, kind = "static" }
    st.next, st.auto, st.done = 1, true, nil
    st.cam_x, st.cam_y = 420 - W / 2, 2000 - H / 2
    st.wake, st.passed, st.side = {}, {}, nil
    st.x, st.y, st.a, st.speed = 420, 2000, -0.7, 0
end ]==] },
    { name = "game.step", order = 2, source = [==[
local S = shared
local W, H, WORLD_W, WORLD_H, GAP, GATES = S.W, S.H, S.WORLD_W, S.WORLD_H, S.GAP, S.GATES
local SAND, NIGHT, DEEP, AMBER, RED, GREEN = S.SAND, S.NIGHT, S.DEEP, S.AMBER, S.RED, S.GREEN
local gate_buoys, wrap = S.gate_buoys, S.wrap
return function(st, input, g)
    local w = st.w
    if #input.events > 0 then st.auto = false end
    local x, y, a, vx, vy = w:get(st.boat)
    local thrust, helm = false, 0
    if st.auto and not st.done then
      local gt = GATES[st.next]
      -- two marks: one behind the gate on its line, then one past it, so the boat goes through
      -- square rather than at it; a miss sends it back round to the first
      local ux, uy = math.cos(gt[3]), math.sin(gt[3])
      local side = (x - gt[1]) * ux + (y - gt[2]) * uy
      local off = -(x - gt[1]) * uy + (y - gt[2]) * ux
      local tx, ty
      if side < -60 and math.abs(off) > GAP * 0.3 then
        tx, ty = gt[1] - ux * 200, gt[2] - uy * 200
      elseif side >= 0 then
        tx, ty = gt[1] - ux * 260, gt[2] - uy * 260
      else
        tx, ty = gt[1] + ux * 160, gt[2] + uy * 160
      end
      local d = wrap(math.atan2(ty - y, tx - x) - a)
      helm = d > 0.08 and 1 or (d < -0.08 and -1 or 0)
      thrust = math.abs(d) < 1.1
    else
      thrust = input.held.up
      helm = (input.held.right and 1 or 0) - (input.held.left and 1 or 0)
    end
    if helm ~= 0 then w:set(st.boat, { spin = helm * 2.6 }) end
    if thrust then
      w:impulse(st.boat, math.cos(a) * 7, math.sin(a) * 7)
    end
    -- the water pushes a hull sideways far less than it lets it run ahead: kill most sideways slip
    local _
    _, _, _, vx, vy = w:get(st.boat)
    local fx, fy = math.cos(a), math.sin(a)
    local along = vx * fx + vy * fy
    local across = -vx * fy + vy * fx
    w:set(st.boat, { vx = fx * along - fy * across * 0.86, vy = fy * along + fx * across * 0.86 })
    w:step(g.dt)
    x, y, a, vx, vy = w:get(st.boat)
    st.x, st.y, st.a, st.speed = x, y, a, math.sqrt(vx * vx + vy * vy)
    st.thrust = thrust

    -- through the next gate: the side of its line changes, between its buoys
    if not st.done then
      local gt = GATES[st.next]
      local fx2, fy2 = math.cos(gt[3]), math.sin(gt[3])
      local side = (x - gt[1]) * fx2 + (y - gt[2]) * fy2
      local off = math.abs(-(x - gt[1]) * fy2 + (y - gt[2]) * fx2)
      if st.side and st.side < 0 and side >= 0 and off < GAP / 2 then
        st.passed[st.next] = g.t
        st.next = st.next + 1
        st.side = nil
        if st.next > #GATES then st.done = g.t end
      else
        st.side = side
      end
    end

    -- the wake: where the stern was, every few steps
    if g.n % 4 == 0 then
      table.insert(st.wake, 1, { x - math.cos(a) * 30, y - math.sin(a) * 30, a, g.t, st.speed })
      if #st.wake > 70 then st.wake[#st.wake] = nil end
    end

    -- the camera leads the boat by where it is going
    local tx, ty = x + vx * 0.45 - W / 2, y + vy * 0.45 - H / 2
    st.cam_x = st.cam_x + (tx - st.cam_x) * 0.06
    st.cam_y = st.cam_y + (ty - st.cam_y) * 0.06
    st.cam_x = math.max(-60, math.min(WORLD_W - W + 60, st.cam_x))
    st.cam_y = math.max(-60, math.min(WORLD_H - H + 60, st.cam_y))

end ]==] },
    { name = "harbour3d", order = 4, source = [==[
-- the course in Bevy, 100 px to the metre: x stays x, the 2D y runs into the screen as z
local S = shared
local M = 0.01
return function(t, st)
  if not st then return {} end
  local rows = {}
  local function add(r) r.parent = "harbour"; rows[#rows + 1] = r end
  -- the camera: a three-quarter view over the 2D game's own lead point, so it follows smoothly
  local lx, lz = (st.cam_x + S.W / 2) * M, (st.cam_y + S.H / 2) * M
  rows[#rows + 1] = { id = "harbour", cam_x = lx - 1.2, cam_y = 3.6, cam_z = lz + 6.2, look_x = lx, look_y = 0.2, look_z = lz - 2.5 }

  -- the quay walls round the basin, and the sodium lamps along the north quay
  local WW, WH = S.WORLD_W * M, S.WORLD_H * M
  add { id = "quayN", shape = "box", pos = { WW / 2, 0.3, -0.4 }, size = { WW + 1.6, 0.9, 0.8 }, color = "#3c3833", roughness = 0.95 }
  add { id = "quayS", shape = "box", pos = { WW / 2, 0.3, WH + 0.4 }, size = { WW + 1.6, 0.9, 0.8 }, color = "#3c3833", roughness = 0.95 }
  add { id = "quayW", shape = "box", pos = { -0.4, 0.3, WH / 2 }, size = { 0.8, 0.9, WH }, color = "#3c3833", roughness = 0.95 }
  add { id = "quayE", shape = "box", pos = { WW + 0.4, 0.3, WH / 2 }, size = { 0.8, 0.9, WH }, color = "#3c3833", roughness = 0.95 }
  for i = 0, 7 do
    local x = 0.6 + i * 4.4
    add { id = "lamppost" .. i, shape = "cylinder", pos = { x, 1.3, -0.5 }, size = { 0.06, 1.4, 0.06 }, color = "#1d2125" }
    add { id = "lamphead" .. i, shape = "sphere", pos = { x, 2.05, -0.5 }, scale = 0.16, color = "#ffcf8a",
      emissive = "#ffb35c", emissive_strength = 12 }
    add { id = "lamplight" .. i, light = "point", pos = { x, 1.9, -0.2 }, color = "#ffb35c", intensity = 90000, range = 7 }
  end

  -- the gates: a can buoy each side, Fl R 4s to port and Fl G 4s to starboard; the next one is marked
  for gi, gt in ipairs(S.GATES) do
    local x1, y1, x2, y2 = S.gate_buoys(gt)
    local flash = ((t + gi * 0.37) % 4) < 0.5
    local done, nextg = st.passed[gi], gi == st.next
    for k, b in ipairs({ { x1, y1, "#c0392b", "#ff4d3d" }, { x2, y2, "#1f8a50", "#3dff8a" } }) do
      local bx, bz = b[1] * M, b[2] * M
      local bob = 0.05 * math.sin(t * 2 + gi + k)
      local id = ("g%d%s"):format(gi, k == 1 and "p" or "s")
      add { id = id .. "body", shape = "cylinder", pos = { bx, 0.22 + bob, bz }, size = { 0.3, 0.5, 0.3 },
        color = done and "#3a4248" or b[3], roughness = 0.5 }
      add { id = id .. "top", shape = "cone", pos = { bx, 0.6 + bob, bz }, size = { 0.18, 0.24, 0.18 }, color = "#22262a" }
      add { id = id .. "lamp", shape = "sphere", pos = { bx, 0.78 + bob, bz }, scale = 0.08, color = b[4],
        emissive = b[4], emissive_strength = (flash and not done) and 16 or 0.3 }
      if flash and not done then
        add { id = id .. "glow", light = "point", pos = { bx, 0.9 + bob, bz }, color = b[4], intensity = 40000, range = 4 }
      end
    end
    if nextg then -- a line of floats across the gate, breathing
      for f = 1, 7 do
        local u = f / 8
        add { id = "float" .. f, shape = "sphere", pos = { (x1 + (x2 - x1) * u) * M, 0.04, (y1 + (y2 - y1) * u) * M },
          scale = 0.05, color = "#f2a541", emissive = "#f2a541", emissive_strength = 3 + 3 * math.sin(t * 4 + f) }
      end
    end
  end

  -- the launch: hull, bow, wheelhouse and its navigation lights, heeling into the turn
  local bx, bz, a = st.x * M, st.y * M, st.a
  local yaw = -a
  local ca, sa = math.cos(a), math.sin(a)
  local function at(fx, fz, h) return { bx + fx * ca - fz * sa, h, bz + fx * sa + fz * ca } end
  local heel = math.max(-0.2, math.min(0.2, (st.speed or 0) * 0.0004 * ((st.thrust and 1) or 0.5)))
  add { id = "hull", shape = "box", pos = at(-0.05, 0, 0.08), size = { 0.5, 0.16, 0.24 }, yaw = yaw, roll = heel, color = "#e9e1cf", roughness = 0.5 }
  add { id = "bow", shape = "box", pos = at(0.22, 0, 0.08), size = { 0.17, 0.16, 0.17 }, yaw = yaw + 0.785, color = "#e9e1cf", roughness = 0.5 }
  add { id = "cabin", shape = "box", pos = at(-0.08, 0, 0.24), size = { 0.2, 0.14, 0.17 }, yaw = yaw, color = "#8d9aa1", roughness = 0.4 }
  add { id = "port", shape = "sphere", pos = at(0.02, -0.13, 0.2), scale = 0.03, color = "#ff4d3d", emissive = "#ff4d3d", emissive_strength = 12 }
  add { id = "stbd", shape = "sphere", pos = at(0.02, 0.13, 0.2), scale = 0.03, color = "#3dff8a", emissive = "#3dff8a", emissive_strength = 12 }
  add { id = "mast", shape = "sphere", pos = at(-0.08, 0, 0.4), scale = 0.03, color = "#ffffff", emissive = "#ffffff", emissive_strength = 14 }
  add { id = "boatlight", light = "point", pos = at(0.3, 0, 0.5), color = "#fff1d6", intensity = 6000, range = 2 }

  -- the wake: a V of foam spreading and sinking behind the stern
  for i, p in ipairs(st.wake) do
    local age = t - p[4]
    local fade = math.max(0, 1 - age / 2.6) * math.min(1, p[5] / 120)
    if fade > 0.05 then
      local nx, nz = -math.sin(p[3]), math.cos(p[3])
      local spread = 0.06 + age * 0.26
      for side = -1, 1, 2 do
        add { id = ("wake%d%s"):format(i, side < 0 and "l" or "r"), shape = "cylinder",
          pos = { p[1] * M + nx * spread * side, 0.012, p[2] * M + nz * spread * side },
          size = { 0.03 + age * 0.05, 0.008, 0.03 + age * 0.05 }, color = "#cfe3ea",
          emissive = "#cfe3ea", emissive_strength = 0.35 * fade, roughness = 0.9 }
      end
    end
  end
  return rows
end ]==] },
    { name = "hud", order = 3, source = [==[
local S = shared
return function(t, st)
  local rows = {
    { id = "gate", text = string.format("%d/%d", math.min(st.next, #S.GATES), #S.GATES) },
    { id = "time", text = S.clock(st.done or t) },
    { id = "knots", text = string.format("%.1f", st.speed / 32) },
    { id = "mode", text = st.auto and "AUTOPILOT" or "HELM" },
  }
  if st.done then
    local k = math.min(1, (t - st.done) / 0.8)
    rows[#rows + 1] = { id = "done", text = S.clock(st.done), opacity = k }
    rows[#rows + 1] = { id = "done2", opacity = k }
    rows[#rows + 1] = { id = "doneband", opacity = math.min(1, k * 2) }
  end
  return rows
end ]==] },
  },
}
