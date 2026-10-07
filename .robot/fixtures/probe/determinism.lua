-- Determinism: the same comp hashed twice gives the same frames. game_harbour3d's Bevy 3D frames vary run to run
-- (about 25-40 of 660). Passes once they do not.
local R = dofile(".robot/fixtures/probe/run.lua")
local a = R.sh("./moonsplice hash comps/cases/game_harbour3d.lua")
local b = R.sh("./moonsplice hash comps/cases/game_harbour3d.lua")
local ha, n = {}, 0
for i, h in a:gmatch("FRAME (%d+) (%x+)") do ha[i] = h end
for i, h in b:gmatch("FRAME (%d+) (%x+)") do if ha[i] ~= h then n = n + 1 end end
if n > 0 then R.fail("game_harbour3d: %d frames differ between two runs", n) end
