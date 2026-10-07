-- Gap 2: lint must see what render sees. tide60.lua fails only at frame 211 of 360 (60 fps); render dies there.
-- Passes once lint (and the patch that admitted it) evaluates every frame at the render fps and reports it.
local R = dofile(".robot/fixtures/probe/run.lua")
local d = R.json("./moonsplice lint .robot/fixtures/probe/tide60.lua --json")
if #R.errors(d) == 0 then R.fail("lint passes tide60.lua, which render cannot finish (frame 211)") end
