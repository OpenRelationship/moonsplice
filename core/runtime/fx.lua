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

function F.canvases(node, w, h)
  if node.fx_a and node.fx_w == w and node.fx_h == h then
    return node.fx_a, node.fx_b, node.fx_c
  end
  if node.fx_a then node.fx_a:release() end
  if node.fx_b then node.fx_b:release() end
  if node.fx_c then node.fx_c:release() end
  node.fx_a = love.graphics.newCanvas(w, h)
  node.fx_b = love.graphics.newCanvas(w, h)
  node.fx_c = love.graphics.newCanvas(w, h)
  node.fx_w, node.fx_h = w, h
  return node.fx_a, node.fx_b, node.fx_c
end

local function blit(src, dst, sh)
  local prev = love.graphics.getCanvas()
  local dw, dh = dst:getDimensions()
  local sw, shw = src:getDimensions()
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.setCanvas(dst)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(src, 0, 0, 0, dw / sw, dh / shw)
  love.graphics.setShader()
  love.graphics.setCanvas(prev)
  love.graphics.pop()
end

local function blur_into(src, ping, pong, w, h, radius)
  local sh = shader("blur", BLUR)
  local px = (radius or 6) / w
  local py = (radius or 6) / h
  sh:send("dir", { px, 0 })
  blit(src, ping, sh)
  sh:send("dir", { 0, py })
  blit(ping, pong, sh)
  return pong
end

local function pass_bloom(src, ping, pong, w, h, node)
  local bright = shader("bright", BRIGHT)
  send_if(bright, "threshold", 0.35)
  blit(src, ping, bright)
  local blurred = blur_into(ping, pong, ping, w, h, 8)
  local comb = shader("combine", COMBINE)
  send_if(comb, "bloom", blurred)
  send_if(comb, "strength", node:get("fx_bloom") or 0.45)
  blit(src, pong, comb)
  return pong
end

local function pass_glow(src, ping, pong, w, h, node)
  local blurred = blur_into(src, ping, pong, w, h, 10)
  local sh = shader("glow", GLOW)
  send_if(sh, "glow", blurred)
  send_if(sh, "strength", node:get("fx_glow") or 0.4)
  local dest = (blurred == pong) and ping or pong
  blit(src, dest, sh)
  return dest
end

local function pass_vignette(src, dst, node)
  local sh = shader("vignette", VIGNETTE)
  send_if(sh, "opacity", node:get("fx_vignette") or 0.35)
  send_if(sh, "radius", 0.55)
  blit(src, dst, sh)
  return dst
end

local function pass_chroma(src, dst, node)
  local sh = shader("chroma", CHROMA)
  send_if(sh, "amount", node:get("fx_chroma") or 1.5)
  blit(src, dst, sh)
  return dst
end

local function pass_grain(src, dst, node, t)
  local sh = shader("grain", GRAIN)
  send_if(sh, "amount", node:get("fx_grain") or 0.08)
  send_if(sh, "iTime", t)
  blit(src, dst, sh)
  return dst
end

local function pass_blur(src, ping, pong, w, h, node)
  return blur_into(src, ping, pong, w, h, node:get("fx_blur") or 4)
end

local function pass_shadertoy(src, dst, node, t, w, h)
  local src_code = node.initial.shadertoy
  if not src_code then return src end
  if not node.fx_toy then
    node.fx_toy = love.graphics.newShader(F.convert_shadertoy(src_code))
  end
  local sh = node.fx_toy
  send_if(sh, "iTime", t)
  send_if(sh, "iResolution", { w, h, 1 })
  send_if(sh, "iChannel0", src)
  blit(src, dst, sh)
  return dst
end

local function kawase_lo(node, w, h)
  local hw, hh = math.max(1, math.floor(w / 2)), math.max(1, math.floor(h / 2))
  if node.fx_klo and node.fx_kw == w and node.fx_kh == h then return node.fx_klo end
  if node.fx_klo then node.fx_klo:release() end
  node.fx_klo = love.graphics.newCanvas(hw, hh)
  node.fx_kw, node.fx_kh = w, h
  return node.fx_klo
