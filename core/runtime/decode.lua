-- LuaJIT FFI bridge to moonsplice-decode v2 (YUV-native + prefetch worker).
local ffi = require("ffi")

ffi.cdef([[
int64_t ed_open2(const char *path, int fb_w, int fb_h);
int ed_info(int64_t handle, int *mode, int *w, int *h, int *full_range);
int ed_frame_yuv(int64_t handle, double t, uint8_t *y, size_t ylen,
                 uint8_t *u, size_t ulen, uint8_t *v, size_t vlen);
int ed_frame_rgba(int64_t handle, double t, uint8_t *out, size_t len);
void ed_prefetch(int64_t handle, double t);
void ed_close(int64_t handle);
int ed_yuv420_to_rgba(const uint8_t *y, const uint8_t *u, const uint8_t *v, int w, int h, int full_range, uint8_t *out, size_t out_len);
]])

local D = { available = false }

local function dylib_path()
  return require("native").lib("moonsplice_decode")
end

local lib
local ok, err = pcall(function() lib = ffi.load(dylib_path()) end)
if ok and lib then
  D.available = true
else
  io.stderr:write("moonsplice: decode dylib not found (" .. tostring(err) ..
    ") — falling back to jpg extraction\n")
end

-- returns { handle, mode = "yuv"|"rgba", w, h, full_range }
function D.open(path, fb_w, fb_h)
  local handle = lib.ed_open2(path, fb_w, fb_h)
  if handle < 0 then error("moonsplice-decode: cannot open " .. path) end
  local mode = ffi.new("int[1]")
  local w = ffi.new("int[1]")
  local h = ffi.new("int[1]")
  local fr = ffi.new("int[1]")
  if lib.ed_info(handle, mode, w, h, fr) ~= 0 then error("moonsplice-decode: info failed") end
  return {
    handle = handle,
    mode = mode[0] == 0 and "yuv" or "rgba",
    w = w[0], h = h[0],
    full_range = fr[0] == 1,
  }
end

function D.frame_yuv(dec, t, y, ylen, u, ulen, v, vlen)
  if lib.ed_frame_yuv(dec.handle, t, y, ylen, u, ulen, v, vlen) ~= 0 then
    error("moonsplice-decode: yuv frame fetch failed at t=" .. tostring(t))
  end
end

function D.frame_rgba(dec, t, ptr, len)
  if lib.ed_frame_rgba(dec.handle, t, ptr, len) ~= 0 then
    error("moonsplice-decode: rgba frame fetch failed at t=" .. tostring(t))
  end
end

function D.yuv_to_rgba(y, u, v, w, h, full_range, out, out_len)
  if lib.ed_yuv420_to_rgba(y, u, v, w, h, full_range and 1 or 0, out, out_len) ~= 0 then
    error("moonsplice-decode: yuv→rgba failed")
  end
end

function D.prefetch(dec, t)
  lib.ed_prefetch(dec.handle, t)
end

function D.close(dec)
  lib.ed_close(dec.handle)
end

return D
