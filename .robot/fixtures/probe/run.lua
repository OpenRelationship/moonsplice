-- Shared by the gap probes: run ./moonsplice from the checkout and read its JSON reply.
local M = {}
package.path = "core/?.lua;core/?/init.lua;" .. package.path
local json = require("moonsplice.json")
function M.sh(cmd)
  local p = assert(io.popen(cmd .. " 2>&1; echo \"@rc $?\""))
  local s = p:read("*a"); p:close()
  local out, rc = s:match("^(.-)@rc (%d+)%s*$")
  return out or s, tonumber(rc)
end
function M.json(cmd)
  local out = M.sh(cmd)
  local ok, d = pcall(json.decode, out:match("{.*}") or "")
  return ok and d or nil, out
end
function M.errors(d)
  local codes = {}
  for _, f in ipairs(d and d.findings or {}) do if f.severity == "error" then codes[#codes + 1] = f.code end end
  return codes
end
function M.fail(fmt, ...) io.stderr:write((fmt):format(...), "\n"); os.exit(1) end
return M
