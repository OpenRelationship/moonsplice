-- Seek-safe 3D world bridge: Lua command stream → moonsplice_scene3d → ImageData.
-- Same contract as vector/html: ffi.load a cdylib, rasterize into a buffer.
local ffi = require("ffi")

ffi.cdef([[
int64_t el_scene3d_load(const char *path);
void el_scene3d_unload(int64_t handle);
int el_scene3d_render(const float *cmds, size_t len, uint16_t w, uint16_t h,
                      uint8_t *out, size_t out_len);
]])

local S = { available = false }

local lib
local ok = pcall(function()
  lib = ffi.load(require("native").lib("moonsplice_scene3d"))
end)
if ok and lib then S.available = true end

local Builder = {}
Builder.__index = Builder

function S.new_builder()
  return setmetatable({ cap = 512, len = 0, buf = ffi.new("float[?]", 512) }, Builder)
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

function Builder:camera(ex, ey, ez, lx, ly, lz, ux, uy, uz, fov, near, far, yaw, pitch, roll)
  push(self, 0, ex, ey, ez, lx, ly, lz, ux, uy, uz, fov, near, far, yaw or 0, pitch or 0, roll or 0)
end

function Builder:light(dx, dy, dz, r, g, b, intensity)
  push(self, 1, dx, dy, dz, r, g, b, intensity or 1)
end

function Builder:ambient(r, g, b) push(self, 2, r, g, b) end
function Builder:clear(r, g, b, a) push(self, 3, r, g, b, a or 0) end

local function xform(self, op, x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a)
  push(self, op, x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a)
end

function Builder:cube(x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a)
  xform(self, 4, x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a)
end

function Builder:mesh(handle, x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a)
  push(self, 5, handle, x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a)
end

function Builder:sphere(x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a)
  xform(self, 6, x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a)
end

function S.load(path)
  if not lib then return 0 end
  return tonumber(lib.el_scene3d_load(path)) or 0
end

function S.unload(handle)
  if lib and handle and handle ~= 0 then lib.el_scene3d_unload(handle) end
end

function S.render(builder, w, h, out_ptr, out_len)
  if lib.el_scene3d_render(builder.buf, builder.len, w, h,
    ffi.cast("uint8_t*", out_ptr), out_len) ~= 0 then
    error("moonsplice-scene3d: render failed")
  end
end

return S
