-- Visualize Value style explainer: black field, thin white lines, tiny captions.
-- One idea per beat. Rendered through moonsplice-scene (MOONSPLICE_SCENE=1).
local e = require("moonsplice")

local W, H = 1080, 1080
local INK = { 1, 1, 1, 1 }
local DIM = "#8a8f98"
local LW = 3

local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 else return x end end
local function ease(x) x = clamp01(x); return x < 0.5 and 2 * x * x or 1 - (-2 * x + 2) ^ 2 / 2 end
local function draw_on(v, t, t0, dur) return ease((t - t0) / dur) end

return e.comp {
  width = W, height = H, duration = 20, fps = 30, background = "#000000",

  scene = function(s)
    -- persistent frame corner marks, VV-style plate
    s:vector { x = 0, y = 0, w = W, h = H, draw = function(v, t)
      local m, l = 60, 26
      for _, c in ipairs({ { m, m, 1, 1 }, { W - m, m, -1, 1 }, { m, H - m, 1, -1 }, { W - m, H - m, -1, -1 } }) do
        v:move(c[1], c[2] + c[4] * l); v:line(c[1], c[2]); v:line(c[1] + c[3] * l, c[2]); v:stroke(2, { 1, 1, 1, 0.35 })
      end
    end }

    -- ---- beat 1 (0–4.5s): five engines → one ------------------------------
    local b1 = s:vector { x = 0, y = 0, w = W, h = H, opacity = 1, draw = function(v, t)
      local p = draw_on(v, t, 0.3, 1.2)
      local cx, cy = 540, 500
      local merge = draw_on(v, t, 2.0, 1.4)
      for i = 0, 4 do
        local ang = -math.pi / 2 + (i - 2) * 0.55
        local x0, y0 = cx + math.cos(ang) * 300, cy + math.sin(ang) * 300 + 40
        local x1, y1 = cx, cy
        local x, y = x0 + (x1 - x0) * merge, y0 + (y1 - y0) * merge
        local size = 60 * (1 - merge * 0.6)
        -- box
        v:move(x - size, y - size * 0.7); v:line(x + size, y - size * 0.7); v:line(x + size, y + size * 0.7); v:line(x - size, y + size * 0.7)
        v:line(x - size, y - size * 0.7); v:stroke(LW, { 1, 1, 1, p * (1 - merge) })
        -- spoke to center, drawn on
        local sx, sy = x + (cx - x) * p, y + (cy - y) * p
        v:move(x, y); v:line(sx, sy); v:stroke(2, { 1, 1, 1, 0.5 * p * (1 - merge) })
      end
      -- the one circle grows in as they merge
      local r = 8 + 110 * merge
      local seg = 48
      for k = 0, seg do
        local a = k / seg * math.pi * 2
        local px, py = cx + math.cos(a) * r, cy + math.sin(a) * r
        if k == 0 then v:move(px, py) else v:line(px, py) end
      end
      v:stroke(LW, { 1, 1, 1, merge })
    end }
    local c1 = s:text { x = 540, y = 760, text = "five engines. one rasterizer.", size = 30, anchor = "center", color = DIM, opacity = 0, tracking = 2 }

    -- ---- beat 2 (4.5–9s): seek, not playback --------------------------------
    local b2 = s:vector { x = 0, y = 0, w = W, h = H, opacity = 0, draw = function(v, t)
      local p = draw_on(v, t, 4.8, 1.0)
      local x0, x1, y = 180, 900, 520
      v:move(x0, y); v:line(x0 + (x1 - x0) * p, y); v:stroke(LW, INK)
      for i = 0, 8 do
        local x = x0 + (x1 - x0) * i / 8
        if x <= x0 + (x1 - x0) * p then v:move(x, y - 14); v:line(x, y + 14); v:stroke(2, { 1, 1, 1, 0.6 }) end
      end
      -- the playhead jumps: any frame, any order
      local jumps = { 0.15, 0.82, 0.4, 0.95, 0.05, 0.6 }
      local j = math.floor((t - 5.8) / 0.45) + 1
      if t >= 5.8 and j >= 1 then
        local k = jumps[math.min(j, #jumps)]
        local x = x0 + (x1 - x0) * k
        local seg = 32
        for q = 0, seg do
          local a = q / seg * math.pi * 2
          local px, py = x + math.cos(a) * 16, y + math.sin(a) * 16
          if q == 0 then v:move(px, py) else v:line(px, py) end
        end
        v:fill(INK)
        v:move(x, y - 60); v:line(x, y - 24); v:stroke(2, INK)
      end
    end }
    local c2 = s:text { x = 540, y = 760, text = "seek, not playback. any frame, any order.", size = 30, anchor = "center", color = DIM, opacity = 0, tracking = 2 }

    -- ---- beat 3 (9–13.5s): text is a shape now --------------------------------
    local w3 = s:text { x = 540, y = 470, text = "SHAPE", size = 150, anchor = "center", color = "#ffffff", opacity = 0, tracking = 0 }
    local b3 = s:vector { x = 0, y = 0, w = W, h = H, opacity = 0, draw = function(v, t)
      local p = draw_on(v, t, 10.6, 1.2)
      v:move(220, 590); v:line(220 + 640 * p, 590); v:stroke(LW, INK)
    end }
    local c3 = s:text { x = 540, y = 760, text = "type is a path. tracking is a tween.", size = 30, anchor = "center", color = DIM, opacity = 0, tracking = 2 }

    -- ---- beat 4 (13.5–17.5s): every property, a curve ---------------------------
    local b4 = s:vector { x = 0, y = 0, w = W, h = H, opacity = 0, draw = function(v, t)
      local p = draw_on(v, t, 13.8, 1.6)
      local x0, y0, x1, y1 = 200, 700, 880, 300
      -- axes
      v:move(x0, y1 - 40); v:line(x0, y0); v:line(x1 + 40, y0); v:stroke(2, { 1, 1, 1, 0.45 })
      -- ease curve drawn on (cubic in-out, sampled)
      local n = math.floor(80 * p)
      for k = 0, n do
        local u = k / 80
        local ev = ease(u)
        local px, py = x0 + (x1 - x0) * u, y0 - (y0 - y1) * ev
        if k == 0 then v:move(px, py) else v:line(px, py) end
      end
      if n > 0 then v:stroke(LW, INK) end
      -- the value dot riding the curve
      if p >= 1 then
        local u = clamp01((t - 15.5) / 1.4)
        local px, py = x0 + (x1 - x0) * u, y0 - (y0 - y1) * ease(u)
        local seg = 32
        for q = 0, seg do
          local a = q / seg * math.pi * 2
          local qx, qy = px + math.cos(a) * 12, py + math.sin(a) * 12
          if q == 0 then v:move(qx, qy) else v:line(qx, qy) end
        end
        v:fill(INK)
      end
    end }
    local c4 = s:text { x = 540, y = 760, text = "every property is a curve you can seek.", size = 30, anchor = "center", color = DIM, opacity = 0, tracking = 2 }

    -- ---- end card (17.5–20s) -----------------------------------------------------
    local logo = s:text { x = 540, y = 500, text = "moonsplice", size = 96, anchor = "center", color = "#ffffff", opacity = 0, tracking = 6 }
    local tag = s:text { x = 540, y = 600, text = "programmatic video from lua", size = 26, anchor = "center", color = DIM, opacity = 0, tracking = 3 }

    s:script(function(t)
      -- beat 1
      t:wait(0.6)
      t:tween(c1, 0.6, { opacity = 1 }, "sineOut")
      t:wait(2.9)
      t:parallel(
        function() t:tween(b1, 0.4, { opacity = 0 }, "sineIn") end,
        function() t:tween(c1, 0.4, { opacity = 0 }, "sineIn") end)
      -- beat 2 (cursor ≈ 4.5)
      t:parallel(
        function() t:tween(b2, 0.3, { opacity = 1 }, "sineOut") end,
        function() t:wait(0.4); t:tween(c2, 0.6, { opacity = 1 }, "sineOut") end)
      t:wait(3.6)
      t:parallel(
        function() t:tween(b2, 0.4, { opacity = 0 }, "sineIn") end,
        function() t:tween(c2, 0.4, { opacity = 0 }, "sineIn") end)
      -- beat 3 (cursor ≈ 9.2)
      t:parallel(
        function() t:tween(w3, 0.5, { opacity = 1 }, "sineOut"); t:tween(w3, 1.8, { tracking = 34 }, "cubicInOut") end,
        function() t:wait(0.2); t:tween(b3, 0.3, { opacity = 1 }, "sineOut") end,
        function() t:wait(1.0); t:tween(c3, 0.6, { opacity = 1 }, "sineOut") end)
      t:wait(1.5)
      t:parallel(
        function() t:tween(w3, 0.4, { opacity = 0 }, "sineIn") end,
        function() t:tween(b3, 0.4, { opacity = 0 }, "sineIn") end,
        function() t:tween(c3, 0.4, { opacity = 0 }, "sineIn") end)
      -- beat 4 (cursor ≈ 13.7)
      t:parallel(
        function() t:tween(b4, 0.3, { opacity = 1 }, "sineOut") end,
        function() t:wait(1.2); t:tween(c4, 0.6, { opacity = 1 }, "sineOut") end)
      t:wait(3.1)
      t:parallel(
        function() t:tween(b4, 0.4, { opacity = 0 }, "sineIn") end,
        function() t:tween(c4, 0.4, { opacity = 0 }, "sineIn") end)
      -- end card (cursor ≈ 17.7)
      t:parallel(
        function() t:tween(logo, 0.7, { opacity = 1, tracking = 14 }, "sineOut") end,
        function() t:wait(0.3); t:tween(tag, 0.6, { opacity = 1 }, "sineOut") end)
    end)
  end,
}
