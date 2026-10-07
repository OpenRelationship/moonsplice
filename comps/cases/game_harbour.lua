-- Harbour Run in rows (.robot/docs/rows.robot): a game, and with no input log a film of itself
-- (.robot/docs/canon.robot, amendment 2026-10-06). The fold is two systems, game.init and game.step; the HUD is
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
    { id = "sea", kind = "vector", x = 0, y = 0, w = 1280, h = 720, draw = { fn = [==[
local S = shared
local W, H, WORLD_W, WORLD_H, GAP, GATES = S.W, S.H, S.WORLD_W, S.WORLD_H, S.GAP, S.GATES
local SAND, NIGHT, DEEP, AMBER, RED, GREEN = S.SAND, S.NIGHT, S.DEEP, S.AMBER, S.RED, S.GREEN
local gate_buoys, wrap = S.gate_buoys, S.wrap
return function(v, t)
        local st = q.state
        if not st then return end
        local cx, cy = st.cam_x, st.cam_y
        v:gradient(0, 0, W, H, 0, 0, 0, H, NIGHT, DEEP)

        -- swell: short curved strokes on a world grid, each breathing on its own phase
        local step = 84
        local gx0, gy0 = math.floor(cx / step) * step, math.floor(cy / step) * step
        for gy = gy0, gy0 + H + step, step do
          for gx = gx0, gx0 + W + step, step do
            local ph = math.sin(gx * 0.013 + gy * 0.021) * 6
            local a = 0.05 + 0.06 * (0.5 + 0.5 * math.sin(t * 0.9 + ph))
            local sx, sy = gx - cx + math.sin(gy * 0.05) * 20, gy - cy + math.sin(t * 0.7 + ph) * 4
            v:move(sx - 16, sy); v:curve(sx - 6, sy - 4, sx + 6, sy - 4, sx + 16, sy)
            v:stroke(1.4, { 0.62, 0.78, 0.86, a })
          end
        end

        -- the quay, and its sodium lamps on the water
        for i = 0, 16 do
          local lx = i * 220 + 60 - cx
          if lx > -200 and lx < W + 200 then
            v:radial(lx, -cy + 26, 170, { 0.95, 0.65, 0.25, 0.20 }, { 0.95, 0.65, 0.25, 0 })
            v:circle(lx, -cy + 18, 4, AMBER)
            for k = 1, 9 do -- the light broken on the swell below each lamp
              local ry = -cy + 40 + k * 22
              local half = 26 - k * 2 + math.sin(t * 2 + k + i) * 5
              v:rect(lx - half, ry, half * 2, 2, { 0.95, 0.65, 0.25, 0.22 - k * 0.02 }, 1)
            end
          end
        end
        v:rect(-cx - 60, -cy - 80, WORLD_W + 120, 80, "#151b22", 0)

        -- the wake: a V that spreads and fades behind the stern
        for i, p in ipairs(st.wake) do
          local age = t - p[4]
          local spread = 6 + age * 26
          local fade = math.max(0, 0.34 - age * 0.12) * math.min(1, p[5] / 120)
          if fade > 0.01 then
            local nx, ny = -math.sin(p[3]), math.cos(p[3])
            local x0, y0 = p[1] - cx, p[2] - cy
            v:circle(x0 + nx * spread, y0 + ny * spread, 2.2 + age, { 0.85, 0.93, 0.96, fade })
            v:circle(x0 - nx * spread, y0 - ny * spread, 2.2 + age, { 0.85, 0.93, 0.96, fade })
            if i % 2 == 0 then v:circle(x0, y0, 3 + age * 2, { 0.85, 0.93, 0.96, fade * 0.5 }) end
          end
        end

        -- the gates: port red to the left of the course, starboard green to the right
        for gi, gt in ipairs(GATES) do
          local x1, y1, x2, y2 = gate_buoys(gt)
          local flash = ((t + gi * 0.37) % 4) < 0.5
          local done = st.passed[gi]
          local nextg = gi == st.next
          for k, b in ipairs({ { x1, y1, RED }, { x2, y2, GREEN } }) do
            local bx, by = b[1] - cx, b[2] - cy
            if bx > -120 and bx < W + 120 and by > -120 and by < H + 120 then
              local c = color(b[3])
              if flash then v:radial(bx, by, 90, { c[1], c[2], c[3], 0.45 }, { c[1], c[2], c[3], 0 }) end
              v:circle(bx, by, 13, done and "#2a3640" or b[3])
              v:circle(bx, by, 5, flash and "#ffffff" or { c[1], c[2], c[3], 1 })
            end
            local _ = k
          end
          if done then -- a ring that spreads from where the boat went through, once
            local age = t - done
            if age < 1.6 then
              v:move(gt[1] - cx + 60 + age * 160, gt[2] - cy)
              local r = 60 + age * 160
              for k = 1, 48 do
                local an = k / 48 * math.pi * 2
                v:line(gt[1] - cx + math.cos(an) * r, gt[2] - cy + math.sin(an) * r)
              end
              v:stroke(2, { 0.91, 0.88, 0.81, 0.6 * (1 - age / 1.6) })
            end
          elseif nextg then -- the line to aim through, dashed
            local dx, dy = x2 - x1, y2 - y1
            for k = 0, 9 do
              local a0, a1 = (k + 0.25) / 10, (k + 0.75) / 10
              v:move(x1 + dx * a0 - cx, y1 + dy * a0 - cy); v:line(x1 + dx * a1 - cx, y1 + dy * a1 - cy)
              v:stroke(1.5, { 0.91, 0.88, 0.81, 0.35 + 0.25 * math.sin(t * 4) })
            end
          end
        end

        -- the launch: hull, wheelhouse, and its navigation lights
        local bx, by, a = st.x - cx, st.y - cy, st.a
        local ca, sa = math.cos(a), math.sin(a)
        local function at(px, py) return bx + px * ca - py * sa, by + px * sa + py * ca end
        local function poly(pts, c)
          local x0, y0 = at(pts[1], pts[2]); v:move(x0, y0)
          for i = 3, #pts, 2 do local px, py = at(pts[i], pts[i + 1]); v:line(px, py) end
          v:fill(c)
        end
        v:radial(bx, by, 60, { 0, 0, 0, 0.35 }, { 0, 0, 0, 0 })
        poly({ -32, -12, 18, -12, 34, 0, 18, 12, -32, 12 }, SAND)
        poly({ -18, -7, 4, -7, 4, 7, -18, 7 }, "#9aa7ad")
        local px, py = at(4, -12); local sx, sy = at(4, 12); local mx, my = at(-31, 0)
        v:circle(px, py, 3, RED); v:circle(sx, sy, 3, GREEN); v:circle(mx, my, 2.5, "#ffffff")
        if st.thrust then
          local ex, ey = at(-36, 0)
          v:radial(ex, ey, 18, { 0.85, 0.93, 0.96, 0.5 }, { 0.85, 0.93, 0.96, 0 })
        end

end ]==] } },
    -- the almanac: set like a tide table, tabular figures, no boxes
    { id = "name", kind = "text", x = 40, y = 34, text = "HARBOUR RUN", size = 15, color = "#e9e1cf", ls = 3 },
    { id = "gate_label", kind = "text", x = 40, y = 60, text = "GATE", size = 15, color = "#7f97a3", ls = 2 },
    { id = "time_label", kind = "text", x = 160, y = 60, text = "ELAPSED", size = 15, color = "#7f97a3", ls = 2 },
    { id = "knots_label", kind = "text", x = 300, y = 60, text = "KNOTS", size = 15, color = "#7f97a3", ls = 2 },
    { id = "gate", kind = "text", x = 40, y = 80, text = "1/8", size = 30, color = "#e9e1cf" },
    { id = "time", kind = "text", x = 160, y = 80, text = "00:00.0", size = 30, color = "#e9e1cf" },
    { id = "knots", kind = "text", x = 300, y = 80, text = "0.0", size = 30, color = "#e9e1cf" },
    { id = "mode", kind = "text", x = 1110, y = 34, text = "AUTOPILOT", size = 15, color = "#f2a541", ls = 3 },
    { id = "done", kind = "text", x = 640, y = 320, text = "", size = 64, color = "#e9e1cf", anchor = "center", opacity = 0 },
    { id = "done2", kind = "text", x = 640, y = 380, text = "MOORED", size = 15, color = "#f2a541", ls = 4, anchor = "center", opacity = 0 },
    { id = "legend", kind = "text", x = 40, y = 674, text = "Fl R 4s   Fl G 4s      UP thrust   LEFT RIGHT helm", size = 14, color = "#4f6672", ls = 1 },
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
  end
  return rows
end ]==] },
  },
}
