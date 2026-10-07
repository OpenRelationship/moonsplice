-- Games: a composition that is a pure function of t *and its input log* (.robot/docs/canon.robot, amendment
-- 2026-10-06). Host-free like the rest of core/moonsplice: the host injects what it has (a
-- physics world, through `host.physics`) and the input log.
--
--   e.comp {
--     width = 1280, height = 720, duration = 30, fps = 60,
--     game = {
--       rate = 60,                                  -- simulation steps a second
--       init = function(state, g) ... end,          -- once, before step 1
--       step = function(state, input, g) ... end,   -- every step: the only place state changes
--       script = { {t = 1.0, down = "right"}, {t = 2.5, up = "right"} },  -- plays itself with no log
--     },
--     scene = function(s)
--       local ship = s:circle { r = 20, color = "#fff" }
--       s:view(function(state, t) ship:set { x = state.x, y = state.y } end)
--     end,
--   }
--
-- `input` each step: `held[key]`, `pressed[key]` (went down this step), `released[key]`,
-- `pointer = {x, y, down}`, `events` (this step's raw events). `g`: `dt`, `n` (the step), `t`,
-- `random()` / `random(a, b)` seeded per game, `physics{gravity}` (a world from the host).
--
-- The log is a list of events {t, down = key} | {t, up = key} | {t, x, y} | {t, x, y, press}
-- | {t, x, y, release}. An event at time t applies at the first step at or after t, so a log
-- replays onto the same steps at any frame rate. Going backwards replays from the start.

local G = {}
G.__index = G

local function copy_log(log)
  local out = {}
  for i, e in ipairs(log or {}) do
    local c = {}
    for k, v in pairs(e) do c[k] = v end
    c._i = i
    out[i] = c
  end
  table.sort(out, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return a._i < b._i
  end)
  return out
end

function G.new(def, host)
  assert(type(def) == "table", "moonsplice: game{} takes a table")
  assert(type(def.step) == "function", "moonsplice: game.step(state, input, g) required")
  local rate = def.rate or 60
  assert(type(rate) == "number" and rate > 0, "moonsplice: game.rate must be a number > 0")
  local self = setmetatable({
    def = def, rate = rate, host = host or {},
    log = copy_log(def.script), scripted = def.script ~= nil,
    views = {},
  }, G)
  self:reset()
  return self
end

-- The log this game folds. A recorded or live log replaces the script.
function G:set_log(log)
  self.log = copy_log(log)
  self.scripted = false
  self:reset()
end

-- One more event, live. It must not be earlier than the step already taken.
function G:push(e)
  local c = {}
  for k, v in pairs(e) do c[k] = v end
  c.t = math.max(c.t or 0, self.n / self.rate)
  c._i = #self.log + 1
  self.log[#self.log + 1] = c
  if self.scripted then
    self.scripted = false
  end
end

function G:reset()
  self.n, self.cursor = 0, 1
  self.held, self.pointer = {}, { x = 0, y = 0, down = false }
  self.state = {}
  local seed = self.def.seed or 1
  local rng = seed % 2147483647
  if rng <= 0 then rng = rng + 2147483646 end
  local host = self.host
  local g = { dt = 1 / self.rate, n = 0, t = 0 }
  function g.random(a, b)
    rng = (rng * 16807) % 2147483647 -- Park-Miller: the same numbers on every VM
    local u = (rng - 1) / 2147483646
    if a == nil then return u end
    if b == nil then a, b = 1, a end
    return a + math.floor(u * (b - a + 1))
  end
  function g.physics(opts)
    assert(host.physics, "moonsplice: this host has no physics (run it on moonsplice-engine)")
    return host.physics(opts)
  end
  self.g = g
  if self.def.init then self.def.init(self.state, g) end
end

local function apply(self, e, input)
  if e.down then
    if not self.held[e.down] then input.pressed[e.down] = true end
    self.held[e.down] = true
  elseif e.up then
    self.held[e.up] = nil
    input.released[e.up] = true
  end
  if e.x then self.pointer.x, self.pointer.y = e.x, e.y end
  if e.press then self.pointer.down = true; input.pressed.pointer = true end
  if e.release then self.pointer.down = false; input.released.pointer = true end
  input.events[#input.events + 1] = e
end

function G:step_once()
  self.n = self.n + 1
  local t = self.n / self.rate
  local input = { held = self.held, pressed = {}, released = {}, pointer = self.pointer, events = {} }
  while self.cursor <= #self.log and self.log[self.cursor].t <= t + 1e-9 do
    apply(self, self.log[self.cursor], input)
    self.cursor = self.cursor + 1
  end
  self.g.n, self.g.t = self.n, t
  self.def.step(self.state, input, self.g)
end

-- Bring the state to time t: the step floor(t * rate).
function G:advance(t)
  local want = math.max(0, math.floor(t * self.rate + 1e-9))
  if want < self.n then self:reset() end
  while self.n < want do self:step_once() end
  return self.state
end

-- The log as recorded so far, for saving a played session.
function G:recorded()
  local out = {}
  for i, e in ipairs(self.log) do
    local c = {}
    for k, v in pairs(e) do if k ~= "_i" then c[k] = v end end
    out[i] = c
  end
  return out
end

return G
