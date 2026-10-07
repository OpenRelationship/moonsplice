-- Moonshine-style post FX + a Shadertoy → LÖVE converter.
-- Seek-safe: shaders + uniforms only. No clocks. Applied to an offscreen
-- canvas of an `s:fx` group.
local F = {}

local function send_if(sh, name, value)
  if sh:hasUniform(name) then sh:send(name, value) end
end

-- Shadertoy mainImage() wrapped as a LÖVE pixel effect. Replaces texture()
-- with Texel() and injects iTime / iResolution / iChannel0.
function F.convert_shadertoy(src)
  assert(type(src) == "string" and src:find("mainImage"),
    "moonsplice fx: shadertoy source must define mainImage")
  local body = src
    :gsub("texture2D%s*%(", "Texel(")
    :gsub("texture%s*%(", "Texel(")
  if F.preprocess then body = F.preprocess(body) end
  return table.concat({
    "uniform float iTime;",
    "uniform vec3 iResolution;",
    "uniform Image iChannel0;",
    body,
    [[
    vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
      vec4 fragColor = vec4(0.0);
      mainImage(fragColor, sc);
      return fragColor * color;
    }
    ]],
  }, "\n")
end

local shaders = {}

local function shader(name, src)
  if not shaders[name] then
    shaders[name] = love.graphics.newShader(src)
  end
  return shaders[name]
end

local BRIGHT = [[
  uniform float threshold;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 c = Texel(tex, uv);
    float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    float k = smoothstep(threshold, threshold + 0.25, l);
    return vec4(c.rgb * k, c.a) * color;
  }
]]

local BLUR = [[
  uniform vec2 dir;
  vec4 effect(vec4 c, Image tex, vec2 uv, vec2 sc) {
    float w[9];
    w[0]=0.0625; w[1]=0.0938; w[2]=0.1250; w[3]=0.1562; w[4]=0.1688;
    w[5]=0.1562; w[6]=0.1250; w[7]=0.0938; w[8]=0.0625;
    vec4 sum = vec4(0.0);
    float tot = 0.0;
    for (int i = 0; i < 9; i++) {
      float o = float(i) - 4.0;
      sum += Texel(tex, uv + dir * o) * w[i];
      tot += w[i];
    }
    return (sum / tot) * c;
  }
]]

local COMBINE = [[
  uniform Image bloom;
  uniform float strength;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 base = Texel(tex, uv);
    vec4 b = Texel(bloom, uv);
    return vec4(base.rgb + b.rgb * strength, base.a) * color;
  }
]]

local VIGNETTE = [[
  uniform float opacity;
  uniform float radius;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 c = Texel(tex, uv);
    float d = length(uv - vec2(0.5));
    float dark = smoothstep(radius, 1.0, d * 1.45);
    c.rgb *= 1.0 - opacity * dark;
    return c * color;
  }
]]

local CHROMA = [[
  uniform float amount;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec2 dir = (uv - vec2(0.5)) * amount * 0.004;
    float r = Texel(tex, uv + dir).r;
    float g = Texel(tex, uv).g;
    float b = Texel(tex, uv - dir).b;
    float a = Texel(tex, uv).a;
    return vec4(r, g, b, a) * color;
  }
]]

local GRAIN = [[
  uniform float amount;
  uniform float iTime;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 c = Texel(tex, uv);
    float n = fract(sin(dot(sc + iTime * 19.0, vec2(12.9898, 78.233))) * 43758.5453);
    c.rgb += (n - 0.5) * amount;
    return c * color;
  }
]]

local GLOW = [[
  uniform Image glow;
  uniform float strength;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 base = Texel(tex, uv);
    vec4 g = Texel(glow, uv);
    return vec4(max(base.rgb, g.rgb * strength), base.a) * color;
  }
]]

local PASSTHRU = [[
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    return Texel(tex, uv) * color;
  }
]]

