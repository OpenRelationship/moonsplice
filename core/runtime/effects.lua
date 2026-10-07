-- Native, deterministic RGBA adjustment bridge. Effects operate on the
-- premultiplied buffers that HTML and vector nodes already own.
local ffi = require("ffi")

ffi.cdef([[
int el_fx_apply_rgba(uint8_t *pixels, uint32_t width, uint32_t height, size_t len,
  float blur, float brightness, float contrast, float saturate, float grayscale,
  float sepia, float invert, float opacity, float hue_rotate_degrees);
]])

local E = { available = false }
local lib
local ok = pcall(function()
  lib = ffi.load(require("native").lib("moonsplice_scene"))
end)
if ok and lib then E.available = true end

local defaults = {
  effect_blur = 0, effect_brightness = 1, effect_contrast = 1,
  effect_saturate = 1, effect_grayscale = 0, effect_sepia = 0,
  effect_invert = 0, effect_opacity = 1, effect_hue_rotate = 0,
}

function E.has_effects(node)
  for key, default in pairs(defaults) do
    if (node:get(key) or default) ~= default then return true end
  end
  return false
end

function E.apply(node, data, w, h)
  if not E.has_effects(node) then return end
  if not E.available then
    error("moonsplice: effects requested but native dylibs are not built; run moonsplice build")
  end
  local function prop(name) return node:get(name) or defaults[name] end
  local rc = lib.el_fx_apply_rgba(
    ffi.cast("uint8_t*", data:getFFIPointer()), w, h, data:getSize(),
    prop("effect_blur"), prop("effect_brightness"), prop("effect_contrast"),
    prop("effect_saturate"), prop("effect_grayscale"), prop("effect_sepia"),
    prop("effect_invert"), prop("effect_opacity"), prop("effect_hue_rotate")
  )
  if rc ~= 0 then error("moonsplice-effects: apply failed") end
end

return E
