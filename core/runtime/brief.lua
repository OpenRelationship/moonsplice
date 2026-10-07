-- Part of rowsmode (core/runtime/rowsmode.lua): see its head for the module's contract.
local M = require("rowsmode")
local R, q, findings_of, findings = M._.R, M._.q, M._.findings_of, M._.findings

function M._.brief(comp, rows, path)
  local lint = require("moonsplice.lint")
  local fs = lint.run(comp, { fps = comp.fps or 30 })
  -- and check's, measured on rendered frames (contrast, overflow): about a second, and the writer
  -- reads no other findings
  local checked = 0
  if path then
    local ok, more = pcall(findings_of, path, "check")
    if ok then
      for _, f in ipairs(more) do
        f.node = f.node or (f.id ~= "" and f.id or nil)
        fs[#fs + 1] = f
        checked = checked + 1
      end
    end
  end
  local o = {}
  local function w(x) o[#o + 1] = x end
  local function val(v)
    if type(v) == "string" then
      if v:match("^/.+/[^/]+$") then v = v:match("([^/]+)$") end
      return ("%q"):format(#v > 60 and (v:sub(1, 57) .. "...") or v)
    elseif type(v) == "number" then return (("%.4g"):format(v))
    elseif type(v) == "table" then local j = R.json(v); return #j > 60 and (j:sub(1, 57) .. "...") or j end
    return tostring(v)
  end
  local facts = {}
  for _, f in ipairs(comp.derived or {}) do
    if (f.t0 or 0) <= comp.duration then
      facts[f.pred] = facts[f.pred] or {}
      table.insert(facts[f.pred], f)
    end
  end
  local function tref(t)
    if type(t) == "number" then return ("%.2fs"):format(t) end
    local ok, v = pcall(R.fact_time, t, comp.derived or {})
    return ok and ("%s(%.2fs)"):format(t, v) or tostring(t)
  end
  w(("comp %dx%d, %gs at %d fps, background %s; digest %s"):format(comp.width, comp.height, comp.duration,
    comp.fps or 30, val(rows.comp.background), M.digest(rows):sub(1, 8)))
  for pred, list in pairs(facts) do
    local parts = {}
    for _, f in ipairs(list) do
      parts[#parts + 1] = (pred == "beat" and (f.args .. "=") or ((f.args or "") .. "@")) .. ("%.2f"):format(f.t0)
    end
    w(("facts %s (asset %s): %s"):format(pred, tostring(list[1].asset), table.concat(parts, " ")))
  end
  for _, a in ipairs(rows.asset) do
    w(("asset %s: %s"):format(a.id, a.solid and "solid" or val(a.src)) .. (a.derive and (" derive " .. val(a.derive)) or ""))
  end
  -- nodes
  local props, keys, motion, setby = {}, {}, {}, {}
  for _, r in ipairs(rows.prop) do props[r.id] = props[r.id] or {}; table.insert(props[r.id], r) end
  local is_row = {}
  for _, n in ipairs(rows.node) do is_row[n.id] = true end
  for _, k in ipairs(rows.key) do
    local c = k.id .. "." .. k.name
    -- a key on a precomp's inner node (<instance>/<child>) is listed under the instance
    local at, name = k.id, k.name
    local inst = not is_row[k.id] and k.id:match("^(.-)/")
    if inst and is_row[inst] then at, name = inst, k.id:sub(#inst + 2) .. "." .. k.name end
    keys[at] = keys[at] or {}
    keys[at][c] = keys[at][c] or { name = name, id = k.id }
    table.insert(keys[at][c], k)
  end
  for _, m in ipairs(rows.motion) do motion[m.id] = motion[m.id] or {}; table.insert(motion[m.id], m) end
  for sys, ids in pairs(comp.access or {}) do
    for id, ps in pairs(ids) do
      setby[id] = setby[id] or {}
      local names = {}
      for p in pairs(ps) do names[#names + 1] = p end
      table.sort(names)
      setby[id][#setby[id] + 1] = sys .. " sets " .. table.concat(names, ",")
    end
  end
  local depth, parent = {}, {}
  for _, n in ipairs(rows.node) do parent[n.id] = n.parent end
  -- composition (core/moonsplice/clip.lua): what each clip plays, and when, in comp time
  local Clip = require("moonsplice.clip")
  local built = {}
  for _, n in ipairs(comp.nodes) do if n.id then built[n.id] = n end end
  local function secs(t) return t == math.huge and "end" or ("%.2fs"):format(t) end
  -- a key time under a clip is local: say when it plays, too
  local function at_comp(node, t)
    if not (node and node.clock) then return "" end
    local lt = t
    if type(t) ~= "number" then
      local ok, v = pcall(R.fact_time, t, comp.derived or {})
      if not ok then return "" end
      lt = v
    end
    local c = Clip.to_comp(comp, node, lt)
    return c and (" (comp %.2fs)"):format(c) or " (never plays)"
  end
  w(comp._clips and "nodes (draw order; children indented; keys under a clip are in its local time):"
    or "nodes (draw order; children indented):")
  for _, n in ipairs(rows.node) do
    local d = n.parent and ((depth[n.parent] or 0) + 1) or 0
    depth[n.id] = d
    local pad = ("  "):rep(d + 1)
    local ps = {}
    for _, r in ipairs(props[n.id] or {}) do ps[#ps + 1] = r.name .. "=" .. val(r.value) end
    w(pad .. n.id .. " " .. n.kind .. (#ps > 0 and (" " .. table.concat(ps, " ")) or ""))
    local b = built[n.id]
    if b and Clip.CLOCKS[b.kind] and b._start then w(pad .. "  " .. Clip.describe(comp, b)) end
    if b and b.kind == "track" and b._members then
      local first = b._members[1]
      w(pad .. ("  track: %d clips end to end from %s to %s; reorder with move_clip, trim with set_prop duration")
        :format(#b._members, first and secs(Clip.to_comp(comp, first, first._start) or 0) or "-",
          b._end and secs(Clip.to_comp(comp, b, b._end) or b._end) or "-"))
    end
    -- curves by prop name: `pairs` order changes from run to run (LuaJIT seeds its string hash)
    local curves = {}
    for _, c in pairs(keys[n.id] or {}) do curves[#curves + 1] = c end
    table.sort(curves, function(a, b) return a.name < b.name end)
    for _, c in ipairs(curves) do
      local parts = {}
      for _, k in ipairs(c) do
        parts[#parts + 1] = val(k.value) .. "@" .. tref(k.t) .. at_comp(built[c.id], k.t) .. (k.ease and (" " .. k.ease) or "")
      end
      w(pad .. "  keys " .. c.name .. ": " .. table.concat(parts, " -> "))
    end
    for _, m in ipairs(motion[n.id] or {}) do
      w(pad .. ("  motion %s %s %s..%s"):format(m.name, m.curve, tref(m.t0), tref(m.t1)))
    end
    for _, line in ipairs(setby[n.id] or {}) do w(pad .. "  " .. line .. " every frame") end
  end
  -- systems
  w("systems (run every frame after the keys, in order):")
  for _, sy in ipairs(rows.system) do
    local spawned = {}
    for id in pairs((comp.spawned or {})[sy.name] or {}) do
      local stem = id:gsub("%d+$", "")
      spawned[stem] = (spawned[stem] or 0) + 1
    end
    local sp = {}
    for stem, c in pairs(spawned) do sp[#sp + 1] = c > 1 and (stem .. "*" .. c) or stem end
    table.sort(sp)
    local ids = {}
    for id in pairs((comp.access or {})[sy.name] or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    w(("  %s (order %s, %d lines)%s%s"):format(sy.name, tostring(sy.order), select(2, sy.source:gsub("\n", "")) + 1,
      #ids > 0 and (": sets " .. table.concat(ids, ", ")) or "",
      #sp > 0 and ("; spawns " .. table.concat(sp, ", ")) or ""))
  end
  -- expectations: the comp's own, then its precomps' (checked in each instance's local time)
  local inner = {}
  for _, x in ipairs(comp.expect or {}) do if x.clock then inner[#inner + 1] = x end end
  if #(rows.expect or {}) > 0 or #inner > 0 then
    local failing = {}
    for _, f in ipairs(fs) do
      if f.code == "expect_failed" then failing[f.detail:match("%(expect ([^)]+)%)$") or ""] = f.detail end
    end
    w("expect (the ask; fixed, no move edits them):")
    for _, x in ipairs(rows.expect) do
      local when = x.at and (" at " .. tostring(x.at))
        or (x.t0 or x.t1) and (" over %s..%s%s"):format(tostring(x.t0 or 0), tostring(x.t1 or "end"), x.holds == "ever" and " (ever)" or "")
        or x.prop and " over the whole piece" or ""
      w(failing[x.id] and ("  FAIL " .. failing[x.id]) or ("  ok   " .. x.id .. when .. ": " .. (x.says or "")))
    end
    for _, x in ipairs(inner) do
      w(failing[x.id] and ("  FAIL " .. failing[x.id]) or ("  ok   " .. x.id .. ": " .. (x.says or "") .. " (precomp)"))
    end
  end
  -- findings: errors, then warnings; info left out
  local errs, warns = {}, {}
  for _, f in ipairs(fs) do
    if f.code ~= "expect_failed" then
      local line = ("  %s %s%s: %s"):format(f.severity, f.code, f.node and (" on " .. f.node) or "", f.detail or "")
      if f.severity == "error" then errs[#errs + 1] = line elseif f.severity == "warn" then warns[#warns + 1] = line end
    end
  end
  w(("findings (lint and check): %d errors, %d warnings"):format(#errs, #warns))
  for _, l in ipairs(errs) do w(l) end
  for _, l in ipairs(warns) do w(l) end
  return table.concat(o, "\n")
end

