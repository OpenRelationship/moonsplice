-- moonsplice love host. Modes:
--   render  : offline fixed-dt frames -> ffmpeg stdin -> mp4
--   hash    : offline fixed-dt frames -> md5 per frame (determinism/golden tests)
--   preview : realtime looping playback window
--   serve   : long-lived frame + outline server for the desktop app (core/runtime/serve.lua)
-- Usage (via moonsplice): love runtime --render comp.lua -o out.mp4 [--shuffle]

local function parse_args()
  local raw = arg
  if love.arg and love.arg.parseGameArguments then
    raw = love.arg.parseGameArguments(arg)
  end
  local o = { mode = "preview", shuffle = false, input_flags = {} }
  local i = 1
  while i <= #raw do
    local a = raw[i]
    if a == "--render" then o.mode = "render"
    elseif a == "--hash" then o.mode = "hash"
    elseif a == "--preview" then o.mode = "preview"
    elseif a == "--serve" then o.mode = "serve"
    elseif a == "--lint" then o.mode = "lint"
    elseif a == "--check" then o.mode = "check"
    elseif a == "--json" then o.json = true
    elseif a == "--rows" then o.mode = "rows"
    elseif a == "--brief" then o.brief = true
    elseif a == "--patch" then o.mode = "patch"; i = i + 1; o.patch_file = raw[i]
    elseif a == "--expect" then o.mode = "expect"; i = i + 1; o.expect_file = raw[i]
    elseif a == "--gate" then o.mode = "gate"
    elseif a == "--strict" then o.strict = true
    elseif a == "--shuffle" then o.shuffle = true
    elseif a == "-o" or a == "--out" then i = i + 1; o.out = raw[i]
    elseif a == "--fps" then i = i + 1; o.fps = tonumber(raw[i])
    elseif a == "--inputs" then i = i + 1; o.inputs_file = raw[i]
    elseif a == "--input-log" then i = i + 1; o.input_log = raw[i]
    elseif a == "--input" then
      i = i + 1
      local spec = raw[i] or ""
      local key, path = spec:match("^([^=]+)=(.*)$")
      if not key or key == "" then
        error('moonsplice: --input expects KEY=PATH, got ' .. tostring(raw[i]))
      end
      o.input_flags[key] = path
    elseif a:match("%.lua$") then o.comp = a; o.comp_rel = a
    end
    i = i + 1
  end
  if not o.comp then error("moonsplice: no composition file given") end
  if not o.comp:match("^/") then
    o.comp_rel = o.comp_rel or o.comp
    o.comp = (os.getenv("MOONSPLICE_CWD") or os.getenv("PWD") or ".") .. "/" .. o.comp
  else
    o.comp_rel = o.comp_rel or o.comp:match("([^/]+%.lua)$") or o.comp
  end
  return o
end

local function abs_path(p)
  if not p then return p end
  if p:match("^/") then return p end
  return (os.getenv("MOONSPLICE_CWD") or os.getenv("PWD") or ".") .. "/" .. p
end

-- Host-only: read a JSON object of string paths. Missing file → nil (caller decides).
local function read_inputs_json(path)
  if not path then return nil end
  local open = io.open or _MOONSPLICE_IOOPEN
  local f = open(path, "r")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  local doc = require("moonsplice.json").decode(body)
  if type(doc) ~= "table" then
    error("moonsplice: inputs file must be a JSON object: " .. path)
  end
  local map = {}
  for k, v in pairs(doc) do
    if type(k) ~= "string" or type(v) ~= "string" then
      error("moonsplice: inputs JSON values must be string paths: " .. path)
    end
    map[k] = v
  end
  return map
end

local function merge_kv(dst, src)
  if not src then return dst end
  for k, v in pairs(src) do dst[k] = v end
  return dst
end

-- sibling <comp>.inputs.json < --inputs FILE.json < --input KEY=PATH
local function resolve_inputs(opts)
  local map = {}
  local sibling = opts.comp:gsub("%.lua$", ".inputs.json")
  merge_kv(map, read_inputs_json(sibling))
  if opts.inputs_file then
    local p = abs_path(opts.inputs_file)
    local file_map = read_inputs_json(p)
    if not file_map then
      error("moonsplice: inputs file not found: " .. opts.inputs_file)
    end
    merge_kv(map, file_map)
  end
  merge_kv(map, opts.input_flags)
  return map
end

