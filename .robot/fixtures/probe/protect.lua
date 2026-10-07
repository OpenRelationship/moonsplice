-- Gap 1: a system that fails only at some times must not take the comp down. Passes once lint reports a
-- system_error finding (not a compile_error) and render finishes with exit 0, drawing the other systems.
local R = dofile(".robot/fixtures/probe/run.lua")
local d = R.json("./moonsplice lint .robot/fixtures/probe/bomb.lua --json")
local codes = table.concat(R.errors(d), ",")
if not codes:find("system_error") then R.fail("lint gives [%s], wants a system_error for bomb", codes) end
local out, rc = R.sh("./moonsplice render .robot/fixtures/probe/bomb.lua -o \"${TMPDIR:-/tmp}/probe-bomb.mp4\"")
os.remove((os.getenv("TMPDIR") or "/tmp/") .. "/probe-bomb.mp4")
if rc ~= 0 or out:find("moonsplice error") then R.fail("render dies: %s", (out:match("[^\n]*error[^\n]*") or out):sub(1, 300)) end
