-- The control: the same moves on a fixed schedule, the way the Studio's producer works today.
-- treat, write, fix until the gate passes (3 tries), look; if the critic's lowest score is under 3,
-- revise once from its notes, fix again, look again. No decider, no rows.
local M = {}

function M.run(work, o)
  local steps, budget = 0, o.budget
  local function go(verb)
    if steps >= budget then return nil end
    steps = steps + 1
    local outcome, note = work[verb](work)
    work:say(("step %d: %s -> %s %s"):format(steps, verb, outcome, note or ""))
    return outcome
  end
  local function build()
    for _ = 1, 3 do
      if work.gate and work.gate.pass then break end
      if not go("fix") then break end
    end
  end
  go("treat")
  go("write")
  build()
  if work.gate and work.gate.pass then
    go("look")
    if work.scores and work.scores.low < 3 then
      go("write")
      build()
      if work.gate and work.gate.pass then go("look") end
    end
  end
  return { steps = steps, ended = steps >= budget and "budget" or "answered", decisions = {} }
end

return M
