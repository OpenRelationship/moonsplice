-- vello_cpu vector-node bridge: Lua builder → flat f32 command stream → Rust.
local ffi = require("ffi")
local colorlib = require("moonsplice.color")

ffi.cdef([[
int el_vec_render(const float *cmds, size_t len, uint16_t w, uint16_t h,
                  uint8_t *out, size_t out_len);
]])

local V = { available = false }

local lib
local ok = pcall(function()
  lib = ffi.load(require("native").lib("moonsplice_vector"))
end)
if ok and lib then V.available = true end

-- growable f32 command buffer, reused across frames
local Builder = {}
Builder.__index = Builder

function V.new_builder()
  return setmetatable({ cap = 4096, len = 0, buf = ffi.new("float[?]", 4096) }, Builder)
end

function Builder:reset() self.len = 0 end

local function push(b, ...)
  local n = select("#", ...)
  if b.len + n > b.cap then
    local ncap = b.cap * 2
    while b.len + n > ncap do ncap = ncap * 2 end
    local nbuf = ffi.new("float[?]", ncap)
    ffi.copy(nbuf, b.buf, b.len * 4)
    b.buf, b.cap = nbuf, ncap
  end
  for i = 1, n do
    b.buf[b.len] = select(i, ...)
    b.len = b.len + 1
  end
end

local function col(c)
  if type(c) == "string" then c = colorlib.parse(c) end
  return c[1], c[2], c[3], c[4] or 1
end

function Builder:rect(x, y, w, h, c, rad)
  if rad and rad > 0 then
    push(self, 1, x, y, w, h, rad, col(c))
  else
    push(self, 0, x, y, w, h, col(c))
  end
end

function Builder:circle(cx, cy, r, c) push(self, 2, cx, cy, r, col(c)) end
function Builder:move(x, y) push(self, 3, x, y) end
function Builder:line(x, y) push(self, 4, x, y) end
function Builder:curve(x1, y1, x2, y2, x, y) push(self, 5, x1, y1, x2, y2, x, y) end
function Builder:fill(c) push(self, 6, col(c)) end
function Builder:stroke(width, c) push(self, 7, width, col(c)) end

function Builder:polyline(pts, width, c)
  if #pts < 4 then return end
  self:move(pts[1], pts[2])
  for i = 3, #pts, 2 do
    self:line(pts[i], pts[i + 1])
  end
  self:stroke(width or 2, c)
end

function Builder:gradient(x, y, w, h, x0, y0, x1, y1, c0, c1)
  push(self, 8, x, y, w, h, x0, y0, x1, y1)
  push(self, col(c0))
  push(self, col(c1))
end

-- soft radial blob (mesh-gradient building block): center color -> edge color
function Builder:radial(cx, cy, r, c0, c1)
  push(self, 9, cx, cy, r)
  push(self, col(c0))
  push(self, col(c1))
end

-- film grain post-pass over the whole node (deterministic; vary seed to animate)
function Builder:grain(amount, seed)
  push(self, 10, amount, seed or 1)
end

function V.render(builder, w, h, out_ptr, out_len)
  if lib.el_vec_render(builder.buf, builder.len, w, h,
    ffi.cast("uint8_t*", out_ptr), out_len) ~= 0 then
    error("moonsplice-vector: render failed")
  end
end

return V
