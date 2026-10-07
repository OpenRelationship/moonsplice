-- Moonsplice as a tablua world: tablua's agent (core/agent) decides each move with Jev from the
-- work's standing, and every step goes into tablua's rows (state, candidates, decision, outcome),
-- so what was tried and how it went is a table the studio can query and learn from.
local agent = require("agent")

local M = {}

M.options = {
  treat = "write three treatments (premise, governing rule, grammar, structure) and choose one; do this first, "
    .. "and again only if the critic says the idea itself is weak",
  write = "write the whole composition from the treatment, or revise it from the critic's notes",
  fix = "repair the current file against the gate's lint/check findings (only when the gate fails)",
  look = "render the current file and have the critic score a contact sheet (only when the gate passes)",
  answer = "hand the piece in: the gate passes and the critic's lowest score is 3 or more, or the budget is nearly "
    .. "spent with the best version passing",
}

-- where the work stands, for tablua's rows (stage) and the learner's columns (pass): the stage names the
-- part of the work, and "building" (the gate fails) is where rank mode ranks every decision
function M.stand(work, req)
  req.stage = not work.treatment and "treating" or not (work.gate and work.gate.pass) and "building" or "polishing"
  req.pass = work:pass()
end

function M.new(work, budget)
  local world = { tools = {}, work = work, budget = budget }
  for _, n in ipairs({ "treat", "write", "fix", "look" }) do world.tools[#world.tools + 1] = { name = n, what = M.options[n] } end

  function world.question()
    return { kind = "choice", text = "What should the studio do next?", options = M.options }
  end

  function world.state(a, req)
    local used = #req.steps
    local lines = { work:standing(), ("Steps used: %d of %d."):format(used, budget) }
    local last = req.steps[used]
    if last then lines[#lines + 1] = ("Last step: %s -> %s. %s"):format(last.verb, tostring(last.outcome), last.note or "") end
    return table.concat(lines, "\n")
  end

  function world.think(a, req)
    return { system = "You advise a small studio.", user = world.state(a, req) .. "\nWhat matters most now? Two sentences." }
  end
  function world.ask(a, req) return world.think(a, req) end
  function world.form(written) return { question = written } end

  function world.act(a, req, verb, step)
    local f = work[verb]
    if not f then step.outcome, step.note = "broken", "no such move " .. tostring(verb) return nil end
    local outcome, note = f(work)
    step.outcome, step.note, step.lines = outcome, note, { verb .. ": " .. tostring(note) }
    M.stand(work, req)
    return nil
  end

  -- the moves that make sense now: what rank mode chooses among (checkpoint.before, A:overrule)
  function world.allowed(a, req)
    M.stand(work, req)
    local moves = { "treat", "write" }
    if work.code and not (work.gate and work.gate.pass) then moves[#moves + 1] = "fix" end
    if work.gate and work.gate.pass and not work.scores then moves[#moves + 1] = "look" end
    return moves
  end
  return world
end

-- A minimal memory (tablua's env.memory): keeps the steps so checkpoint.after writes the rows.
local Memory = {}
Memory.__index = Memory
function Memory:begin(text) self.n = (self.n or 0) + 1 return self.prefix .. ":" .. self.n end
function Memory:tokens_today() return 0 end
function Memory:called() end
function Memory:step(todo, row) self.steps = self.steps or {}; self.steps[#self.steps + 1] = row end
function Memory:log() end
function Memory:outcome(todo, label, why) self.ended = label end

-- run the agent until it answers or the budget is spent
function M.run(work, o)
  local world = M.new(work, o.budget)
  local decisions = {}
  local memory = setmetatable({ prefix = o.todo or "ms" }, Memory)
  local learn = o.tablua and require("agent.learn").new{ tabpfn = require("agent.logistic").new(), tablua = o.tablua,
    memory = memory, log = o.log }
  local env = { name = "the studio", jev = o.decider, mercury = o.writer, tablua = o.tablua, memory = memory,
    learn = learn, rank = o.rank,
    decided = function(req, verb, answer, how)
      decisions[#decisions + 1] = { verb = verb, how = how, p = answer and answer.probabilities }
    end,
    log = o.log }
  local a = agent.new(env, world)
  local req = a:begin(work.ask)
  M.stand(work, req)
  local why
  for _ = 1, o.budget do
    local r = a:step(req)
    if r[1] == "done" then why = r[2] or "answered" break end
    local step = r[2]
    work:say(("step %d: %s"):format(#req.steps + 1, step.verb))
    local res = a:perform(req, step)
    if not step.outcome then step.outcome = "no_effect" end
    a:close(req, step)
    if res and res[1] == "done" then why = res[2] break end
  end
  return { steps = #req.steps, ended = why or "budget", decisions = decisions, req = req }
end

return M
