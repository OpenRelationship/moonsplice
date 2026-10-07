-- HSLuv (www.hsluv.org), vendored and localized from the MIT hsluv-lua
-- implementation by Alexei Boronine. Used for color tweens that hold chroma
-- instead of collapsing through muddy RGB midpoints.
--[[
Copyright (C) 2019 Alexei Boronine

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local hsluv = {}

hsluv.m = {
  { 3.240969941904521, -1.537383177570093, -0.498610760293 },
  { -0.96924363628087, 1.87596750150772, 0.041555057407175 },
  { 0.055630079696993, -0.20397695888897, 1.056971514242878 },
}
hsluv.minv = {
  { 0.41239079926595, 0.35758433938387, 0.18048078840183 },
  { 0.21263900587151, 0.71516867876775, 0.072192315360733 },
  { 0.019330818715591, 0.11919477979462, 0.95053215224966 },
}
hsluv.refY = 1.0
hsluv.refU = 0.19783000664283
hsluv.refV = 0.46831999493879
hsluv.kappa = 903.2962962
hsluv.epsilon = 0.0088564516

local function distance_line_from_origin(line)
  return math.abs(line.intercept) / math.sqrt((line.slope ^ 2) + 1)
end

local function length_of_ray_until_intersect(theta, line)
  return line.intercept / (math.sin(theta) - line.slope * math.cos(theta))
end

local function get_bounds(l)
  local result = {}
  local sub1 = ((l + 16) ^ 3) / 1560896
  local sub2 = sub1 > hsluv.epsilon and sub1 or (l / hsluv.kappa)
  for i = 1, 3 do
    local m1, m2, m3 = hsluv.m[i][1], hsluv.m[i][2], hsluv.m[i][3]
    for t = 0, 1 do
      local top1 = (284517 * m1 - 94839 * m3) * sub2
      local top2 = (838422 * m3 + 769860 * m2 + 731718 * m1) * l * sub2 - 769860 * t * l
      local bottom = (632260 * m3 - 126452 * m2) * sub2 + 126452 * t
      result[#result + 1] = { slope = top1 / bottom, intercept = top2 / bottom }
    end
  end
  return result
end

local function max_safe_chroma_for_lh(l, h)
  local hrad = h / 360 * math.pi * 2
  local bounds = get_bounds(l)
  local min = 1.7976931348623157e+308
  for i = 1, 6 do
    local length = length_of_ray_until_intersect(hrad, bounds[i])
    if length >= 0 then min = math.min(min, length) end
  end
  return min
end

local function dot_product(a, b)
  return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

local function from_linear(c)
  if c <= 0.0031308 then return 12.92 * c end
  return 1.055 * (c ^ 0.416666666666666685) - 0.055
end

local function to_linear(c)
  if c > 0.04045 then return ((c + 0.055) / 1.055) ^ 2.4 end
  return c / 12.92
end

local function xyz_to_rgb(tuple)
  return {
    from_linear(dot_product(hsluv.m[1], tuple)),
    from_linear(dot_product(hsluv.m[2], tuple)),
    from_linear(dot_product(hsluv.m[3], tuple)),
  }
end

local function rgb_to_xyz(tuple)
  local rgbl = { to_linear(tuple[1]), to_linear(tuple[2]), to_linear(tuple[3]) }
  return {
    dot_product(hsluv.minv[1], rgbl),
    dot_product(hsluv.minv[2], rgbl),
    dot_product(hsluv.minv[3], rgbl),
  }
end

local function y_to_l(Y)
  if Y <= hsluv.epsilon then return Y / hsluv.refY * hsluv.kappa end
  return 116 * ((Y / hsluv.refY) ^ 0.333333333333333315) - 16
end

local function l_to_y(L)
  if L <= 8 then return hsluv.refY * L / hsluv.kappa end
  return hsluv.refY * (((L + 16) / 116) ^ 3)
end

local function xyz_to_luv(tuple)
  local X, Y, Z = tuple[1], tuple[2], tuple[3]
  local divider = X + 15 * Y + 3 * Z
  local varU, varV = 4 * X, 9 * Y
  if divider ~= 0 then
    varU, varV = varU / divider, varV / divider
  else
    varU, varV = 0, 0
  end
  local L = y_to_l(Y)
  if L == 0 then return { 0, 0, 0 } end
  return { L, 13 * L * (varU - hsluv.refU), 13 * L * (varV - hsluv.refV) }
end

local function luv_to_xyz(tuple)
  local L, U, V = tuple[1], tuple[2], tuple[3]
  if L == 0 then return { 0, 0, 0 } end
  local varU = U / (13 * L) + hsluv.refU
  local varV = V / (13 * L) + hsluv.refV
  local Y = l_to_y(L)
  local X = -(9 * Y * varU) / (((varU - 4) * varV) - varU * varV)
  return { X, Y, (9 * Y - 15 * varV * Y - varV * X) / (3 * varV) }
end

local function luv_to_lch(tuple)
  local L, U, V = tuple[1], tuple[2], tuple[3]
  local C = math.sqrt(U * U + V * V)
  local H = 0
  if C >= 1e-8 then
    H = (math.atan2 or math.atan)(V, U) * 180.0 / math.pi
    if H < 0 then H = 360 + H end
  end
  return { L, C, H }
end

local function lch_to_luv(tuple)
  local L, C, Hrad = tuple[1], tuple[2], tuple[3] / 360.0 * 2 * math.pi
  return { L, math.cos(Hrad) * C, math.sin(Hrad) * C }
end

local function hsluv_to_lch(tuple)
  local H, S, L = tuple[1], tuple[2], tuple[3]
  if L > 99.9999999 then return { 100, 0, H } end
  if L < 0.00000001 then return { 0, 0, H } end
  return { L, max_safe_chroma_for_lh(L, H) / 100 * S, H }
end

local function lch_to_hsluv(tuple)
  local L, C, H = tuple[1], tuple[2], tuple[3]
  if L > 99.9999999 then return { H, 0, 100 } end
  if L < 0.00000001 then return { H, 0, 0 } end
  return { H, C / max_safe_chroma_for_lh(L, H) * 100, L }
end

function hsluv.rgb_to_hsluv(tuple)
  return lch_to_hsluv(luv_to_lch(xyz_to_luv(rgb_to_xyz(tuple))))
end

function hsluv.hsluv_to_rgb(tuple)
  return xyz_to_rgb(luv_to_xyz(lch_to_luv(hsluv_to_lch(tuple))))
end

-- silence unused local (kept as documentation of the chroma bound helper)
do local _ = distance_line_from_origin end

return hsluv
