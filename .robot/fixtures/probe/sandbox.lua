-- Gap 4: a system's sandbox must not reach the host. Passes once a system that writes into string or table
-- leaves the host's own libraries untouched (today the sandbox hands systems the real string and table).
package.path = "core/?.lua;core/?/init.lua;" .. package.path
local R = require("moonsplice.rows")
pcall(R.load_system, "leak", "string.probe_leak = true; table.probe_leak = true; return function() return {} end", {})
local leaks = {}
if string.probe_leak then leaks[#leaks + 1] = "string" end
if table.probe_leak then leaks[#leaks + 1] = "table" end
if #leaks > 0 then io.stderr:write("a system wrote into the host's " .. table.concat(leaks, " and ") .. "\n"); os.exit(1) end