local function load_comp(path, fps_override, host_opts)
  -- lib/ is host-free pure Lua; make require("moonsplice") resolve to it.
  local root = love.filesystem.getSource():gsub("/core/runtime/?$", "")
  package.path = root .. "/core/?.lua;" .. root .. "/core/?/init.lua;" .. package.path

  -- Host reads sidecar / CLI JSON before the sandbox; core/moonsplice never opens files.
  local inputs_map = resolve_inputs(host_opts or { comp = path, input_flags = {} })

  -- Determinism by construction: comps get no clock, no ambient RNG, no io.
  math.randomseed(0)
  love.math.setRandomSeed(0)
  local banned = function(name)
    return function() error("moonsplice: " .. name .. " is banned in compositions (deterministic render)", 2) end
  end
  os.time, os.clock, os.date = banned("os.time"), banned("os.clock"), banned("os.date")
  io.open, io.popen, io.read = banned("io.open"), banned("io.popen"), banned("io.read")

  local chunk, err = loadfile(path)
  if not chunk then
    local e = tostring(err)
    -- Lua allows 200 locals per function and a scene with a few hundred nodes reaches it.
    -- The raw message names an implementation limit, not the thing the author did.
    if e:match("more than 200 local variables") then
      e = e .. "\n  moonsplice: a scene function may hold at most 200 locals. Put the nodes in one"
            .. " table instead -- `local N = {}` then `N.title = s:text{...}` -- which costs"
            .. " nothing and has no limit."
    end
    error("moonsplice: cannot load comp: " .. e)
  end
  local comp = chunk()
  assert(type(comp) == "table" and comp.compile, "moonsplice: comp file must `return e.comp{...}`")
  -- media resolves BEFORE scripts record, so tts/audio durations drive timing;
  -- then layout, so tweens see solved positions
  local resolve = require("resolve")
  local E = rawget(_G, "MOONSPLICE_ENGINE")
  local compiled = comp:compile({
    -- a game's world (core/moonsplice/game.lua): what this host gives it
    game_host = { physics = E and E.physics_world or nil },
    -- s:derive(src, ops): media and facts made before render (core/runtime/derive.lua)
    derive = function(src, ops) return require("derive").derive(resolve.localize(src), ops) end,
    -- s:solid(tree): a solid built by Manifold, cached (core/runtime/solid.lua, .robot/docs/solids.robot)
    solid = function(tree) return require("solid").build(tree) end,
    -- a precomp's rows, read relative to the comp that names it (.robot/docs/rows.robot, "Composition")
    load_rows = function(src, from) return resolve.precomp_rows(src, from or path) end,
    post_scene = function(nodes, c)
      resolve.media(nodes, fps_override or c.fps)
      resolve.layout(nodes)
    end,
    post_script = function(c, rec)
      require("physics_bake").bake(c, rec)
    end,
  }, inputs_map)
  -- a recorded session replaces the game's own script (`--input-log FILE.json`)
  local log_path = host_opts and host_opts.input_log
  if log_path then
    if not compiled.game then error("moonsplice: --input-log needs a game (comp{ game = {...} })", 0) end
    if not log_path:match("^/") then log_path = (os.getenv("MOONSPLICE_CWD") or ".") .. "/" .. log_path end
    local f = assert(_MOONSPLICE_IOOPEN(log_path, "rb"), "moonsplice: cannot read input log " .. log_path)
    local doc = require("moonsplice.json").decode(f:read("*a")); f:close()
    compiled.game:set_log(doc.events or doc)
  end
  return compiled
end

local painter -- required after modules boot, inside love.run
local offline = require("offline")

