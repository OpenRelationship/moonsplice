-- Seeded sketchy polylines (Rough.js spirit). Same seed → same wobble,
-- so seek and shuffle-hash match. No math.random.
local R = {}

local function hash(seed, k)
  local s = math.sin(seed * 12.9898 + k * 78.233) * 43758.5453
  return s - math.floor(s)
end

local function flatten(pts)
  if type(pts[1]) == "table" then
    local out = {}
    for i = 1, #pts do
      out[#out + 1] = pts[i][1] or pts[i].x
      out[#out + 1] = pts[i][2] or pts[i].y
    end
    return out
  end
  return pts
end

-- Offset a polyline perpendicular to each segment. roughness is in pixels.
function R.polyline(pts, opts)
  opts = opts or {}
  pts = flatten(pts)
  local n = math.floor(#pts / 2)
  if n < 2 then return pts end
  local roughness = opts.roughness or 1.15
  local seed = opts.seed or 1
  local bowing = opts.bowing or 0.8
  local out = { pts[1], pts[2] }
  local k = 0
  for i = 1, n - 1 do
    local x0, y0 = pts[i * 2 - 1], pts[i * 2]
    local x1, y1 = pts[i * 2 + 1], pts[i * 2 + 2]
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 4 then
      out[#out + 1] = x1
      out[#out + 1] = y1
    else
      local nx, ny = -dy / len, dx / len
      local steps = math.max(2, math.floor(len / 10))
      for s = 1, steps do
        k = k + 1
        local t = s / steps
        local mid = t * (1 - t) * 4 -- bow peak at center
        local j = (hash(seed, k) - 0.5) * roughness * 2
        local b = (hash(seed, k + 91) - 0.5) * bowing * len * 0.04 * mid
        out[#out + 1] = x0 + dx * t + nx * (j + b)
        out[#out + 1] = y0 + dy * t + ny * (j + b)
      end
    end
  end
  return out
end

-- Two overlapping strokes, like Rough.js overlay. Seek-safe.
function R.strokes(pts, opts)
  opts = opts or {}
  local a = R.polyline(pts, opts)
  local b = R.polyline(pts, {
    roughness = (opts.roughness or 1.15) * 0.85,
    seed = (opts.seed or 1) + 19,
    bowing = opts.bowing,
  })
  return { a, b }
end

-- Rectangle outline as a closed polyline (for rough bar/frame strokes).
function R.rect(x, y, w, h, opts)
  local pts = { x, y, x + w, y, x + w, y + h, x, y + h, x, y }
  return R.strokes(pts, opts)
end

return R
