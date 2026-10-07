-- Draft-style ornament primitives: stars, compass, eggs, linkers.
-- Output closed polylines (flat x,y,...) for vello or love.graphics.
local rough = require("moonsplice.rough")

local O = {}

local function close(pts)
  if #pts >= 4 and (pts[1] ~= pts[#pts - 1] or pts[2] ~= pts[#pts]) then
    pts[#pts + 1] = pts[1]
    pts[#pts + 1] = pts[2]
  end
  return pts
end

function O.star(cx, cy, r, n, inner)
  n = n or 5
  inner = inner or 0.38
  local pts = {}
  for i = 0, n * 2 do
    local a = -math.pi / 2 + i * math.pi / n
    local rad = (i % 2 == 0) and r or r * inner
    pts[#pts + 1] = cx + math.cos(a) * rad
    pts[#pts + 1] = cy + math.sin(a) * rad
  end
  return close(pts)
end

function O.compass(cx, cy, r)
  local pts = {}
  -- outer ring
  local ring = {}
  for i = 0, 48 do
    local a = i / 48 * math.pi * 2
    ring[#ring + 1] = cx + math.cos(a) * r
    ring[#ring + 1] = cy + math.sin(a) * r
  end
  pts[#pts + 1] = close(ring)
  -- ticks
  for i = 0, 7 do
    local a = i * math.pi / 4 - math.pi / 2
    local inner = (i % 2 == 0) and r * 0.72 or r * 0.84
    pts[#pts + 1] = {
      cx + math.cos(a) * inner, cy + math.sin(a) * inner,
      cx + math.cos(a) * r * 0.96, cy + math.sin(a) * r * 0.96,
    }
  end
  -- north needle
  pts[#pts + 1] = {
    cx, cy + r * 0.12,
    cx - r * 0.12, cy,
    cx, cy - r * 0.62,
    cx + r * 0.12, cy,
    cx, cy + r * 0.12,
  }
  return pts -- list of polylines
end

function O.egg(cx, cy, rx, ry)
  ry = ry or rx * 1.28
  local pts = {}
  for i = 0, 40 do
    local t = i / 40 * math.pi * 2
    local k = 0.18 * math.cos(t) -- fatter at the bottom
    pts[#pts + 1] = cx + rx * (1 + k) * math.sin(t)
    pts[#pts + 1] = cy + ry * math.cos(t)
  end
  return close(pts)
end

-- Cubic S-curve between two points, plus optional end ticks (title bumper linker).
function O.linker(x0, y0, x1, y1, bow)
  bow = bow or math.min(80, math.abs(x1 - x0) * 0.35)
  local mx = (x0 + x1) / 2
  local c1x, c1y = x0 + bow, y0
  local c2x, c2y = x1 - bow, y1
  local pts = { x0, y0 }
  for i = 1, 24 do
    local t = i / 24
    local u = 1 - t
    pts[#pts + 1] = u * u * u * x0 + 3 * u * u * t * c1x + 3 * u * t * t * c2x + t * t * t * x1
    pts[#pts + 1] = u * u * u * y0 + 3 * u * u * t * c1y + 3 * u * t * t * c2y + t * t * t * y1
  end
  return pts
end

local function clip(pts, reveal)
  if not reveal or reveal >= 1 then return pts end
  if reveal <= 0 then return {} end
  local total = 0
  for i = 3, #pts, 2 do
    local dx, dy = pts[i] - pts[i - 2], pts[i + 1] - pts[i - 1]
    total = total + math.sqrt(dx * dx + dy * dy)
  end
  if total < 1e-6 then return pts end
  local target, acc = total * reveal, 0
  local out = { pts[1], pts[2] }
  for i = 3, #pts, 2 do
    local dx, dy = pts[i] - pts[i - 2], pts[i + 1] - pts[i - 1]
    local len = math.sqrt(dx * dx + dy * dy)
    if acc + len >= target then
      local f = (target - acc) / len
      out[#out + 1] = pts[i - 2] + dx * f
      out[#out + 1] = pts[i - 1] + dy * f
      break
    end
    out[#out + 1] = pts[i]
    out[#out + 1] = pts[i + 1]
    acc = acc + len
  end
  return out
end

function O.polylines(kind, spec, reveal)
  spec = spec or {}
  local w, h = spec.w or 160, spec.h or 160
  local cx, cy = w / 2, h / 2
  local r = spec.r or math.min(w, h) * 0.42
  local list
  if kind == "star" then
    list = { O.star(cx, cy, r, spec.n or 5, spec.inner) }
  elseif kind == "compass" then
    list = O.compass(cx, cy, r)
  elseif kind == "egg" then
    list = { O.egg(cx, cy, spec.rx or r * 0.72, spec.ry or r) }
  elseif kind == "linker" then
    list = { O.linker(spec.x0 or 8, spec.y0 or h / 2, spec.x1 or (w - 8), spec.y1 or h / 2, spec.bow) }
  else
    error("moonsplice ornament: unknown kind " .. tostring(kind), 2)
  end
  local out = {}
  for i, pts in ipairs(list) do
    local p = clip(pts, reveal)
    if spec.stroke == "rough" and #p >= 4 then
      local strokes = rough.strokes(p, {
        seed = (spec.seed or 1) + i * 11,
        roughness = spec.roughness or 1.1,
      })
      for _, s in ipairs(strokes) do out[#out + 1] = s end
    else
      out[#out + 1] = p
    end
  end
  return out
end

return O
