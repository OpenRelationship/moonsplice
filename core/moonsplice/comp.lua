-- Part of moonsplice (core/moonsplice/init.lua): see its head for the module's contract.
local M = require("moonsplice")
local Timeline, color, Scene = M._.Timeline, M._.color, M._.Scene
local Rec, Comp = M._.Rec, M._.Comp

function M.comp(def)
  assert(type(def) == "table", "moonsplice: comp{} takes a table")
  for _, k in ipairs({ "width", "height", "duration" }) do
    assert(type(def[k]) == "number" and def[k] > 0, "moonsplice: comp." .. k .. " required (number > 0)")
  end
  -- a comp authored as rows (.robot/docs/rows.robot) has nodes/keys/systems in place of a scene function
  local rows
  if def.scene == nil and (def.nodes or def.systems or def.keys) then
    local R = require("moonsplice.rows")
    rows = R.normalize(def)
    def = setmetatable({ scene = R.scene(rows, M), game = R.game(rows, M) }, { __index = def })
  end
  assert(type(def.scene) == "function", "moonsplice: comp.scene required (function), or nodes = {...} (.robot/docs/rows.robot)")
  if def.inputs ~= nil then
    assert(type(def.inputs) == "table", "moonsplice: comp.inputs must be a table")
    for name, spec in pairs(def.inputs) do
      assert(type(name) == "string", "moonsplice: input name must be a string")
      assert(type(spec) == "table", ('moonsplice: input "%s" must be a table'):format(name))
      assert(type(spec.kind) == "string", ('moonsplice: input "%s" needs kind'):format(name))
      if spec.default ~= nil then
        assert(type(spec.default) == "string",
          ('moonsplice: input "%s" default must be a string'):format(name))
      end
    end
  end
  return setmetatable({
    width = def.width, height = def.height,
    duration = def.duration, fps = def.fps or 30,
    background = color.parse(def.background or "#000000"),
    brand = def.brand,           -- optional path to a captured brand.json
    lint_allow = def.lint_allow, -- comp-wide lint escape hatch
    color_space = def.color_space, -- "oklab" (default) | "hsluv" | "okhsl" | "rgb"
    inputs = def.inputs,         -- optional { name = { kind, default? } }
    game_def = def.game,         -- optional: a game (core/moonsplice/game.lua)
    rows = rows,                 -- the comp's rows, when it was authored as rows
    _scene_fn = def.scene,
  }, Comp)
end

