-- Gap 5: authored values and defaults kept apart. Passes once a mesh authored with no yaw and a rect with no x
-- read back nil from what was authored, while Node:get still answers the defaults (0).
package.path = "core/?.lua;core/?/init.lua;" .. package.path
local e = require("moonsplice")
local c = e.comp { width = 64, height = 64, duration = 1, fps = 30, scene = function(s)
  s:rect { id = "r", y = 0, w = 10, h = 10, color = "#fff" }
  local w = s:world { id = "w", x = 0, y = 0, w = 64, h = 64 }
  s:mesh { id = "m", parent = w, primitive = "cube" }
end }
c:compile({})
local by = {}
for _, n in ipairs(c.nodes) do if n.id then by[n.id] = n end end
local bad = {}
if by.m.initial.yaw ~= nil then bad[#bad + 1] = "mesh m: yaw " .. tostring(by.m.initial.yaw) .. " in what was authored" end
if by.r.initial.x ~= nil then bad[#bad + 1] = "rect r: x " .. tostring(by.r.initial.x) .. " in what was authored" end
c:evaluate(0)
if by.m:get("yaw") ~= 0 then bad[#bad + 1] = "mesh m: get(yaw) is " .. tostring(by.m:get("yaw")) .. ", wants the default 0" end
if #bad > 0 then io.stderr:write(table.concat(bad, "; ") .. "\n"); os.exit(1) end
