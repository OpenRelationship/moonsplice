-- Gap 3: one time rule. Passes once a boundary authored as a time lands on the frame its author meant (summed
-- waits and 0.1+0.2 included) and 30000/1001 fps maps every frame to itself. time_report.lua prints the detail.
local R = dofile(".robot/fixtures/probe/run.lua")
local out = R.sh("luajit .robot/fixtures/probe/time_report.lua")
local bad = {}
for how, got, want in out:gmatch("%(a%) (.-)%s+t0=[^\n]-first visible frame=(%d+) %(intended (%d+)%)") do
  if got ~= want then bad[#bad + 1] = ("%s lands on frame %s, meant %s"):format(how, got, want) end
end
local mis = out:match("fps=30000/1001: frames where floor%(%(i/fps%)%*fps%) ~= i: (%d+)")
if mis ~= "0" then bad[#bad + 1] = ("29.97 fps: %s of 108000 frames index wrong"):format(tostring(mis)) end
if #bad > 0 then R.fail("%s", table.concat(bad, "; ")) end