-- Compile pass: bind s.input, build scene, execute scripts once, produce
-- timeline. Pure — the host injects a string-path table as `inputs_map`
-- (core/moonsplice never reads disk). hooks.post_scene runs AFTER the scene is
-- built but BEFORE scripts record (layout solving writes x/y there, so tweens
-- see final positions).
-- Merge: def.inputs defaults < inputs_map (host already merged sibling JSON,
-- --inputs file, and --input flags).
function Comp:compile(hooks, inputs_map)
  local bound = {}
  if self.inputs then
    for name, spec in pairs(self.inputs) do
      if spec.default then bound[name] = spec.default end
    end
  end
  if inputs_map then
    for name, path in pairs(inputs_map) do
      if type(path) == "string" then bound[name] = path end
    end
  end
  if self.inputs then
    for name, _ in pairs(self.inputs) do
      if bound[name] == nil then
        error(('moonsplice: input "%s" is not bound'):format(name), 0)
      end
    end
  end
  -- The chunk the scene function came from, so `wrote_at` can tell a line in the composition
  -- from a line in a library the composition called.
  local chunk = nil
  if type(debug) == "table" and type(debug.getinfo) == "function" then
    local info = debug.getinfo(self._scene_fn, "S")
    chunk = info and info.source or nil
  end
  if self.game_def then
    self.game = require("moonsplice.game").new(self.game_def, hooks and hooks.game_host)
  end
  local s = setmetatable(
    { nodes = {}, scripts = {}, count = 0, input = bound, source = chunk, views = {}, game = self.game,
      _derive = hooks and hooks.derive, _solid = hooks and hooks.solid,
      _load_rows = hooks and hooks.load_rows }, Scene)
  self._views = s.views
  self._scene_fn(s)
  self.derived = s.derived -- facts a rows comp's assets produced (core/moonsplice/rows/)
  self.solids = s.solids -- each solid asset's measurements (.robot/docs/solids.robot)
  self.expect = s.expect -- the ask's predicates, times in seconds (lint: expect_failed)
  self.access, self.spawned = s.access, s.spawned -- what each system writes, filled as it runs
  for _, n in ipairs(s.nodes) do
    if n.kind == "flex" then
      local i = n.initial
      i.x, i.y = i.x or 0, i.y or 0
      i.w, i.h = i.w or self.width, i.h or self.height
    end
    if n.kind == "audio" or n.kind == "tts" or n.kind == "sfx" or n.kind == "music" then
      local i = n.initial
      i.at = i.at or 0
      i.media_start = i.media_start or 0
      i.volume = i.volume or 1
      i.fade_in = i.fade_in or 0
      i.fade_out = i.fade_out or 0
      -- narration is the voice bus by default: it is what everything else ducks
      -- under. Opt out with bus = false on a tts node.
      if n.kind == "tts" and i.bus == nil then i.bus = "vo" end
      i.opacity = 0 -- never drawn
    end
    if n.kind == "vector" or n.kind == "html" or n.kind == "group" or n.kind == "fx"
      or n.kind == "particles" or n.kind == "chart" or n.kind == "ornament"
      or n.kind == "spine" or n.kind == "rive" or n.kind == "world"
      or n.kind == "camera" or n.kind == "mesh" or n.kind == "light"
      or n.kind == "clip" or n.kind == "track" or n.kind == "precomp" then
      local i = n.initial
      i.x, i.y = i.x or 0, i.y or 0
      if n.kind == "html" then i.progress = i.progress or 0 end
    end
    if self.color_space and n.initial.color_space == nil then
      n.initial.color_space = self.color_space
    end
    if n.kind == "video" or n.kind == "image" or n.kind == "lottie" or n.kind == "svg"
      or n.kind == "spritesheet" or n.kind == "displace" or n.kind == "rive"
      or n.kind == "page" then
      local i = n.initial
      i.x, i.y = i.x or 0, i.y or 0
      i.w, i.h = i.w or self.width, i.h or self.height
      if n.kind == "video" or n.kind == "lottie" then
        i.from = i.from or 0
        i.duration = i.duration or (self.duration - i.from)
        i.media_start = i.media_start or 0
      end
      if n.kind == "lottie" then
        i.loop = i.loop ~= false
      end
    end
  end
  if hooks and hooks.post_scene then hooks.post_scene(s.nodes, self) end
  local tl = Timeline.new()
  local rec = setmetatable({ cursor = 0, timeline = tl, sim = {} }, Rec)
  for _, fn in ipairs(s.scripts) do fn(rec) end
  if rec.cursor > self.duration + 1e-9 then
    error(("moonsplice: script runs to %.3fs but comp.duration is %.3fs (duration is static)")
      :format(rec.cursor, self.duration), 0)
  end
  self.nodes, self.timeline = s.nodes, tl
  if hooks and hooks.post_script then hooks.post_script(self, rec) end
  for _, n in ipairs(s.nodes) do
    if n.initial.cues then
      -- A cue's t1 only means something if something clears the text at it. Recording
      -- the start alone makes a cue hold until the next one begins, and the last cue
      -- hold to the end of the comp -- so a readout from one chapter stayed on screen
      -- through the next. Contiguous cues are unaffected: the clear is only recorded
      -- when a real gap follows, so nothing that already abutted changes.
      local cues = n.initial.cues
      for i, cue in ipairs(cues) do
        tl:record_step(n, "text", cue.t0, cue.text)
        local nxt = cues[i + 1]
        if cue.t1 and cue.t1 > cue.t0 and (not nxt or nxt.t0 > cue.t1 + 1e-6) then
          tl:record_step(n, "text", cue.t1, "")
        end
      end
    end
  end
  -- clocks, track layout and transitions, now that the keys on clips (speed, time) are recorded
  require("moonsplice.clip").setup(self)
  return self
end

-- Views run after the timeline. With no game their state is an empty table: a view in a video
-- is just a function of t, and what it set is cleared first so frames stay order-free.
local NO_STATE = setmetatable({}, { __newindex = function() error("moonsplice: a view's state is read-only", 2) end })

function Comp:evaluate(t)
  local views = self._views and #self._views > 0
  if self.game or views then M._clear_live() end
  -- every clip's local time first: the timeline evaluates what is under a clip at it
  if self._clips then require("moonsplice.clip").frame(self, t) end
  self.timeline:evaluate(t)
  if self.game or views then
    local state = self.game and self.game:advance(t) or NO_STATE
    for _, v in ipairs(self._views) do v(state, t) end
  end
end

