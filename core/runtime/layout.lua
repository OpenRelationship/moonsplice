-- Taffy flexbox bridge (compile-time solve; render loop never sees this).
local ffi = require("ffi")

ffi.cdef([[
typedef struct {
  float width, height;
  int direction, justify, align;
  float gap, padding;
  int wrap;
} ElContainer;
typedef struct {
  float width, height, grow, shrink, margin;
} ElItem;
int el_flex_solve(const ElContainer *container, const ElItem *items, size_t n, float *out);
]])

local L = { available = false }

local lib
local ok = pcall(function()
  lib = ffi.load(require("native").lib("moonsplice_layout"))
end)
if ok and lib then L.available = true end

local JUSTIFY = { start = 0, center = 1, ["end"] = 2, between = 3, around = 4, evenly = 5 }
local ALIGN = { start = 0, center = 1, ["end"] = 2, stretch = 3 }

-- items: array of {w, h, grow, shrink, margin} (NaN-able w/h via nil)
-- returns array of {x, y, w, h} relative to container
function L.solve(c, items)
  local cont = ffi.new("ElContainer", {
    width = c.w, height = c.h,
    direction = c.dir == "column" and 1 or 0,
    justify = JUSTIFY[c.justify or "start"] or 0,
    align = ALIGN[c.align or "start"] or 0,
    gap = c.gap or 0,
    padding = c.pad or 0,
    wrap = c.wrap and 1 or 0,
  })
  local arr = ffi.new("ElItem[?]", #items)
  local nan = 0 / 0
  for i, it in ipairs(items) do
    arr[i - 1].width = it.w or nan
    arr[i - 1].height = it.h or nan
    arr[i - 1].grow = it.grow or 0
    arr[i - 1].shrink = it.shrink or 1
    arr[i - 1].margin = it.margin or 0
  end
  local out = ffi.new("float[?]", #items * 4)
  if lib.el_flex_solve(cont, arr, #items, out) ~= 0 then
    error("moonsplice-layout: flex solve failed")
  end
  local res = {}
  for i = 1, #items do
    res[i] = {
      x = out[(i - 1) * 4], y = out[(i - 1) * 4 + 1],
      w = out[(i - 1) * 4 + 2], h = out[(i - 1) * 4 + 3],
    }
  end
  return res
end

return L
