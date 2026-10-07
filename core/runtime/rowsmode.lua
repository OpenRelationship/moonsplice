-- `moonsplice rows` and `moonsplice patch` (.robot/docs/rows.robot §6): the comp as rows, and typed
-- patches applied to a comp authored as rows. JSON on stdout and exit 0 whenever the command ran;
-- a rejected patch is data.
local R = require("moonsplice.rows")
local M = {}

local function sha1(s)
  return love.data.encode("string", "hex", love.data.hash("sha1", s))
end

local function root()
  return os.getenv("MOONSPLICE_ROOT")
    or (love.filesystem and love.filesystem.getSource and love.filesystem.getSource():gsub("/core/runtime/?$", "")) or "."
end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- the source text of a function the object API was given (a view), for showing it as a system
local function source_of(fn)
  local info = debug.getinfo(fn, "S")
  if not info or not info.source or info.source:sub(1, 1) ~= "@" then return "-- (no source)" end
  local f = _MOONSPLICE_IOOPEN(info.source:sub(2), "r")
  if not f then return "-- (no source)" end
  local lines, n = {}, 0
  for line in f:lines() do
    n = n + 1
    if n >= info.linedefined and n <= info.lastlinedefined then lines[#lines + 1] = line end
  end
  f:close()
  return table.concat(lines, "\n")
end

local function tables(rows)
  local t = {}
  for _, name in ipairs(R.TABLES) do t[name] = rows[name] end
  t.comp = next(t.comp) and t.comp or setmetatable({}, R.OBJECT)
  t.game = next(t.game) and t.game or setmetatable({}, R.OBJECT)
  return t
end

function M.dump(comp)
  local views = {}
  if not comp.rows then for i, fn in ipairs(comp._views or {}) do views[i] = source_of(fn) end end
  return R.dump(comp, { nodes = comp.nodes, views = views, defaults = require("moonsplice").NODE_DEFAULTS,
    source_of = source_of })
end

function M.digest(rows) return sha1(R.json(tables(rows))) end

-- `moonsplice rows COMP --brief`: the comp as a model should read it. The rows tables are the right
-- form for a sheet and a learner and the wrong one for a language model, which has to join 190 prop rows
-- to know what t4 is. This is one line per node, in draw order with children indented, its keys with
-- fact references resolved, what systems set on it; then the systems by what they write and spawn, the
-- expectations held or failing, and the open errors and warnings. Read from the evaluated comp, so it
-- says what the code does, not what anyone declared.
local findings_of -- below; check's findings for the brief
function M.rows(comp, opts)
  local rows = M.dump(comp)
  if opts.brief then
    if not comp.rows then io.stderr:write("moonsplice rows --brief: the comp is not in rows form\n") return 1 end
    io.write(M._.brief(comp, rows, opts.comp), "\n")
    io.flush()
    return 0
  end
  if opts.out then
    for _, s in ipairs(rows.system) do
      if s.opaque then
        io.stderr:write("moonsplice rows: this comp has code written with the object API (" .. s.name .. "); it holds "
          .. "node handles or draws by hand, so it cannot be written in rows form automatically. Write it as systems.\n")
        return 1
      end
    end
    local f = assert(_MOONSPLICE_IOOPEN(opts.out, "w"))
    f:write(R.lua(rows)); f:close()
  end
  -- derived: facts the assets' derive produced (beats, words), each with its src; not part of the
  -- digest, which covers what was written
  local derived = {}
  for _, f in ipairs(comp.derived or {}) do
    if (f.t0 or 0) <= comp.duration then derived[#derived + 1] = f end -- what the comp's time can reach
  end
  -- solids: each solid asset's measurements (size, volume, parts, watertight), so an agent can check its geometry
  local solids = {}
  for id, m in pairs(comp.solids or {}) do
    local o = {}
    for k, v in pairs(m) do if k ~= "src" then o[k] = v end end
    solids[id] = o
  end
  io.write(R.json({ schema = R.schema, tables = tables(rows), digest = M.digest(rows), derived = derived,
    solids = next(solids) and solids or nil }), "\n")
  io.flush()
  return 0
end

-- the comp file a patch or an expectation is for: its precomps are relative to it
local comp_path

-- a comp built from rows, compiled with no media work and evaluated at three times: what a
-- patch must survive before it lands
local function try(rows)
  local src = R.lua(rows)
  local chunk, err = loadstring(src, "=rows")
  if not chunk then error(err, 0) end
  local comp = chunk()
  -- with the derive step (cached), so keys bound to facts it makes (beats, words) resolve
  -- the same host main.lua gives a comp: a game's world needs the engine's physics
  local E = rawget(_G, "MOONSPLICE_ENGINE")
  comp:compile({ game_host = { physics = E and E.physics_world or nil }, derive = function(src, ops)
    return require("derive").derive(require("resolve").localize(src), ops)
  end, solid = function(tree) return require("solid").build(tree) end,
    load_rows = function(src, from) return require("resolve").precomp_rows(src, from or comp_path) end })
  for _, t in ipairs({ 0, comp.duration / 2, comp.duration * 0.999 }) do comp:evaluate(t) end
  return comp
end

findings_of = function(path, only)
  local out = {}
  for _, tier in ipairs(only and { only } or { "lint", "check" }) do
    local p = assert(_MOONSPLICE_POPEN(("%s/moonsplice %s %s --json 2>&1"):format(q(root()), tier, q(path)), "r"))
    local text = p:read("*a")
    p:close()
    local body = text:match("(%{\"schema\".*%})")
    local ok, doc = pcall(function() return require("moonsplice.json").decode(body) end)
    if ok and doc then
      for _, f in ipairs(doc.findings or {}) do
        out[#out + 1] = { tier = f.tier ~= "" and f.tier or tier, id = f.id or f.node or "", name = f.name or "",
          code = f.code, severity = f.severity, t0 = f.t0, t1 = f.t1, measured = f.measured,
          threshold = f.threshold, detail = f.detail }
      end
    else
      out[#out + 1] = { tier = tier, id = "", name = "", code = "load_error", severity = "error",
        detail = (text:match("moonsplice error: ([^\n]+)") or text:sub(1, 400)) }
    end
  end
  return out
end
local function findings(path) return findings_of(path) end

-- the engine's one line of truth after a call (ROWS.md, "State"): the digest, the open errors by
-- code and node, the warnings counted, the expectations held of their total and which fail. A
-- harness ends every result with it, so the newest message in an append-only transcript is current.
local function key_of(f) return (f.code or "") .. ":" .. ((f.id ~= "" and f.id) or f.node or "") end

function M.state(rows, fs)
  local errs, warns, failing = {}, 0, {}
  local own, held_off = {}, 0
  for _, x in ipairs(rows.expect or {}) do own[x.id] = true end
  for _, f in ipairs(fs) do
    if f.code == "expect_failed" then
      local id = (f.detail or ""):match("%(expect ([^)]+)%)$") or "?"
      failing[#failing + 1] = id
      -- a precomp's own expectation (<instance>/<id>) fails the gate but is not one of this comp's rows
      if own[id] then held_off = held_off + 1 end
    elseif f.severity == "error" then errs[#errs + 1] = f.code .. " " .. ((f.id ~= "" and f.id) or f.node or "")
    elseif f.severity == "warn" then warns = warns + 1 end
  end
  local total = #(rows.expect or {})
  local digest = M.digest(rows)
  local line = ("state: digest %s; errors %d%s; warnings %d; expect %d/%d%s"):format(digest:sub(1, 8), #errs,
    #errs > 0 and (" (" .. table.concat(errs, ", ") .. ")") or "", warns, total - held_off, total,
    #failing > 0 and (" (failing: " .. table.concat(failing, ", ") .. ")") or "")
  return { digest = digest, errors = #errs, warnings = warns, expect_held = total - held_off, expect_total = total,
    failing = failing, line = line }
end

-- what a call changed: findings closed and opened (errors and warnings, by code and node)
function M.delta(before, after)
  local b, a = {}, {}
  for _, f in ipairs(before) do if f.severity ~= "info" then b[key_of(f)] = f end end
  for _, f in ipairs(after) do if f.severity ~= "info" then a[key_of(f)] = f end end
  local closed, opened = {}, {}
  for k, f in pairs(b) do if not a[k] then closed[#closed + 1] = f.code .. " " .. ((f.id ~= "" and f.id) or f.node or "") end end
  for k, f in pairs(a) do if not b[k] then opened[#opened + 1] = f.code .. " " .. ((f.id ~= "" and f.id) or f.node or "") end end
  table.sort(closed); table.sort(opened)
  local line = "delta: " .. ((#closed + #opened == 0) and "nothing closed or opened" or
    (("closed %s | opened %s"):format(#closed > 0 and table.concat(closed, ", ") or "none",
      #opened > 0 and table.concat(opened, ", ") or "none")))
  return { closed = closed, opened = opened, line = line }
end

function M.patch(comp, opts)
  local f = _MOONSPLICE_IOOPEN(opts.patch_file, "r")
  if not f then io.stderr:write("moonsplice patch: cannot read " .. tostring(opts.patch_file) .. "\n") return 1 end
  local ok, patches = pcall(require("moonsplice.json").decode, f:read("*a"))
  f:close()
  if not ok or type(patches) ~= "table" then io.stderr:write("moonsplice patch: the patches are not JSON\n") return 1 end
  if patches.move then patches = { patches } end
  if not comp.rows then
    local rejected = {}
    for i, p in ipairs(patches) do
      rejected[i] = { patch = p, why = "the comp is not in rows form; `moonsplice rows COMP -o NEW.lua` converts one" }
    end
    io.write(R.json({ applied = {}, rejected = rejected, touched = {}, findings = findings(opts.comp) }), "\n")
    return 0
  end
  local rows = R.copy(comp.rows)
  local before = M.digest(rows)
  comp_path = opts.comp
  local res = R.apply(rows, patches, try)
  local after = M.digest(rows)
  -- the findings before, only when something will change (a lint and a check: about a second)
  local fs_before = after ~= before and findings(opts.comp) or nil
  if after ~= before then
    local out = assert(_MOONSPLICE_IOOPEN(opts.comp, "w"))
    out:write(R.lua(rows)); out:close()
  end
  res.digest_before, res.digest_after = before, after
  res.findings = findings(opts.comp)
  res.state = M.state(rows, res.findings)
  res.delta = M.delta(fs_before or res.findings, res.findings)
  io.write(R.json(res), "\n")
  io.flush()
  return 0
end

-- what the parts share, and the parts (they load after this table is registered as rowsmode)
M._ = {
  R = R, sha1 = sha1, root = root, q = q,
  source_of = source_of, tables = tables, try = try, findings_of = findings_of,
  findings = findings, key_of = key_of,
}
package.loaded["rowsmode"] = M
require("brief")
require("expect")

return M
