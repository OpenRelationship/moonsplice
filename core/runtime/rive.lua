-- Frame-addressed Rive. Same pattern as Lottie: set time from t, no update(dt).
-- Runtime is the moonsplice_rive cdylib (rive-rs). Until that crate ships, available
-- is false and s:rive nodes skip drawing.
local R = { available = false }

local ok, lib = pcall(function()
  return require("ffi").load(require("native").lib("moonsplice_rive"))
end)
if ok and lib then R.available = true end

function R.open(path, w, h, imgdata_ptr)
  error("moonsplice rive: runtime not bundled yet (rive-rs crate). Use s:lottie for vector animation.")
end

return R
