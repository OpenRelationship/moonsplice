-- The moves on one piece of work, shared by both arms so they differ only in who decides:
-- treat (director), write (builder), fix (builder against the gate), look (render + critic).
-- Each returns an outcome in tablua's words: "complete", "no_effect" or "broken", and a note.
local H = require("host")
local P = require("prompts")
local T = require("tools")
local json = require("ports.json")

local W = {}
W.__index = W

-- ask, kind ("video" | "game"), dir, writer and critic ports
function W.new(o)
  H.mkdir(o.dir)
  return setmetatable({ ask = o.ask, kind = o.kind or "video", dir = o.dir, writer = o.writer, critic = o.critic,
    file = o.dir .. "/comp.lua", version = 0, log = {} }, W)
end

function W:say(s)
  self.log[#self.log + 1] = s
  if os.getenv("MOONSPLICE_AGENT_VERBOSE") then io.stderr:write("  · " .. s .. "\n") end
end

local function call(port, req)
  local ok, text, rec = pcall(port.chat, port, req)
  if not ok then return nil, type(text) == "table" and (text.message or json.encode(text)) or tostring(text) end
  return text, rec
end

function W:treat()
  local text, err = call(self.writer, P.director(self.ask, self.kind))
  if not text then return "broken", "the director failed: " .. tostring(err) end
  self.treatments = text
  self.treatment = P.chosen(text)
  H.write(self.dir .. "/treatment.md", text)
  return "complete", "treatment chosen: " .. self.treatment:sub(1, 160):gsub("\n", " ")
end

-- a new version of the file, gated; progress when the gate's errors fell (or it passes)
function W:take(code, how)
  if not code then return "broken", how .. ": the reply held no Lua" end
  self.version = self.version + 1
  H.write(self.dir .. ("/comp.v%d.lua"):format(self.version), code)
  local before = self.gate
  H.write(self.file, code)
  self.code = code
  self.gate = T.gate(self.file)
  self.critique, self.scores = nil, nil -- a new file has not been looked at
  local g = self.gate
  local note = ("%s v%d: gate %s, %d errors, %d warnings"):format(how, self.version, g.pass and "PASSES" or "fails",
    g.errors, g.warnings)
  if g.crash then note = note .. "; " .. g.crash:sub(1, 200) end
  if g.pass then return "complete", note end
  if before and g.errors < before.errors then return "complete", note end
  return before and "no_effect" or "broken", note
end

function W:write()
  local text, err = call(self.writer, P.write(self.ask, self.kind, self.treatment, self.code, self.critique_text))
  if not text then return "broken", "the builder failed: " .. tostring(err) end
  return self:take(P.code(text), self.critique_text and "revise" or "write")
end

function W:fix()
  if not self.code then return "no_effect", "nothing to fix: no file yet" end
  if self.gate and self.gate.pass then return "no_effect", "the gate already passes" end
  local text, err = call(self.writer, P.fix(self.ask, self.kind, self.treatment, self.code, self.gate or {}))
  if not text then return "broken", "the builder failed: " .. tostring(err) end
  return self:take(P.code(text), "fix")
end

-- render, contact sheet, critic. progress when every score is at least 3.
function W:look(port, tag)
  if not self.code then return "no_effect", "nothing to look at: no file yet" end
  if not (self.gate and self.gate.pass) then return "no_effect", "the gate fails; looking would judge a broken file" end
  local r, err = T.render(self.file, self.dir .. "/" .. (tag or ("look" .. self.version)))
  if not r then
    self.gate.pass = false
    self.gate.findings = { "error render: " .. tostring(err) }
    self.gate.errors = (self.gate.errors or 0) + 1
    return "broken", "render failed: " .. tostring(err):sub(1, 200)
  end
  local text, e2 = call(port or self.critic, P.critic(self.ask, self.kind, self.treatment, T.b64(r.sheet), r.picks))
  if not text then return "broken", "the critic failed: " .. tostring(e2) end
  local ok, doc = pcall(json.decode, text:match("%b{}") or "{}")
  doc = ok and type(doc) == "table" and doc or {}
  local scores, sum, n, low = {}, 0, 0, 5
  for _, k in ipairs(P.rubric_order) do
    local v = tonumber((doc.scores or {})[k])
    if v then scores[k] = v; sum = sum + v; n = n + 1; if v < low then low = v end end
  end
  if n == 0 then return "broken", "the critic gave no scores: " .. text:sub(1, 200) end
  local result = { scores = scores, mean = sum / n, low = low, notes = doc.notes, banned = doc.banned,
    broken = doc.broken, sheet = r.sheet, mp4 = r.mp4 }
  if tag then return result end -- an oracle's look, not the agent's
  self.scores = result
  self.critique_text = ("scores %s; banned: %s; visibly wrong: %s; notes: %s"):format(json.encode(scores),
    json.encode(doc.banned or {}), json.encode(doc.broken or {}), tostring(doc.notes or ""))
  self.looks = (self.looks or 0) + 1
  local best = self.best
  if not best or result.mean > best.mean then
    self.best = { mean = result.mean, version = self.version, code = self.code }
  end
  local note = ("look v%d: mean %.2f, lowest %d; %s"):format(self.version, result.mean, low, tostring(doc.notes or ""):sub(1, 200))
  if low >= 3 then return "complete", note end
  return "no_effect", note
end

-- the share of the seven things a finished piece needs that hold now: the gate, and each of the critic's six
-- scores at 3 or more on the current version (not yet looked at counts as not holding). One meaning, 0..1,
-- for tablua's pass column.
function W:pass()
  local n = (self.gate and self.gate.pass) and 1 or 0
  if self.scores then for _, v in pairs(self.scores.scores) do if v >= 3 then n = n + 1 end end end
  return n / 7
end

-- where the work stands, in words both a decider and a person can read
function W:standing()
  local s = { "Ask (" .. self.kind .. "): " .. self.ask }
  s[#s + 1] = self.treatment and ("Treatment: chosen (" .. self.treatment:sub(1, 220):gsub("\n", " ") .. "...)")
    or "Treatment: none yet."
  if not self.code then
    s[#s + 1] = "File: none yet."
  else
    local g = self.gate
    s[#s + 1] = ("File: version %d, gate %s (%d errors, %d warnings)."):format(self.version, g.pass and "PASSES" or "FAILS",
      g.errors, g.warnings)
    if not g.pass then s[#s + 1] = "Gate findings: " .. table.concat(g.findings, " | "):sub(1, 700) end
  end
  if self.scores then
    s[#s + 1] = ("Critic on this version: mean %.2f, lowest %d. %s"):format(self.scores.mean, self.scores.low,
      tostring(self.scores.notes or ""):sub(1, 400))
  elseif self.code then
    s[#s + 1] = "Critic: has not seen this version."
  end
  if self.best and self.best.version ~= self.version then
    s[#s + 1] = ("Best critic score so far: %.2f on version %d."):format(self.best.mean, self.best.version)
  end
  return table.concat(s, "\n")
end

-- the version to hand in: the best looked-at version that passes, else the current one
function W:final()
  if self.best and not (self.scores and self.scores.mean >= self.best.mean and self.gate.pass) then
    H.write(self.file, self.best.code)
    self.code = self.best.code
    self.gate = T.gate(self.file)
  end
  return self.file
end

return W
