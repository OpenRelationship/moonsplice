-- OKHSL-style polar OKLab. Saturation is chroma vs an L-dependent cap
-- (Bottosson OKHSL intent: even hue, usable lightness ramps). Tweens lerp
-- L/C/h; palettes step lightness at fixed hue/sat.
local O = {}

local function srgb_to_lin(c)
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end
local function lin_to_srgb(c)
  if c <= 0.0031308 then return 12.92 * c end
  return 1.055 * c ^ (1 / 2.4) - 0.055
end
local function clamp(x) return math.min(1, math.max(0, x)) end
local cbrt = function(x) return x ^ (1 / 3) end
local atan2 = math.atan2 or math.atan

function O.max_chroma(L)
  L = clamp(L)
  -- Peak chroma near mid-lightness; dies at black/white like OKHSL's cusp.
  return 0.125 + 0.275 * (1 - (2 * L - 1) ^ 2)
end

function O.rgb_to_okhsl(c)
  local r, g, b = srgb_to_lin(c[1]), srgb_to_lin(c[2]), srgb_to_lin(c[3])
  local l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  local m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  local s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  local L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
  local A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
  local B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  local C = math.sqrt(A * A + B * B)
  local h = math.deg(atan2(B, A)) % 360
  local cap = O.max_chroma(L)
  local sat = cap > 1e-6 and clamp(C / cap) or 0
  return { h, sat * 100, clamp(L) * 100 }
end

function O.okhsl_to_rgb(hsl)
  local h = (hsl[1] or 0) % 360
  local sat = clamp((hsl[2] or 0) / 100)
  local L = clamp((hsl[3] or 0) / 100)
  local C = sat * O.max_chroma(L)
  local rad = math.rad(h)
  local A = C * math.cos(rad)
  local B = C * math.sin(rad)
  local l = (L + 0.3963377774 * A + 0.2158037573 * B) ^ 3
  local m = (L - 0.1055613458 * A - 0.0638541728 * B) ^ 3
  local s = (L - 0.0894841775 * A - 1.2914855480 * B) ^ 3
  local r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  local b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  return { clamp(lin_to_srgb(r)), clamp(lin_to_srgb(g)), clamp(lin_to_srgb(b)) }
end

return O