end

local function pass_kawase(src, dst, node, w, h)
  local lo = kawase_lo(node, w, h)
  local down = shader("kawase_down", KAWASE_DOWN)
  local up = shader("kawase_up", KAWASE_UP)
  local iters = math.max(1, math.min(4, math.floor((node:get("fx_blur") or 2) + 0.5)))
  local cur = src
  for i = 1, iters do
    local px = (0.5 + (i - 1)) / w
    local py = (0.5 + (i - 1)) / h
    down:send("pixel", { px, py })
    blit(cur, lo, down)
    up:send("pixel", { px * 0.5, py * 0.5 })
    blit(lo, dst, up)
    cur = dst
  end
  return dst
end

local function pass_tonemap(src, dst, node)
  local sh = shader("tonemap", TONEMAP)
  send_if(sh, "amount", node:get("fx_tonemap") or 1)
  blit(src, dst, sh)
  return dst
end

local function pass_pixelate(src, dst, node, w, h)
  local sh = shader("pixelate", PIXELATE)
  send_if(sh, "amount", node:get("fx_pixelate") or 0.45)
  send_if(sh, "pixel", { 1 / w, 1 / h })
  blit(src, dst, sh)
  return dst
end

local function pass_posterize(src, dst, node)
  local sh = shader("posterize", POSTERIZE)
  send_if(sh, "amount", node:get("fx_posterize") or 0.55)
  blit(src, dst, sh)
  return dst
end

local function pass_filmgrain(src, dst, node, t)
  local sh = shader("filmgrain", FILMGRAIN)
  send_if(sh, "amount", node:get("fx_grain") or 0.08)
  send_if(sh, "iTime", t)
  blit(src, dst, sh)
  return dst
end

local function pass_worley(src, dst, node, t)
  local sh = shader("worley", WORLEY)
  send_if(sh, "amount", node:get("fx_worley") or 0.45)
  send_if(sh, "iTime", t)
  blit(src, dst, sh)
  return dst
end

-- Apply chain to canvases. `a` holds the unfiltered scene. Returns the canvas
-- that should be drawn.
function F.apply(node, a, b, c, t, w, h)
  local chain = node.initial.chain or { "bloom", "vignette" }
  local src = a
  local function other(x)
    if x == a then return b end
    if x == b then return c end
    return a
  end
  local function pair(x)
    local d = other(x)
    local e = other(d)
    if e == x then e = other(e) end
    return d, e
  end
  for _, name in ipairs(chain) do
    local dst, spare = pair(src)
    if name == "bloom" then
      src = pass_bloom(src, dst, spare, w, h, node)
    elseif name == "glow" then
      src = pass_glow(src, dst, spare, w, h, node)
    elseif name == "blur" then
      src = pass_blur(src, dst, spare, w, h, node)
    elseif name == "vignette" then
      src = pass_vignette(src, dst, node)
    elseif name == "chroma" or name == "chromasep" then
      src = pass_chroma(src, dst, node)
    elseif name == "grain" then
      src = pass_grain(src, dst, node, t)
    elseif name == "shadertoy" then
      src = pass_shadertoy(src, dst, node, t, w, h)
    elseif name == "kawase" then
      src = pass_kawase(src, dst, node, w, h)
    elseif name == "tonemap" or name == "aces" then
      src = pass_tonemap(src, dst, node)
    elseif name == "pixelate" then
      src = pass_pixelate(src, dst, node, w, h)
    elseif name == "posterize" then
      src = pass_posterize(src, dst, node)
    elseif name == "filmgrain" then
      src = pass_filmgrain(src, dst, node, t)
    elseif name == "worley" then
      src = pass_worley(src, dst, node, t)
    else
      error("moonsplice fx: unknown pass " .. tostring(name), 0)
    end
  end
  return src
end

return F
