-- Part of fx (core/runtime/fx.lua): see its head for the module's contract.
local F = require("fx")
local BLUR, BRIGHT, CHROMA, COMBINE = F._.BLUR, F._.BRIGHT, F._.CHROMA, F._.COMBINE
local FILMGRAIN, GLOW, GRAIN, KAWASE_DOWN = F._.FILMGRAIN, F._.GLOW, F._.GRAIN, F._.KAWASE_DOWN
local KAWASE_UP, PIXELATE, POSTERIZE, TONEMAP = F._.KAWASE_UP, F._.PIXELATE, F._.POSTERIZE, F._.TONEMAP
local VIGNETTE, WORLEY, send_if, shader = F._.VIGNETTE, F._.WORLEY, F._.send_if, F._.shader

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
