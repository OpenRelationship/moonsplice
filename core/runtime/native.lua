-- Stable runtime path for staged native helpers. Development and CI can point
-- MOONSPLICE_NATIVE directly at a Cargo release directory to skip staging.
local N = {}

function N.root()
  return love.filesystem.getSource():gsub("/core/runtime/?$", "")
end

function N.extension()
  if jit and jit.os == "Windows" then return ".dll" end
  if jit and jit.os == "OSX" then return ".dylib" end
  return ".so"
end

function N.lib(name)
  local dir = os.getenv("MOONSPLICE_NATIVE") or (N.root() .. "/native/target/release")
  local prefix = (jit and jit.os == "Windows") and "" or "lib"
  return dir .. "/" .. prefix .. name .. N.extension()
end

return N
