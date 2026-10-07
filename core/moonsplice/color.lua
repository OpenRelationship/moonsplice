-- Color parsing + interpolation. Internal form: {r,g,b,a} floats 0..1.
-- Default lerp is OKLab (animato-inspired). HSLuv / OKHSL are opt-in per
-- node/comp via color_space; "rgb" is the muddy baseline for eval contrast.
local hsluv = require("moonsplice.hsluv")
local okhsl = require("moonsplice.okhsl")
local C = {}

local function hexpair(s, i) return tonumber(s:sub(i, i + 1), 16) / 255 end

function C.parse(v)
  if type(v) == "table" then
    return { v[1] or v.r or 0, v[2] or v.g or 0, v[3] or v.b or 0, v[4] or v.a or 1 }
  end
  if type(v) == "string" then
    local s = v:gsub("^#", "")
    -- #rgb / #rgba, the form every other tool in the ecosystem takes. Each digit
    -- doubles, so #0c1 is #00cc11 -- the same rule CSS uses.
    if #s == 3 or #s == 4 then
      s = s:gsub("(%x)", "%1%1")
    end
    if #s == 6 then return { hexpair(s, 1), hexpair(s, 3), hexpair(s, 5), 1 } end
    if #s == 8 then return { hexpair(s, 1), hexpair(s, 3), hexpair(s, 5), hexpair(s, 7) } end
    error(("moonsplice: bad color %q"):format(v), 3)
  end
  error("moonsplice: bad color type " .. type(v), 3)
end

function C.is_color(v)
  return type(v) == "table" and #v == 4
end

-- Perceptual color interpolation via OKLab (animato-inspired): no muddy
-- mid-tween grays, hue moves the short way perceptually. Alpha lerps linearly.
local function srgb_to_lin(c)
  if c <= 0.04045 then return c / 12.92 end
  return ((c + 0.055) / 1.055) ^ 2.4
end
local function lin_to_srgb(c)
  if c <= 0.0031308 then return 12.92 * c end
  return 1.055 * c ^ (1 / 2.4) - 0.055
end
local cbrt = function(x) return x ^ (1 / 3) end

local function to_oklab(c)
  local r, g, b = srgb_to_lin(c[1]), srgb_to_lin(c[2]), srgb_to_lin(c[3])
  local l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
  local m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
  local s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
  return {
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  }
end

local function from_oklab(L, A, B)
  local l = (L + 0.3963377774 * A + 0.2158037573 * B) ^ 3
  local m = (L - 0.1055613458 * A - 0.0638541728 * B) ^ 3
  local s = (L - 0.0894841775 * A - 1.2914855480 * B) ^ 3
  local r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  local g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  local b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
  local clamp = function(x) return math.min(1, math.max(0, x)) end
  return clamp(lin_to_srgb(r)), clamp(lin_to_srgb(g)), clamp(lin_to_srgb(b))
end

local function lerp_alpha(a, b, k)
  return (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * k
end

function C.lerp_rgb(a, b, k)
  return {
    a[1] + (b[1] - a[1]) * k,
    a[2] + (b[2] - a[2]) * k,
    a[3] + (b[3] - a[3]) * k,
    lerp_alpha(a, b, k),
  }
end

function C.lerp_oklab(a, b, k)
  local la, lb = to_oklab(a), to_oklab(b)
  local r, g, bl = from_oklab(
    la[1] + (lb[1] - la[1]) * k,
    la[2] + (lb[2] - la[2]) * k,
    la[3] + (lb[3] - la[3]) * k)
  return { r, g, bl, lerp_alpha(a, b, k) }
end

function C.lerp_hsluv(a, b, k)
  local ha, hb = hsluv.rgb_to_hsluv(a), hsluv.rgb_to_hsluv(b)
  local dh = hb[1] - ha[1]
  if dh > 180 then dh = dh - 360 elseif dh < -180 then dh = dh + 360 end
  local rgb = hsluv.hsluv_to_rgb({
    (ha[1] + dh * k) % 360,
    ha[2] + (hb[2] - ha[2]) * k,
    ha[3] + (hb[3] - ha[3]) * k,
  })
  local clamp = function(x) return math.min(1, math.max(0, x)) end
  return { clamp(rgb[1]), clamp(rgb[2]), clamp(rgb[3]), lerp_alpha(a, b, k) }
end

function C.lerp_okhsl(a, b, k)
  local ha, hb = okhsl.rgb_to_okhsl(a), okhsl.rgb_to_okhsl(b)
  local dh = hb[1] - ha[1]
  if dh > 180 then dh = dh - 360 elseif dh < -180 then dh = dh + 360 end
  local rgb = okhsl.okhsl_to_rgb({
    (ha[1] + dh * k) % 360,
    ha[2] + (hb[2] - ha[2]) * k,
    ha[3] + (hb[3] - ha[3]) * k,
  })
  return { rgb[1], rgb[2], rgb[3], lerp_alpha(a, b, k) }
end

-- Brand ramps: n steps, fixed hue/sat, lightness from l0→l1 (OKHSL).
function C.palette(opts)
  opts = opts or {}
  local n = opts.n or 5
  local h = opts.h or 210
  local s = opts.s or 72
  local l0 = opts.l0 or 32
  local l1 = opts.l1 or 78
  local out = {}
  for i = 1, n do
    local t = n == 1 and 0.5 or (i - 1) / (n - 1)
    local rgb = okhsl.okhsl_to_rgb({ h, s, l0 + (l1 - l0) * t })
    out[i] = { rgb[1], rgb[2], rgb[3], 1 }
  end
  return out
end

function C.lerp(a, b, k, space)
  if space == "rgb" then return C.lerp_rgb(a, b, k) end
  if space == "hsluv" then return C.lerp_hsluv(a, b, k) end
  if space == "okhsl" then return C.lerp_okhsl(a, b, k) end
  return C.lerp_oklab(a, b, k)
end

return C
