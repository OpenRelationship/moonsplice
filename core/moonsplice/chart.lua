-- d3-shape port: arrays → draw commands. Reveal clips path length / bar height
-- / pie sweep. mix lerps data→data1 (Vizzu). Host-free; painters stroke cmds.
local color = require("moonsplice.color")
local rough = require("moonsplice.rough")
local okhsl = require("moonsplice.okhsl")

local M = {}

local function clamp(x, a, b) return math.max(a, math.min(b, x)) end

function M.lerp_data(a, b, k)
  if not b then return a end
  k = clamp(k or 0, 0, 1)
  local n = math.max(#a, #b)
  local out = {}
  for i = 1, n do
    local va, vb = a[i] or a[#a], b[i] or b[#b]
    if type(va) == "table" or type(vb) == "table" then
      local ta = type(va) == "table" and va or { va }
      local tb = type(vb) == "table" and vb or { vb }
      out[i] = M.lerp_data(ta, tb, k)
    else
      va, vb = va or 0, vb or 0
      out[i] = va + (vb - va) * k
    end
  end
  return out
end

local function nums(data)
  local xs, ys = {}, {}
  for i, v in ipairs(data) do
    if type(v) == "table" then
      xs[i] = v.x or v[1] or i
      ys[i] = v.y or v[2] or 0
    else
      xs[i] = i
      ys[i] = v
    end
  end
  return xs, ys
end

local function palette_for(spec, n)
  if spec.colors and #spec.colors > 0 then
    local out = {}
    for i = 1, n do
      local c = spec.colors[((i - 1) % #spec.colors) + 1]
      out[i] = type(c) == "table" and c or color.parse(c)
    end
    return out
  end
  local hue = spec.hue
  if not hue and spec.color then
    local rgb = type(spec.color) == "table" and spec.color or color.parse(spec.color)
    hue = okhsl.rgb_to_okhsl(rgb)[1]
  end
  return color.palette {
    h = hue or 210, n = n, s = spec.sat or 72, l0 = 42, l1 = 74,
  }
end

local function clip_poly(pts, reveal)
  if reveal >= 1 then return pts end
  if reveal <= 0 or #pts < 4 then return {} end
  local total, acc = 0, { 0 }
  for i = 3, #pts, 2 do
    local dx, dy = pts[i] - pts[i - 2], pts[i + 1] - pts[i - 1]
    total = total + math.sqrt(dx * dx + dy * dy)
    acc[#acc + 1] = total
  end
  if total < 1e-6 then return pts end
  local target = total * reveal
  local out = { pts[1], pts[2] }
  for i = 2, #acc do
    if acc[i] >= target then
      local span = acc[i] - acc[i - 1]
      local f = span > 0 and (target - acc[i - 1]) / span or 1
      local i0 = (i - 1) * 2 - 1
      out[#out + 1] = pts[i0] + (pts[i0 + 2] - pts[i0]) * f
      out[#out + 1] = pts[i0 + 1] + (pts[i0 + 3] - pts[i0 + 1]) * f
      break
    else
      out[#out + 1] = pts[i * 2 - 1]
      out[#out + 1] = pts[i * 2]
    end
  end
  return out
end

local function stroke_pts(pts, spec, seed)
  if spec.stroke ~= "rough" then return { pts } end
  return rough.strokes(pts, {
    seed = seed or spec.seed or 1,
    roughness = spec.roughness or 1.15,
    bowing = spec.bowing,
  })
end

local function add_strokes(cmds, pts, spec, col, width, seed)
  for _, p in ipairs(stroke_pts(pts, spec, seed)) do
    if #p >= 4 then
      cmds[#cmds + 1] = { kind = "polyline", pts = p, color = col, width = width or 2 }
    end
  end
end

-- d3-shape primitives (flat point arrays).
function M.line(xs, ys, x0, y0, w, h)
  local xmin, xmax, ymin, ymax = xs[1], xs[1], ys[1], ys[1]
  for i = 1, #ys do
    if xs[i] < xmin then xmin = xs[i] end
    if xs[i] > xmax then xmax = xs[i] end
    if ys[i] < ymin then ymin = ys[i] end
    if ys[i] > ymax then ymax = ys[i] end
  end
  if xmax <= xmin then xmax = xmin + 1 end
  if ymax <= ymin then ymax = ymin + 1 end
  local pts = {}
  for i = 1, #ys do
    pts[#pts + 1] = x0 + (xs[i] - xmin) / (xmax - xmin) * w
    pts[#pts + 1] = y0 + h - (ys[i] - ymin) / (ymax - ymin) * h
  end
  return pts
end

function M.area(xs, ys, x0, y0, w, h)
  local line = M.line(xs, ys, x0, y0, w, h)
  if #line < 4 then return line end
  local pts = {}
  for i = 1, #line do pts[i] = line[i] end
  pts[#pts + 1] = line[#line - 1]
  pts[#pts + 1] = y0 + h
  pts[#pts + 1] = line[1]
  pts[#pts + 1] = y0 + h
  pts[#pts + 1] = line[1]
  pts[#pts + 1] = line[2]
  return pts, line
end

function M.arc(cx, cy, r, a0, a1, inner)
  local n = math.max(8, math.floor(math.abs(a1 - a0) / 0.08))
  local pts = {}
  for i = 0, n do
    local a = a0 + (a1 - a0) * (i / n)
    pts[#pts + 1] = cx + math.cos(a) * r
    pts[#pts + 1] = cy + math.sin(a) * r
  end
  if inner and inner > 0 then
    for i = n, 0, -1 do
      local a = a0 + (a1 - a0) * (i / n)
      pts[#pts + 1] = cx + math.cos(a) * inner
      pts[#pts + 1] = cy + math.sin(a) * inner
    end
    pts[#pts + 1] = pts[1]
    pts[#pts + 1] = pts[2]
  end
  return pts
end

function M.commands(spec, reveal)
  reveal = clamp(reveal or 1, 0, 1)
  local typ = spec.type or spec.kind or "bar"
  local w, h = spec.w or 400, spec.h or 240
  local mix = clamp(spec.mix or 0, 0, 1)
  local data = spec.data or {}
  if spec.data1 and mix > 0 then data = M.lerp_data(data, spec.data1, mix) end
  local cmds = {}
  if #data == 0 then return cmds end
  local colors = palette_for(spec, math.max(#data, 3))
  local fillc = spec.color or colors[1]

  if typ == "bar" then
    local xs, ys = nums(data)
    local n = #ys
    local maxv = 0
    for i = 1, n do if ys[i] > maxv then maxv = ys[i] end end
    if maxv <= 0 then maxv = 1 end
    local gap = w * 0.08 / math.max(n, 1)
    local bw = (w - gap * (n + 1)) / n
    for i = 1, n do
      local start = (i - 1) / n
      local lr = clamp((reveal - start) * n, 0, 1)
      local bh = (ys[i] / maxv) * h * lr
      local x = gap + (i - 1) * (bw + gap)
      local y = h - bh
      if bh > 0.5 then
        cmds[#cmds + 1] = { kind = "rect", x = x, y = y, w = bw, h = bh, color = colors[i] }
        if spec.stroke == "rough" then
          for _, pts in ipairs(rough.rect(x, y, bw, bh, {
            seed = (spec.seed or 1) + i * 13, roughness = spec.roughness or 1.15,
          })) do
            cmds[#cmds + 1] = { kind = "polyline", pts = pts, color = colors[i], width = 1.5 }
          end
        end
      end
    end

  elseif typ == "stack" then
    local n = #data
    local layers = type(data[1]) == "table" and #data[1] or 1
    local totals = {}
    local maxv = 0
    for i = 1, n do
      local row = type(data[i]) == "table" and data[i] or { data[i] }
      local s = 0
      for L = 1, layers do s = s + (row[L] or 0) end
      totals[i] = s
      if s > maxv then maxv = s end
    end
    if maxv <= 0 then maxv = 1 end
    local pal = palette_for(spec, layers)
    local gap = w * 0.08 / math.max(n, 1)
    local bw = (w - gap * (n + 1)) / n
    for i = 1, n do
      local start = (i - 1) / n
      local lr = clamp((reveal - start) * n, 0, 1)
      local row = type(data[i]) == "table" and data[i] or { data[i] }
      local y = h
      local x = gap + (i - 1) * (bw + gap)
      for L = 1, layers do
        local bh = ((row[L] or 0) / maxv) * h * lr
        y = y - bh
        if bh > 0.5 then
          cmds[#cmds + 1] = { kind = "rect", x = x, y = y, w = bw, h = bh, color = pal[L] }
        end
      end
    end

  elseif typ == "line" or typ == "area" then
    local xs, ys = nums(data)
    local area_pts, line_pts = M.area(xs, ys, 0, 0, w, h)
    line_pts = clip_poly(line_pts, reveal)
    if typ == "area" and #line_pts >= 4 then
      local fill = {}
      for i = 1, #line_pts do fill[i] = line_pts[i] end
      fill[#fill + 1] = line_pts[#line_pts - 1]
      fill[#fill + 1] = h
      fill[#fill + 1] = line_pts[1]
      fill[#fill + 1] = h
      local fc = { fillc[1], fillc[2], fillc[3], (fillc[4] or 1) * 0.35 }
      cmds[#cmds + 1] = { kind = "polyline", pts = fill, color = fc, fill = true }
    end
    add_strokes(cmds, line_pts, spec, fillc, spec.width or 3, spec.seed)

  elseif typ == "pie" then
    local _, ys = nums(data)
    local sum = 0
    for i = 1, #ys do sum = sum + math.max(0, ys[i]) end
    if sum <= 0 then return cmds end
    local cx, cy = w / 2, h / 2
    local r = math.min(w, h) * 0.42
    local a = -math.pi / 2
    local remain = sum * reveal
    for i = 1, #ys do
      local slice = math.max(0, ys[i])
      local take = math.min(slice, remain)
      if take > 0.001 then
        local sweep = take / sum * math.pi * 2
        cmds[#cmds + 1] = {
          kind = "arc", x = cx, y = cy, r = r, a0 = a, a1 = a + sweep,
          color = colors[i], fill = true,
        }
        if spec.stroke == "rough" then
          add_strokes(cmds, M.arc(cx, cy, r, a, a + sweep), spec, colors[i], 1.6,
            (spec.seed or 1) + i * 17)
        end
        a = a + sweep
        remain = remain - take
      end
    end

  elseif typ == "arc" then
    local value = data.value or data[1] or 0
    local total = data.total or data[2] or 1
    local cx, cy = w / 2, h / 2
    local r = math.min(w, h) * 0.42
    local inner = r * (spec.inner or 0.62)
    local a0 = spec.start or -math.pi / 2
    local sweep = (value / total) * math.pi * 2 * reveal
    cmds[#cmds + 1] = {
      kind = "polyline", pts = M.arc(cx, cy, r, 0, math.pi * 2, inner),
      color = spec.track or { 0.15, 0.18, 0.24, 1 }, fill = true,
    }
    if sweep > 0.01 then
      cmds[#cmds + 1] = {
        kind = "polyline", pts = M.arc(cx, cy, r, a0, a0 + sweep, inner),
        color = fillc, fill = true,
      }
    end
  else
    error("moonsplice chart: unknown type " .. tostring(typ), 2)
  end
  return cmds
end

return M
