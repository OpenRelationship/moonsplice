-- The port's keywords: read the Cadence tree at one commit, place every file by manifest.lua, rewrite paths
-- (rewrite.lua), turn markdown into Robot docs (mdrobot.lua), and measure what is left to split (splits.lua).
-- Nothing is read from Cadence's working tree: every byte comes from `git show <commit>:<path>`.
--
--   port.library(root) -> robot library      root is the Moonsplice checkout the port writes into
local robot = require("robot")
local manifest = require("manifest")
local rewrite = require("rewrite")
local mdrobot = require("mdrobot")
local outline = require("outline")
local splits = require("splits")
local laws = require("laws")

local M = {}

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function sh(cmd)
  local p = assert(io.popen(cmd .. " 2>&1; echo \"@rc $?\""))
  local s = p:read("*a"); p:close()
  local out, code = s:match("^(.-)@rc (%d+)%s*$")
  return out or s, tonumber(code) or 1
end

local function lines_of(s)
  local out = {}
  for l in s:gmatch("[^\n]+") do out[#out + 1] = l end
  return out
end

local function count_lines(s)
  local n = select(2, s:gsub("\n", ""))
  if #s > 0 and s:sub(-1) ~= "\n" then n = n + 1 end
  return n
end

local function mkdir_for(path) sh("mkdir -p " .. q(path:match("^(.*)/[^/]+$") or ".")) end

local function write(path, text)
  mkdir_for(path)
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

function M.library(root)
  local lib = robot.library()
  local st = { src = manifest.source, commit = nil, files = nil, plan = nil }
  local staged   -- every ported text after rewriting, in memory, for st.commit

  -- binaries go straight from git to the file, never through a Lua string
  local function blob_to(path, dest)
    mkdir_for(dest)
    local _, code = sh(("git -C %s show %s:%s > %s"):format(q(st.src), st.commit, q(path), q(dest)))
    assert(code == 0, "git show failed for " .. path)
  end
  local function text_of(path)
    local p = assert(io.popen(("git -C %s show %s:%s"):format(q(st.src), st.commit, q(path))))
    local s = p:read("*a"); p:close()
    return s
  end

  local function need_plan()
    assert(st.plan, "Use Source first")
    return st.plan
  end

  lib:add("Use Source", function(commit)
    commit = (commit == nil or commit == "" or commit == "HEAD") and "HEAD" or commit
    local id, code = sh(("git -C %s rev-parse --short %s"):format(q(st.src), q(commit)))
    assert(code == 0, "no commit " .. commit .. " in " .. st.src)
    id = id:gsub("%s+", "")
    if st.commit == id then return id end
    st.commit, staged = id, nil
    st.files = lines_of((sh(("git -C %s ls-tree -r --name-only %s"):format(q(st.src), st.commit))))
    st.plan = {}
    for _, path in ipairs(st.files) do st.plan[#st.plan + 1] = { path = path, m = manifest.match(path) } end
    print(("  source %s at %s: %d files"):format(st.src, st.commit, #st.files))
    return st.commit
  end)

  -- tracked changes, or untracked files outside parked and dropped areas, mean the commit is not the tree
  -- carried = "yes": uncommitted work stays with whoever is doing it, who carries it over; it is listed, not lost
  lib:add("Source Is Committed", function(carried)
    need_plan()
    local out = sh(("git -C %s status --porcelain"):format(q(st.src)))
    local bad = {}
    for _, l in ipairs(lines_of(out)) do
      local path = l:sub(4)
      local m = manifest.match(path)
      if not (m and (m.act == "park" or m.act == "drop")) then bad[#bad + 1] = l end
    end
    if #bad > 0 and carried == "yes" then
      print(("  %d changes not in %s, carried over by their owners:\n    %s"):format(#bad, st.commit,
        table.concat(bad, "\n    ")))
    elseif #bad > 0 then
      error(("%d changes in %s are not in %s; commit them first:\n  %s"):format(#bad, st.src, st.commit,
        table.concat(bad, "\n  ")), 0)
    end
  end)

  lib:add("Every File Has A Rule", function()
    local miss = {}
    for _, f in ipairs(need_plan()) do if not f.m then miss[#miss + 1] = f.path end end
    if #miss > 0 then error(#miss .. " files no rule places:\n  " .. table.concat(miss, "\n  "), 0) end
  end)

  lib:add("No Two Files Land On One Path", function()
    local seen, dup = {}, {}
    for _, f in ipairs(need_plan()) do
      local m = f.m
      if m and m.to then
        local prev = seen[m.to]
        -- several pages may share one doc only through one rule written for that (examples/*.md, evals/*.md)
        if prev and not (m.act == "doc" and prev.rule == m.rule and not m.to:find("%%")) then
          dup[#dup + 1] = prev.path .. " and " .. f.path .. " -> " .. m.to
        end
        seen[m.to] = { path = f.path, rule = m.rule }
      end
    end
    if #dup > 0 then error(table.concat(dup, "\n"), 0) end
  end)

  lib:add("Every Rule Is Used", function()
    local used = {}
    for _, f in ipairs(need_plan()) do if f.m then used[f.m.rule] = true end end
    local idle = {}
    for i, r in ipairs(manifest.rules) do if not used[i] then idle[#idle + 1] = r[1] end end
    if #idle > 0 then print("  rules matching nothing at this commit: " .. table.concat(idle, "  ")) end
  end)

  lib:add("Plan Counts", function()
    local n = {}
    for _, f in ipairs(need_plan()) do local a = f.m and f.m.act or "unplaced"; n[a] = (n[a] or 0) + 1 end
    local keys = {}
    for k in pairs(n) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. n[k] end
    print("  " .. table.concat(parts, "  "))
    return n
  end)

  -- { [to] = { from, text, lines, leftovers } }
  local function stage()
    if staged then return staged end
    staged = {}
    for _, f in ipairs(need_plan()) do
      if f.m and f.m.act == "port" then
        local text = rewrite.text(text_of(f.path), f.m.to)
        staged[f.m.to] = { from = f.path, text = text, lines = count_lines(text), leftovers = rewrite.leftovers(text) }
      end
    end
    return staged
  end

  -- docs grouped by target, in source order, converted
  local function docs()
    local groups, order = {}, {}
    for _, f in ipairs(need_plan()) do
      if f.m and f.m.act == "doc" then
        if not groups[f.m.to] then groups[f.m.to] = {}; order[#order + 1] = f.m.to end
        local g = groups[f.m.to]
        g[#g + 1] = { path = f.path, text = rewrite.text(text_of(f.path), f.m.to) }
      end
    end
    local out = {}
    for _, to in ipairs(order) do
      for _, part in ipairs(mdrobot.convert(groups[to], "cadence@" .. st.commit)) do
        out[#out + 1] = { to = to:gsub("%.robot$", part.name .. ".robot"), text = part.text, n = #groups[to] }
      end
    end
    return out
  end

  lib:add("Docs Parse As Robot", function()
    local bad = {}
    for _, d in ipairs(docs()) do
      local ok, suite = pcall(robot.parse, d.text)
      if not ok or #suite.tests == 0 and not d.text:find("Documentation") then bad[#bad + 1] = d.to end
      if count_lines(d.text) > laws.limit then bad[#bad + 1] = d.to .. " is over the limit" end
    end
    if #bad > 0 then error(table.concat(bad, "\n"), 0) end
    print(("  %d doc files"):format(#docs()))
  end)

  lib:add("Leftover References", function()
    local rows = {}
    for to, s in pairs(stage()) do
      if #s.leftovers > 0 then rows[#rows + 1] = ("%s: %s"):format(to, table.concat(s.leftovers, ", ")) end
    end
    table.sort(rows)
    print(("  %d ported files still name an old path (a hand fix each)"):format(#rows))
    for _, r in ipairs(rows) do print("    " .. r) end
    return #rows
  end)

  -- ported code files over the limit: each must have a plan in splits.lua
  local function oversized()
    local out = {}
    for to, s in pairs(stage()) do
      if laws.counts(to) and s.lines > laws.limit then out[#out + 1] = { to = to, from = s.from, lines = s.lines } end
    end
    table.sort(out, function(a, b) return a.lines > b.lines end)
    return out
  end

  lib:add("Every Oversized File Has A Split Plan", function()
    local miss = {}
    for _, o in ipairs(oversized()) do
      if not splits[o.to] then miss[#miss + 1] = ("%s (%d lines, from %s)"):format(o.to, o.lines, o.from) end
    end
    print(("  %d ported files over %d lines"):format(#oversized(), laws.limit))
    if #miss > 0 then error(#miss .. " oversized files have no split plan:\n  " .. table.concat(miss, "\n  "), 0) end
  end)

  lib:add("Every Split Plan Fits", function()
    local bad = {}
    local all = stage()
    for to, plan in pairs(splits) do
      local s = all[to]
      if not s then bad[#bad + 1] = to .. ": no such ported file"
      else
        local sizes, used = outline.measure(s.text, to:match("%.(%w+)$"), plan)
        for path, n in pairs(sizes) do
          if n > laws.limit then bad[#bad + 1] = ("%s -> %s: %d lines"):format(to, path, n) end
        end
        for p, hit in pairs(used) do if not hit then bad[#bad + 1] = ("%s: pattern %q claims nothing"):format(to, p) end end
      end
    end
    table.sort(bad)
    if #bad > 0 then error(#bad .. " split plans do not fit:\n  " .. table.concat(bad, "\n  "), 0) end
  end)

  lib:add("Show Split Sizes", function()
    local all, keys = stage(), {}
    for to in pairs(splits) do keys[#keys + 1] = to end
    table.sort(keys)
    for _, to in ipairs(keys) do
      local s = all[to]
      if s then
        local sizes = outline.measure(s.text, to:match("%.(%w+)$"), splits[to])
        local parts = {}
        for path, n in pairs(sizes) do parts[#parts + 1] = ("%s %d"):format(path:match("[^/]+$"), n) end
        table.sort(parts)
        print(("  %s (%d): %s"):format(to, s.lines, table.concat(parts, ", ")))
      end
    end
  end)

  lib:add("Placement Should Be", function(path, act, to)
    local m = manifest.match(path)
    if not m then error(path .. " has no rule", 0) end
    if m.act ~= act then error(("%s: %s, not %s"):format(path, m.act, act), 0) end
    if to and to ~= "" and m.to ~= to then error(("%s goes to %s, not %s"):format(path, tostring(m.to), to), 0) end
  end)

  lib:add("Outline", function(to)
    local s = stage()[to]
    assert(s, "not a ported file: " .. to)
    print(outline.show(to, s.text))
  end)

  -- apply: write every placed file into root. Never runs in the dry run (the tasks, not the tests).
  lib:add("Write Ported Files", function()
    local n = 0
    for _, f in ipairs(need_plan()) do
      local m = f.m
      if m and m.act == "copy" then blob_to(f.path, root .. "/" .. m.to); n = n + 1 end
    end
    for to, s in pairs(stage()) do write(root .. "/" .. to, s.text); n = n + 1 end
    for _, d in ipairs(docs()) do write(root .. "/" .. d.to, d.text); n = n + 1 end
    print(("  wrote %d files into %s"):format(n, root))
  end)

  lib:add("Write The Port Record", function()
    local out = { "# what the port did with every Cadence file at " .. st.commit .. ": path<TAB>act<TAB>to<TAB>why" }
    for _, f in ipairs(need_plan()) do
      local m = f.m or {}
      out[#out + 1] = table.concat({ f.path, m.act or "?", m.to or "", m.why or "" }, "\t")
    end
    write(root .. "/.robot/port/record.tsv", table.concat(out, "\n") .. "\n")
  end)

  lib:add("Rewrites Left To Write", function()
    local out = {}
    for _, f in ipairs(need_plan()) do
      if f.m and f.m.act == "rewrite" then out[#out + 1] = ("%s -> %s"):format(f.path, f.m.to) end
    end
    print(("  %d files to rewrite in Lua or Robot, from the Cadence file as reference:"):format(#out))
    for _, l in ipairs(out) do print("    " .. l) end
  end)

  return lib
end

return M
