-- The host, in Lua: everything the Rust side would otherwise have to say through mlua.
--
-- `agent.rs` hands this file one table of Rust functions and gets back `run(prompt)`. The
-- wiring lives here rather than in Rust because it is *Lua* wiring — six ports and a gate —
-- and because keeping it here means the shape can be read next to the declaration it serves.
--
-- Nothing here names a vendor either: the scheme is a string that arrived from the host, the
-- transport is `wire.fetch`, and `src/provider.lua` owns the rest. Malleable's rule 1 is
-- about its core, but there is no reason for the host to be sloppier than the core is.

local M = {}

-- `wire` is the table Rust fills in:
--
--   wire.fetch(request)      -> { status, headers, body } | nil, message
--   wire.ask(request)        -> { allow = boolean, reason = string } | "yes" | "no" | ...
--   wire.now()               -> seconds since the epoch
--   wire.mono()              -> monotonic seconds
--   wire.log(level, event)   -> nil
--   wire.event(name, json)   -> nil          one turn event, on its way to the UI
--   wire.scheme              -> "openrouter"
--   wire.key                 -> the API key, read from the keyring on the Rust side
--   wire.model               -> an override for the declaration's model, or nil
--   wire.moonsplice             -> the app: outline, at, shows, change, undo, export, repaint
--
-- Everything else — the wire format, retry, the loop, the gate — is malleable's.
function M.build(wire, declaration_path, agent)
  local provider = agent.provider

  local clock = {
    now = function() return wire.now() end,
    mono = function() return wire.mono() end,
    sleep = function() return true end, -- the host never asks a turn to sleep
  }

  local log = {
    write = function(level, event)
      wire.log(tostring(level), tostring(event))
    end,
  }

  local schemes = {}
  schemes[wire.scheme] = { key = wire.key }

  local model, why = provider.model({
    schemes = schemes,
    timeout = tonumber(wire.timeout) or 120,
  }, {
    net = { fetch = function(req) return wire.fetch(req) end },
    json = provider.json,
    clock = clock,
    log = log,
  })
  if not model then
    return nil, (type(why) == "table" and why.message) or tostring(why)
  end

  local ports = {
    model = model,
    clock = clock,
    log = log,
    -- Passed through to every tool body by src/turn.lua. This is the app.
    moonsplice = wire.moonsplice,
  }

  -- Rule 4: the gate is the harness's. `trust = "ask"` means a tool that declared
  -- `ask = true` reaches the person, and nothing else does.
  local gate = agent.gate({
    port = { ask = function(request) return wire.ask(request) end },
    trust = "ask",
  })
  local bound = agent.bind(ports, gate)

  -- Turn events, on their way to the UI. `src/turn.lua` fires five; each one becomes a
  -- chunk the chat surface can draw. Rule 8 holds here too: what crosses is names,
  -- counts and decisions.
  local function send(name, fields)
    wire.event(name, fields)
  end

  agent.on "start" (function(e)
    send("start", { budget = e.budget })
  end)
  agent.on "step" (function(e)
    send("step", { step = e.step, budget = e.budget })
  end)
  agent.on "call" (function(e)
    send("call", { step = e.step, call = e.call, tool = e.tool, ask = e.ask and true or false })
  end)
  agent.on "result" (function(e)
    send("result", {
      call = e.call,
      tool = e.tool,
      ok = e.ok and true or false,
      refused = e.refused and true or false,
      size = type(e.body) == "string" and #e.body or 0,
    })
  end)
  agent.on "stop" (function(e)
    send("stop", { stop = e.stop, reason = e.reason, steps = e.steps })
  end)

  if wire.model and wire.model ~= "" then agent.model(wire.model) end
  -- A host that runs unattended (`moonsplice agent run --budget`) may want a longer leash than
  -- the window's; the declaration's own budget stands when it says nothing.
  if tonumber(wire.budget) then agent.budget(math.floor(tonumber(wire.budget))) end

  -- Counted here rather than read back off the result, because a run that stops on its budget
  -- still made every one of those calls.
  local calls = 0
  agent.on "call" (function() calls = calls + 1 end)

  local _ = declaration_path
  return function(prompt, history)
    local result = agent.run(prompt, bound, { history = history })
    return {
      stop = result.stop,
      reason = result.reason,
      answer = result.answer,
      steps = result.steps,
      notes = result.notes,
      calls = result.calls,
      usage = result.usage,
      tool_calls = calls,
    }
  end
end

return M
