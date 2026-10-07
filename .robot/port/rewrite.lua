-- The text rewrites a ported file gets: old paths to new ones, in comments, strings and code alike. A path is only
-- rewritten where it starts (the character before it is not part of a path), so `core/runtime/` is never rewritten
-- again as `runtime/`, and a rule's replacement can hold its own pattern.
--
--   rewrite.text(text, path) -> text, n     path is the file's new path; n counts the rewrites made
--   rewrite.leftovers(text) -> { old, ... }   old paths still in the text after rewriting (the port reports them)
local M = {}

-- { old, new } in order: a longer old path sits above any prefix of it
M.paths = {
  { "app/studio/", "editor/" },
  { "lib/moonsplice/", "core/moonsplice/" },
  { "lib/moonsplice", "core/moonsplice" },
  { "engine/lua/", "core/runtime/" },
  { "agent/REFERENCE.md", ".robot/docs/reference.robot" },
  { "agent/runs/", ".robot/runs/agent/" },
  { "agent/", "core/host/" },
  { "runtime/", "core/runtime/" },
  { "evals/cases/", "comps/cases/" },
  { "evals/assets/", "comps/assets/" },
  { "evals/golden/", ".robot/golden/" },
  { "evals/film/", "comps/film/" },
  { "evals/projects/", "comps/projects/" },
  { "evals/manifest.json", ".robot/eval/manifest.json" },
  { "evals/assets.json", ".robot/eval/assets.json" },
  { "examples/", "comps/examples/" },
  { "tests/fixtures/", ".robot/fixtures/" },
  { "tests/lint/", ".robot/fixtures/lint/" },
  { "native/release/", "native/target/release/" },
  { "target/release/", "native/target/release/" },
  { "tools/apple/", "native/apple/" },
  { "bin/build-native", "moonsplice build" },
  { "bin/golden", "moonsplice golden" },
  { "bin/eval", "moonsplice eval" },
  { "bin/moonsplice-agent", "moonsplice agent" },
  { "bin/moonsplice-", "bin/moonsplice-" },   -- the parked wrappers keep their name, so leftovers lists them
  { "bin/moonsplice", "moonsplice" },
  { "DESIGN.md", ".robot/docs/design.robot" },
  { "CHECKS.md", ".robot/docs/checks.robot" },
  { "INTEGRATIONS.md", ".robot/docs/integrations.robot" },
  { "CLAUDE.md", ".robot/docs/agents.robot" },
  { "~/tablua/", "tablua/" },
}

-- docs/NAME.md -> .robot/docs/name.robot, for every page under docs/
M.patterns = {
  { "docs/([%w_]+)%.md", function(name) return ".robot/docs/" .. name:lower():gsub("_", "-") .. ".robot" end },
}

-- rewrites only for files of one kind: Rust names the runtime folder in strings and loads the engine's Lua
M.by_ext = {
  rs = {
    { 'include_str!("../lua/', 'include_str!("../../../core/runtime/' },
    { '.join("runtime")', '.join("core").join("runtime")' },
    { 'PathBuf::from("runtime")', 'PathBuf::from("core/runtime")' },
  },
  lua = {
    { '"/lib/?.lua;"', '"/core/?.lua;"' },
    { '"/lib/?/init.lua;"', '"/core/?/init.lua;"' },
  },
}

-- rewrites for one file, by its new path: what the dropped parts leave behind in it
M.by_path = {
  ["editor/src-tauri/Cargo.toml"] = {
    { 'path = "../../../engine"', 'path = "../../native/engine"' },
  },
  ["native/Cargo.toml"] = {
    { '"model", ', "" },
    { 'exclude = ["spikes/blitz_spike", "spikes/vello_spike"]\n', "" },
  },
}

local PATHCHAR = "[%w_%./%-]"

local function plain(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

-- replace old with new wherever old starts a path; returns text, count
local function at_start(text, old, new)
  local out, n, at = {}, 0, 1
  local pat = plain(old)
  while true do
    local s, e = text:find(pat, at)
    if not s then break end
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    out[#out + 1] = text:sub(at, s - 1)
    if before ~= "" and before:find(PATHCHAR) then out[#out + 1] = old
    else out[#out + 1] = new; n = n + 1 end
    at = e + 1
  end
  out[#out + 1] = text:sub(at)
  return table.concat(out), n
end

local function literal(text, old, new)
  local n = 0
  local s = text:gsub(plain(old), function() n = n + 1; return new end)
  return s, n
end

function M.text(text, path)
  local total = 0
  local ext = path:match("%.(%w+)$") or ""
  for _, r in ipairs(M.by_path[path] or {}) do
    local n
    text, n = literal(text, r[1], r[2]); total = total + n
  end
  for _, r in ipairs(M.by_ext[ext] or {}) do
    local n
    text, n = literal(text, r[1], r[2]); total = total + n
  end
  -- every old path becomes a token first, so no rule rewrites another rule's output
  local tokens = {}
  for i, r in ipairs(M.paths) do
    local n
    text, n = at_start(text, r[1], "\1" .. i .. "\2"); total = total + n
    tokens[i] = r[2]
  end
  for _, p in ipairs(M.patterns) do
    local n
    text, n = text:gsub("()" .. p[1], function(pos, name)
      local before = pos > 1 and text:sub(pos - 1, pos - 1) or ""
      if before ~= "" and before:find(PATHCHAR) then return nil end
      return p[2](name)
    end)
    total = total + n
  end
  text = text:gsub("\1(%d+)\2", function(i) return tokens[tonumber(i)] end)
  return text, total
end

-- old paths a ported file still names: the port lists these for a hand fix
M.old = { "lib/moonsplice", "evals/", "bin/", "tests/", "~/cadence", "cadence/", "nomimono", "buck2", "LÖVE fork",
  "packages/malleable", "app/" }

function M.leftovers(text)
  local found = {}
  for _, old in ipairs(M.old) do
    local _, n = at_start(text, old, "")
    if n > 0 then found[#found + 1] = old end
  end
  return found
end

return M
