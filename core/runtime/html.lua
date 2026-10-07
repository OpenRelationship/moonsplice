-- Blitz HTML bridge: CSS-laid-out fragments and full pages as textures, no Chrome.
local ffi = require("ffi")

ffi.cdef([[
int el_html_render(const char *html, uint32_t w, uint32_t h, float scale,
                   uint8_t *out, size_t out_len);
int el_html_render_page(const char *html, const char *base_url,
                        uint32_t w, uint32_t h, float scale, int bake,
                        uint8_t *out, size_t out_len);
int el_html_render_page_png(const char *html, const char *base_url,
                            uint32_t w, uint32_t h, float scale, int bake,
                            const char *path);
]])

local H = { available = false }

local lib
local ok = pcall(function()
  lib = ffi.load(require("native").lib("moonsplice_scene"))
end)
if ok and lib then H.available = true end

function H.render(html, w, h, scale, out_ptr, out_len)
  if lib.el_html_render(html, w, h, scale or 1.0,
    ffi.cast("uint8_t*", out_ptr), out_len) ~= 0 then
    error("moonsplice-html: render failed")
  end
end

function H.render_page(html, base_url, w, h, scale, out_ptr, out_len, bake)
  local b = (bake ~= false) and 1 or 0
  if lib.el_html_render_page(html, base_url or "", w, h, scale or 1.0, b,
    ffi.cast("uint8_t*", out_ptr), out_len) ~= 0 then
    error("moonsplice-html: page render failed")
  end
end

function H.render_page_png(html, base_url, w, h, scale, path, bake)
  local b = (bake ~= false) and 1 or 0
  if lib.el_html_render_page_png(html, base_url or "", w, h, scale or 1.0, b, path) ~= 0 then
    error("moonsplice-html: page png failed")
  end
end

return H