local function json_escape(s)
  return tostring(s):gsub('["\\\n]', { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n" })
end

local function emit_findings(findings, opts, tier)
  local errs, warns = 0, 0
  for _, f in ipairs(findings) do
    if f.severity == "error" then errs = errs + 1
    elseif f.severity == "warn" then warns = warns + 1 end
  end
  if opts.json then
    local result = require("moonsplice.result")
    local cwd = os.getenv("MOONSPLICE_CWD") or os.getenv("PWD") or "."
    io.write(result.from_findings(findings, {
      comp = opts.comp_rel or opts.comp,
      cwd = cwd,
      strict = opts.strict,
      duration_ms = opts.duration_ms,
    }, tier) .. "\n")
  else
    for _, f in ipairs(findings) do
      io.write(("%-5s %-20s %s%s  %s%s\n"):format(
        f.severity:upper(), f.code,
        f.node and ("[" .. f.node .. "] ") or "",
        f.t0 and ("@%.2f-%.2fs"):format(f.t0, f.t1 or f.t0) or "",
        f.detail or "",
        f.measured and (" (%.2f vs %.2f)"):format(f.measured, f.threshold or 0) or ""))
    end
    io.write(("%s: %d errors, %d warnings, %d findings total\n")
      :format(tier, errs, warns, #findings))
  end
  io.flush()
  if errs > 0 or (opts.strict and warns > 0) then return 1 end
  return 0
end

_MOONSPLICE_EMIT = emit_findings

local function load_brand(comp)
  if not comp.brand then return nil end
  local path = comp.brand
  if not path:match("^/") then path = (os.getenv("MOONSPLICE_CWD") or ".") .. "/" .. path end
  local f = _MOONSPLICE_IOOPEN(path, "r")
  if not f then error("moonsplice: brand file not found: " .. comp.brand) end
  local body = f:read("*a")
  f:close()
  local palette = {}
  for hex in body:gmatch('"#(%x%x%x%x%x%x)"') do palette[#palette + 1] = "#" .. hex end
  return { palette = palette, fonts = true }
end

local function lint_mode(comp, opts)
  local lint = require("moonsplice.lint")
  local painter_mod = require("painter")
  local findings = lint.run(comp, {
    fps = 30,
    brand = load_brand(comp),
    measure_text = function(text, size, fontpath)
      local f = painter_mod.font(size, fontpath)
      return f:getWidth(text), f:getHeight()
    end,
  })
  return emit_findings(findings, opts, "lint")
end

local function preview(comp)
  local sw, sh = 1280, 720
  local scale = math.min(sw / comp.width, sh / comp.height, 1)
  love.window.setMode(comp.width * scale, comp.height * scale, { vsync = 1 })
  love.window.setTitle("moonsplice preview")
  local canvas = love.graphics.newCanvas(comp.width, comp.height)
  local start = love.timer.getTime()
  return function()
    love.event.pump()
    for name, _, _, k in love.event.poll() do
      if name == "quit" or (name == "keypressed" and k == "escape") then return 0 end
    end
    local t = (love.timer.getTime() - start) % comp.duration
    comp:evaluate(t)
    love.graphics.setCanvas({ canvas, stencil = true })
    painter.draw_scene(comp, t)
    love.graphics.setCanvas()
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, 0, 0, 0, scale, scale)
    love.graphics.present()
    love.timer.sleep(0.001)
    return nil
  end
end

-- No blue error screen: offline tools print and exit. (Default handler opens a
-- window and loops forever — hangs CI and any scripted run.)
function love.errorhandler(msg)
  local opts = _G._MOONSPLICE_OPTS
  if opts and opts.json then
    local ok, result = pcall(require, "moonsplice.result")
    if ok then
      local cwd = os.getenv("MOONSPLICE_CWD") or os.getenv("PWD") or "."
      io.stdout:write(result.error_envelope({
        mode = opts.mode or "compile",
        comp = opts.comp_rel or opts.comp,
        cwd = cwd,
      }, msg) .. "\n")
      io.stdout:flush()
      os.exit(1)
    end
  end
  io.stderr:write("moonsplice error: " .. tostring(msg) .. "\n" .. debug.traceback() .. "\n")
  io.stderr:flush()
  os.exit(1)
end

function love.run()
  -- keep private io refs before comp sandbox nukes them (host code needs both)
  _MOONSPLICE_POPEN = io.popen
  _MOONSPLICE_IOOPEN = io.open
  _MOONSPLICE_IOREAD = io.read
  painter = require("painter")
  local resolve = require("resolve")
  local opts = parse_args()
  _G._MOONSPLICE_OPTS = opts
  local comp = load_comp(opts.comp, opts.fps, opts)
  comp.render_fps = opts.fps or comp.fps

  if opts.mode == "preview" then
    return preview(comp)
  end
  if opts.mode == "serve" then
    local code = require("serve").run(comp, opts, painter, load_comp)
    return function() return code end
  end
  if opts.mode == "rows" then
    local code = require("rowsmode").rows(comp, { out = opts.out and abs_path(opts.out), brief = opts.brief,
      comp = opts.comp })
    return function() return code end
  end
  if opts.mode == "patch" then
    opts.patch_file = abs_path(opts.patch_file)
    local code = require("rowsmode").patch(comp, opts)
    return function() return code end
  end
  if opts.mode == "gate" then
    local code = require("rowsmode").gate(comp, opts)
    return function() return code end
  end
  if opts.mode == "expect" then
    opts.expect_file = abs_path(opts.expect_file)
    local code = require("rowsmode").expect(comp, opts)
    return function() return code end
  end
  if opts.mode == "lint" then
    local code = lint_mode(comp, opts)
    return function() return code end
  end
  if opts.mode == "check" then
    local code = require("checkmode").run(comp, opts, painter)
    return function() return code end
  end
  offline(comp, opts)
  return function() return 0 end
end
