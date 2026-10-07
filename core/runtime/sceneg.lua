-- sceneg: the part of `love.graphics` that drawing code uses, recorded into the scene stream.
--
-- The kinds LÖVE used to draw (particles, chart, ornament, spine, spritesheet, `s:draw`) are
-- written against `g.circle`, `g.line`, `g.setColor`, `g.push`/`g.translate`... This is that
-- surface over `scene.lua`'s builder, so the same drawing code paints through `scene/` with no
-- LÖVE underneath. It is a subset on purpose: anything not here raises a sentence naming the
-- call, rather than drawing nothing.

local scene = require("scene")

local G = {}

local function mul(a, b)
  return {
    a[1] * b[1] + a[3] * b[2], a[2] * b[1] + a[4] * b[2],
    a[1] * b[3] + a[3] * b[4], a[2] * b[3] + a[4] * b[4],
    a[1] * b[5] + a[3] * b[6] + a[5], a[2] * b[5] + a[4] * b[6] + a[6],
  }
end

local function args(...)
  local first = ...
  if type(first) == "table" then return first end
  return { ... }
end

-- `base` is the node's affine in frame space; drawing starts from it.
function G.new(builder, base, images)
  local g = {}
  local m = { base[1], base[2], base[3], base[4], base[5], base[6] }
  local stack = {}
  local color = { 1, 1, 1, 1 }
  local width = 1
  local alpha_scale = 1

  local function c() return { color[1], color[2], color[3], color[4] * alpha_scale } end
  local function at() builder:transform(m) end

  function g.setColor(r, gg, b, a)
    if type(r) == "table" then r, gg, b, a = r[1], r[2], r[3], r[4] end
    color = { r or 1, gg or 1, b or 1, a or 1 }
  end
  function g.getColor() return color[1], color[2], color[3], color[4] end
  function g.setLineWidth(w) width = w end
  function g.getLineWidth() return width end
  function g.setLineJoin() end
  function g.setLineStyle() end
  function g.setBlendMode() end
  function g.getBlendMode() return "alpha", "alphamultiply" end

  function g.push() stack[#stack + 1] = { m[1], m[2], m[3], m[4], m[5], m[6] } end
  function g.pop() m = table.remove(stack) or m end
  function g.origin() m = { base[1], base[2], base[3], base[4], base[5], base[6] } end
  function g.translate(x, y) m = mul(m, { 1, 0, 0, 1, x or 0, y or 0 }) end
  function g.scale(sx, sy) sx = sx or 1; m = mul(m, { sx, 0, 0, sy or sx, 0, 0 }) end
  function g.rotate(r)
    local cs, sn = math.cos(r or 0), math.sin(r or 0)
    m = mul(m, { cs, sn, -sn, cs, 0, 0 })
  end

  function g.rectangle(mode, x, y, w, h, rx)
    at()
    if mode == "fill" then
      builder:rect(x, y, w, h, c(), rx or 0)
    else
      builder:move(x, y); builder:line(x + w, y); builder:line(x + w, y + h); builder:line(x, y + h); builder:line(x, y)
      builder:stroke(width, c())
    end
  end

  local function arcpath(cx, cy, r, a0, a1, rx, ry)
    rx, ry = rx or r, ry or r
    local n = math.max(8, math.ceil(math.abs(a1 - a0) / (math.pi * 2) * 64))
    local pts = {}
    for k = 0, n do
      local a = a0 + (a1 - a0) * k / n
      pts[#pts + 1] = cx + math.cos(a) * rx
      pts[#pts + 1] = cy + math.sin(a) * ry
    end
    return pts
  end
  local function path(pts, close)
    builder:move(pts[1], pts[2])
    for k = 3, #pts - 1, 2 do builder:line(pts[k], pts[k + 1]) end
    if close then builder:line(pts[1], pts[2]) end
  end

  function g.circle(mode, x, y, r)
    at()
    if mode == "fill" then builder:circle(x, y, r, c())
    else path(arcpath(x, y, r, 0, math.pi * 2), true); builder:stroke(width, c()) end
  end
  function g.ellipse(mode, x, y, rx, ry)
    at()
    path(arcpath(x, y, nil, 0, math.pi * 2, rx, ry), true)
    if mode == "fill" then builder:fill(c()) else builder:stroke(width, c()) end
  end
  function g.arc(mode, x, y, r, a0, a1)
    at()
    local pts = arcpath(x, y, r, a0, a1)
    if mode == "fill" then
      table.insert(pts, 1, y); table.insert(pts, 1, x)
      path(pts, true); builder:fill(c())
    else
      path(pts, false); builder:stroke(width, c())
    end
  end
  function g.line(...)
    local pts = args(...)
    if #pts < 4 then return end
    at(); path(pts, false); builder:stroke(width, c())
  end
  function g.polygon(mode, ...)
    local pts = args(...)
    if #pts < 6 then return end
    at(); path(pts, true)
    if mode == "fill" then builder:fill(c()) else builder:stroke(width, c()) end
  end
  function g.points(...)
    local pts = args(...)
    at()
    for k = 1, #pts - 1, 2 do builder:rect(pts[k] - 0.5, pts[k + 1] - 0.5, 1, 1, c(), 0) end
  end

  -- Images: `g.image(path)` stands in for `love.graphics.newImage` and returns something
  -- `g.draw` and `g.newQuad` understand.
  function g.image(p)
    return images(p)
  end
  function g.newQuad(x, y, w, h, sw, sh) return { quad = true, x = x, y = y, w = w, h = h, sw = sw, sh = sh } end
  function g.draw(img, quad, x, y, r, sx, sy, ox, oy)
    if type(quad) ~= "table" or not quad.quad then
      quad, x, y, r, sx, sy, ox, oy = nil, quad, x, y, r, sx, sy, ox
    end
    if type(img) ~= "table" or not img.scene_id then
      error("sceneg: g.draw takes an image from g.image(path) on the scene path", 2)
    end
    g.push()
    g.translate(x or 0, y or 0); g.rotate(r or 0); g.scale(sx or 1, sy or sx or 1); g.translate(-(ox or 0), -(oy or 0))
    at()
    local a = color[4] * alpha_scale
    if quad then
      -- the quad's region of the image, at the origin: clip to it, draw the whole image shifted
      builder:clip_push(0, 0, quad.w, quad.h, 0)
      builder:image(img.scene_id, -quad.x, -quad.y, img.w, img.h, 0, a)
      builder:pop()
    else
      builder:image(img.scene_id, 0, 0, img.w, img.h, 0, a)
    end
    g.pop()
  end

  -- opacity the caller applies on top of every colour (node opacity)
  function g.__alpha(a) alpha_scale = a end

  return setmetatable(g, {
    __index = function(_, k)
      return function()
        error(("g.%s is not on the scene path (core/runtime/sceneg.lua has what is)"):format(tostring(k)), 2)
      end
    end,
  })
end

-- A path's pixels as a scene image: { scene_id, w, h }, loaded once per path.
local loaded = {}
function G.image(path)
  if not loaded[path] then
    local f = assert(_MOONSPLICE_IOOPEN(path, "rb"), "moonsplice: cannot read " .. path)
    local bytes = f:read("*a"); f:close()
    local data = love.image.newImageData(love.filesystem.newFileData(bytes, path))
    local w, h = data:getWidth(), data:getHeight()
    loaded[path] = { scene_id = scene.image_id(path, data), w = w, h = h,
      getDimensions = function() return w, h end, getWidth = function() return w end,
      getHeight = function() return h end }
  end
  return loaded[path]
end

return G