-- LYGIA-style snippet table. LÖVE has no preprocessor; concat #include names.
local GLSL = {}
GLSL["lygia/color/tonemap/aces.glsl"] = [[
vec3 aces(vec3 x) {
  const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
  return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}
]]
GLSL["lygia/filter/kawase/down.glsl"] = [[
vec4 kawaseDown(Image tex, vec2 uv, vec2 pixel) {
  vec4 sum = Texel(tex, uv) * 4.0;
  sum += Texel(tex, uv + vec2(-pixel.x, -pixel.y));
  sum += Texel(tex, uv + vec2( pixel.x, -pixel.y));
  sum += Texel(tex, uv + vec2(-pixel.x,  pixel.y));
  sum += Texel(tex, uv + vec2( pixel.x,  pixel.y));
  return sum / 8.0;
}
]]
GLSL["lygia/filter/kawase/up.glsl"] = [[
vec4 kawaseUp(Image tex, vec2 uv, vec2 pixel) {
  vec2 o = pixel;
  vec4 sum = Texel(tex, uv + vec2(-o.x * 2.0, 0.0));
  sum += Texel(tex, uv + vec2(-o.x, -o.y)) * 2.0;
  sum += Texel(tex, uv + vec2(0.0, -o.y * 2.0));
  sum += Texel(tex, uv + vec2(o.x, -o.y)) * 2.0;
  sum += Texel(tex, uv + vec2(o.x * 2.0, 0.0));
  sum += Texel(tex, uv + vec2(o.x, o.y)) * 2.0;
  sum += Texel(tex, uv + vec2(0.0, o.y * 2.0));
  sum += Texel(tex, uv + vec2(-o.x, o.y)) * 2.0;
  return sum / 12.0;
}
]]
GLSL["lygia/generative/worley.glsl"] = [[
float worley(vec2 uv, float t) {
  vec2 p = uv * 6.0;
  vec2 i = floor(p);
  vec2 f = fract(p);
  float d = 1.0;
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec2 g = vec2(float(x), float(y));
      vec2 o = vec2(
        fract(sin(dot(i + g, vec2(127.1, 311.7)) + t) * 43758.5453),
        fract(sin(dot(i + g, vec2(269.5, 183.3)) + t * 1.3) * 43758.5453));
      vec2 r = g + o - f;
      d = min(d, dot(r, r));
    }
  }
  return sqrt(d);
}
]]

function F.preprocess(src)
  local seen = {}
  local function expand(s)
    return (s:gsub('#include%s+"([^"]+)"', function(path)
      if seen[path] then return "" end
      local body = GLSL[path]
      if not body then error("moonsplice fx: missing include " .. path, 0) end
      seen[path] = true
      return expand(body)
    end))
  end
  return expand(src)
end

local KAWASE_DOWN = F.preprocess([[
  #include "lygia/filter/kawase/down.glsl"
  uniform vec2 pixel;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    return kawaseDown(tex, uv, pixel) * color;
  }
]])

local KAWASE_UP = F.preprocess([[
  #include "lygia/filter/kawase/up.glsl"
  uniform vec2 pixel;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    return kawaseUp(tex, uv, pixel) * color;
  }
]])

local TONEMAP = F.preprocess([[
  #include "lygia/color/tonemap/aces.glsl"
  uniform float amount;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 c = Texel(tex, uv);
    c.rgb = mix(c.rgb, aces(c.rgb * 1.12), amount);
    return c * color;
  }
]])

local PIXELATE = [[
  uniform float amount;
  uniform vec2 pixel;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    float n = mix(1.0, 48.0, amount);
    vec2 cell = pixel * n;
    vec2 uv2 = floor(uv / cell) * cell + cell * 0.5;
    return Texel(tex, uv2) * color;
  }
]]

local POSTERIZE = [[
  uniform float amount;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 c = Texel(tex, uv);
    float levels = mix(12.0, 3.0, amount);
    c.rgb = floor(c.rgb * levels + 0.5) / levels;
    return c * color;
  }
]]

local FILMGRAIN = [[
  uniform float amount;
  uniform float iTime;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 c = Texel(tex, uv);
    float n = fract(sin(dot(sc + iTime * 13.0, vec2(12.9898, 78.233))) * 43758.5453);
    float y = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    c.rgb += (n - 0.5) * amount * (0.55 + 0.45 * y);
    return c * color;
  }
]]

local WORLEY = F.preprocess([[
  #include "lygia/generative/worley.glsl"
  uniform float amount;
  uniform float iTime;
  vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 c = Texel(tex, uv);
    float w = worley(uv + vec2(iTime * 0.03, 0.0), iTime);
    c.rgb = mix(c.rgb, c.rgb * vec3(0.85 + w), amount);
    return c * color;
  }
]])

-- what the parts share, and the parts (they load after this table is registered as fx)
F._ = {
  BLUR = BLUR, BRIGHT = BRIGHT, CHROMA = CHROMA, COMBINE = COMBINE,
  FILMGRAIN = FILMGRAIN, GLOW = GLOW, GRAIN = GRAIN, KAWASE_DOWN = KAWASE_DOWN,
  KAWASE_UP = KAWASE_UP, PIXELATE = PIXELATE, POSTERIZE = POSTERIZE, TONEMAP = TONEMAP,
  VIGNETTE = VIGNETTE, WORLEY = WORLEY, send_if = send_if, shader = shader,
}
package.loaded["fx"] = F
require("fxpass")

return F
