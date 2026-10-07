-- Solids as data (.robot/docs/solids.robot): a tree of plain values built by Manifold, in the engine
-- (solid/, MOONSPLICE_ENGINE.solid), once per tree. The cache is keyed by the tree's canonical JSON,
-- so the same tree is the same file everywhere; a comp stays a pure function of time.
local M = {}

local function home() return os.getenv("HOME") or "." end

local function cache_dir()
  local d = home() .. "/.cache/moonsplice/solids"
  local p = _MOONSPLICE_POPEN("mkdir -p '" .. d .. "' 2>&1", "r"); p:read("*a"); p:close()
  return d
end

local function read(path)
  local f = _MOONSPLICE_IOOPEN(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

-- tree -> { src = path to the .msh, size, min, max, volume, area, parts, genus, watertight, triangles }
function M.build(tree)
  local E = rawget(_G, "MOONSPLICE_ENGINE")
  assert(E and E.solid, "moonsplice: solids need the engine (MOONSPLICE_ENGINE.solid)")
  local R = require("moonsplice.rows")
  local text = R.json(tree)
  local hex = love.data.encode("string", "hex", love.data.hash("sha1", "msh2|" .. text))
  local base = cache_dir() .. "/" .. hex
  local info = read(base .. ".info.json")
  if not (info and read(base .. ".msh")) then
    info = E.solid(text, base .. ".msh")
    local r = require("moonsplice.json").decode(info)
    if r.error then error("moonsplice solid: " .. r.error, 0) end
    local f = assert(_MOONSPLICE_IOOPEN(base .. ".info.json", "wb")); f:write(info); f:close()
  end
  local r = require("moonsplice.json").decode(info)
  r.src = base .. ".msh"
  return r
end

return M
