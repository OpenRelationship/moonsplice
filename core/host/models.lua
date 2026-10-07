-- Which model does what, and what it cost. Routing (.robot/docs/capcut-parity.robot: local or MiniMax):
--
--   writer / critic   "m3"               MiniMax M3 through OpenRouter (images in, for the critic)
--                     "minimax:<model>"  MiniMax's own API, e.g. minimax:MiniMax-M3 (key: keychain account "minimax" or MINIMAX_API_KEY)
--                     "local:<model>"    an Ollama model on this machine (OpenAI-compatible, localhost:11434)
--   decider           "jev"              OpenRouter's typed decisions (tablua's ports.jev)
--                     any writer spec    the same model asked for a JSON choice with probabilities
--
-- Every port is wrapped in a meter: calls, seconds, tokens and USD, per role.
local H = require("host")
local json = require("ports.json")

local M = {}

M.meter = { calls = 0, cost = 0, seconds = 0, by = {} }

function M.reset()
  M.meter = { calls = 0, cost = 0, seconds = 0, by = {} }
end

local function metered(role, port, method)
  local f = port[method]
  return function(self, ...)
    local t0 = H.now()
    local a, b = f(port, ...)
    local dt = H.now() - t0
    local m, r = M.meter, (method == "decide" and b or b) or {}
    m.calls, m.seconds = m.calls + 1, m.seconds + dt
    m.cost = m.cost + (tonumber(r.cost) or 0)
    local by = m.by[role] or { calls = 0, cost = 0, seconds = 0 }
    by.calls, by.cost, by.seconds = by.calls + 1, by.cost + (tonumber(r.cost) or 0), by.seconds + dt
    m.by[role] = by
    return a, b
  end
end

-- An Ollama model through tablua's OpenAI-compatible route, thinking off for every call (reasoning_effort
-- "none": a small Qwen otherwise spends every token thinking and answers nothing).
function M.local_port(model)
  local port = require("ports.chat").new(H.net, { key = "ollama", service = "openai", model = model, timeout = 1800,
    url = os.getenv("OLLAMA_URL") or "http://localhost:11434/v1/chat/completions" })
  return { model = model, chat = function(self, req)
    local r = {}
    for k, v in pairs(req) do r[k] = v end
    r.reasoning_effort = "none"
    return port:chat(r)
  end }
end

local function chat_port(spec, opts)
  opts = opts or {}
  if spec == "m3" or spec:match("^openrouter:") then
    local key = H.key("openrouter", "OPENROUTER_API_KEY")
    assert(key, "no OpenRouter key: set OPENROUTER_API_KEY or keychain account openrouter")
    -- no max_tokens anywhere: reasoning counts against it, and a cap is what made M3 answer empty
    -- (tablua's bench: 223 uncapped M3 calls sorted by throughput, none empty, mean 20 s)
    return require("ports.chat").new(H.net, { key = key, model = spec == "m3" and "minimax/minimax-m3"
      or spec:match("^openrouter:(.+)$"), sort = "throughput", timeout = 1800 })
  end
  local mm = spec:match("^minimax:(.+)$")
  if mm then
    local key = H.key("minimax", "MINIMAX_API_KEY")
    assert(key, "no MiniMax key: security add-generic-password -s com.moonsplice.studio -a minimax -w <key>")
    return require("ports.chat").new(H.net, { key = key, service = "minimax", model = mm, timeout = 1800 })
  end
  local lm = spec:match("^local:(.+)$")
  if lm then return M.local_port(lm) end
  error("no model route " .. tostring(spec))
end

-- a writer: chat{ system, user | messages, max_tokens } -> text, record (tablua's chat shape, Mercury's place)
function M.writer(spec, role)
  local port = chat_port(spec)
  return { chat = metered(role or "writer", port, "chat"), spec = spec }
end

-- A decider with Jev's shape, from a chat model: one JSON object, the choice and a probability per option.
local Decider = {}
Decider.__index = Decider

function Decider:decide(state, questions)
  local out, record = {}, { cost = 0 }
  for id, q in pairs(questions) do
    local names = {}
    for name, what in pairs(q.options or {}) do names[#names + 1] = ("- %s: %s"):format(name, what) end
    table.sort(names)
    local text, r = self.port:chat{
      system = "You decide an agent's next move. Reply with one JSON object only: "
        .. '{"choice": "<option name>", "probabilities": {"<option>": <0..1>, ...}} covering every option.',
      user = state .. "\n\n" .. (q.text or "") .. "\nOptions:\n" .. table.concat(names, "\n"),
      json = true, temperature = 0.2 }
    record.cost = record.cost + (tonumber(r.cost) or 0)
    local ok, doc = pcall(json.decode, (text:match("%b{}") or "{}"))
    doc = ok and type(doc) == "table" and doc or {}
    local choice = doc.choice
    if not (q.options or {})[choice or ""] then
      -- an answer outside the options is no answer: take the most probable listed option, or the first
      local best, bp = nil, -1
      for name in pairs(q.options or {}) do
        local p = tonumber((doc.probabilities or {})[name]) or 0
        if p > bp or (p == bp and name < best) then best, bp = name, p end
      end
      choice = best
    end
    out[id] = { choice = choice, probabilities = doc.probabilities or { [choice] = 1 }, confidence = nil }
  end
  return out, record
end

function M.decider(spec)
  if spec == "jev" then
    local key = H.key("openrouter", "OPENROUTER_API_KEY")
    assert(key, "no OpenRouter key for Jev")
    local jev = require("ports.jev").new(H.net, { key = key })
    return { decide = metered("decider", jev, "decide"), spec = spec }
  end
  local d = setmetatable({ port = chat_port(spec) }, Decider)
  return { decide = metered("decider", d, "decide"), spec = spec }
end

return M
