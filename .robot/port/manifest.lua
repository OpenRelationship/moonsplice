-- Where every tracked file of the old Cadence tree goes in Moonsplice. Rules are tried in order and the first whose
-- pattern matches the path wins, so a narrow rule sits above the broad one it carves out of. A path no rule matches
-- fails the port: nothing is left behind by accident.
--
--   { pattern, act, to?, why? }
--     act = "copy"     the file comes over as it is (binary, data), renamed by gsub(pattern, to)
--           "port"     text that comes over and is rewritten (paths, requires: rewrite.lua), renamed the same way
--           "doc"      markdown, converted to Robot documentation (mdrobot.lua) at `to` (a .robot path)
--           "rewrite"  not copied: new Lua is written at `to` by hand, from this file as the reference
--           "park"     stays in the Cadence tree, frozen at the pinned commit; not part of Moonsplice
--           "drop"     superseded; `why` says by what
local M = {}

local DEMOS = "Cadence-era demos and samples, dropped 2026-10-07 at the owner's word: new work starts fresh in the current DSL"

-- the tree the port reads, and the commit it reads it at (git show, never the working tree)
M.source = os.getenv("CADENCE") or ((os.getenv("HOME") or "") .. "/cadence")

M.rules = {
  -- the authoring API, the host runtime and the engine's own Lua
  { "^lib/moonsplice/(.+%.lua)$", "port", "core/moonsplice/%1" },
  { "^runtime/(.+%.lua)$", "port", "core/runtime/%1" },
  { "^engine/lua/(.+%.lua)$", "port", "core/runtime/%1" },

  -- the Moonsplice side of the harness (tablua is the harness, a submodule at tablua/)
  { "^agent/REFERENCE%.md$", "doc", ".robot/docs/reference.robot" },
  { "^agent/runs/(.+)$", "copy", ".robot/runs/agent/%1" },
  { "^agent/(.+%.lua)$", "port", "core/host/%1" },

  -- Rust: one cargo workspace under native/, a crate per folder as before
  { "^Cargo%.toml$", "port", "native/Cargo.toml" },
  { "^Cargo%.lock$", "copy", "native/Cargo.lock" },
  { "^%.cargo/(.+)$", "port", "native/.cargo/%1" },
  { "^(engine/.+)$", "port", "native/%1" },
  { "^(scene/.+%.ttf)$", "copy", "native/%1" },
  { "^tools/apple/(.+)$", "port", "native/apple/%1" },
  { "^submodules/", "drop", why = "nomimono's submodule folder; tablua is at tablua/" },

  -- the editor: the Tauri + React Studio app, its own cargo project and npm package under editor/
  { "^app/AGENTS%.md$", "doc", ".robot/docs/editor.robot" },
  { "^app/studio/agent/editor%.feature$", "rewrite", ".robot/suites/editor.robot",
    why = "Gherkin becomes Robot (no Gherkin, as in tablua); the editor's agent drives tablua, not malleable" },
  { "^app/studio/(.+%.png)$", "copy", "editor/%1" },
  { "^app/studio/(.+%.icns)$", "copy", "editor/%1" },
  { "^app/studio/(.+%.ico)$", "copy", "editor/%1" },
  { "^app/studio/(.+%.lock)$", "copy", "editor/%1" },
  { "^app/studio/(package%-lock%.json)$", "copy", "editor/%1" },
  { "^app/studio/(.+)$", "port", "editor/%1" },

  -- comps travel with their media, so the relative paths inside them hold
  { "^evals/cases/(.+)$", "port", "comps/cases/%1" },
  { "^evals/assets/(.+)$", "copy", "comps/assets/%1" },
  { "^evals/film/", "drop", why = DEMOS },
  { "^evals/projects/", "drop", why = DEMOS },
  { "^examples/", "drop", why = DEMOS },
  { "^comps/lesson/", "drop", why = DEMOS },
  { "^comps/agent/", "drop", why = DEMOS },
  { "^comps/demo/", "drop", why = DEMOS },
  { "^comps/(.+%.lua)$", "port", "comps/%1" },
  { "^comps/(.+)$", "copy", "comps/%1" },

  -- validation: goldens, fixtures, eval manifests and claims all live in .robot/
  { "^evals/golden/(.+)$", "copy", ".robot/golden/%1" },
  { "^evals/(manifest%.json)$", "port", ".robot/eval/%1" },
  { "^evals/(assets%.json)$", "port", ".robot/eval/%1" },
  { "^evals/agent/(.+%.robot)$", "port", ".robot/eval/%1" },
  { "^evals/agent/(fixture%.json)$", "copy", ".robot/eval/%1" },
  { "^evals/agent/(.+)%.md$", "doc", ".robot/docs/eval-agent.robot" },
  { "^evals/agent/.+%.py$", "park" },
  { "^evals/(.+)%.md$", "doc", ".robot/docs/evals.robot" },
  { "^tests/captions_from_words%.lua$", "rewrite", "core/moonsplice/captions_test.lua",
    why = "a test in test/spec.lua's form, beside the module it tests" },
  { "^tests/(fixtures/.+)$", "port", ".robot/%1" },
  { "^tests/(lint/.+)$", "port", ".robot/fixtures/%1" },
  { "^tests/run_p1%.sh$", "rewrite", ".robot/suites/p1.robot", why = "a Robot suite, not a shell script" },
  { "^tests/run_verify%.sh$", "rewrite", ".robot/suites/verify.robot", why = "a Robot suite, not a shell script" },
  { "^tests/(golden/.+)$", "copy", ".robot/%1" },
  { "^tests/PLAN%.md$", "doc", ".robot/docs/tests.robot" },
  { "^%.robot/(claims/.+)$", "port", ".robot/%1" },
  { "^%.robot/(runs/.+)$", "copy", ".robot/%1" },
  { "^%.robot/(ledger%.sqlite)$", "copy", ".robot/%1" },
  { "^%.robot/(mskeywords%.lua)$", "port", ".robot/%1" },
  { "^%.robot/run%.lua$", "port", ".robot/claims.lua" },

  -- every command is one Lua CLI behind the root launcher `moonsplice`
  { "^bin/moonsplice$", "rewrite", "core/cli/init.lua", why = "the launcher, in Lua; ./moonsplice execs it" },
  { "^bin/build%-native$", "rewrite", "core/cli/build.lua" },
  { "^bin/golden$", "rewrite", "core/cli/golden.lua" },
  { "^bin/eval$", "rewrite", "core/cli/eval.lua" },
  { "^bin/lint%-tests$", "rewrite", ".robot/suites/lint.robot", why = "a Robot suite" },
  { "^bin/moonsplice%-agent$", "rewrite", "core/cli/agent.lua" },
  { "^bin/moonsplice%-open$", "rewrite", "core/cli/open.lua" },
  { "^bin/moonsplice%-fetch$", "rewrite", "core/cli/fetch.lua" },
  { "^bin/moonsplice%-transcribe$", "rewrite", "core/cli/transcribe.lua" },
  { "^bin/moonsplice%-capture$", "rewrite", "core/cli/capture.lua" },
  { "^bin/moonsplice%-eval%-agent$", "rewrite", "core/cli/evalagent.lua" },
  { "^bin/studio%-devtools$", "rewrite", "core/cli/devtools.lua",
    why = "vendors tauri-plugin-mcp into editor/.tauri-plugin-mcp (gitignored), which the editor's build needs" },
  { "^bin/", "park", why = "Python, Studio or vision wrappers: their programs are parked" },

  -- every markdown page becomes Robot documentation
  { "^DESIGN%.md$", "doc", ".robot/docs/canon.robot" },
  { "^CHECKS%.md$", "doc", ".robot/docs/checks.robot" },
  { "^INTEGRATIONS%.md$", "doc", ".robot/docs/integrations.robot" },
  { "^README%.md$", "doc", ".robot/docs/readme.robot" },
  { "^CLAUDE%.md$", "doc", ".robot/docs/agents.robot" },
  { "^AGENTS%.md$", "drop", why = "a symlink to .agents/AGENTS.md" },
  { "^%.agents/AGENTS%.md$", "doc", ".robot/docs/agents-repo.robot" },
  { "^docs/media/(.+)$", "copy", "assets/docs/%1" },
  { "^docs/CAPCUT_PARITY%.md$", "doc", ".robot/docs/capcut-parity.robot" },
  { "^docs/(.+)%.md$", "doc", ".robot/docs/%1.robot" },

  -- media
  { "^assets/(.+)$", "copy", "assets/%1" },
  { "^brand/.+%.py$", "park" },
  { "^brand/(.+)$", "copy", "assets/brand/%1" },
  { "^LICENSE$", "copy", "LICENSE" },

  -- parked: not Lua or Rust, and not on Moonsplice's path yet; they stay in the Cadence tree at the pinned commit

  { "^vision/", "park", why = "Python vision MCP; its Lua view (vision/lua) goes with it" },
  { "^cloud/", "park", why = "Python Modal worker" },
  { "^checks/", "park", why = "Python probes" },
  { "^tools/", "park", why = "Python, Node and research scripts" },
  { "^web/", "park", why = "wasmoon preview host" },
  { "^site/", "park", why = "the site is its own project" },
  { "^skills/", "park", why = "vendored agent skills" },
  { "^%.mcp%.json$", "park", why = "registers the parked vision MCP" },

  -- dropped: superseded by this layout
  { "^model/", "drop", why = "the editor-model direction, scrapped 2026-09-16" },
  { "^spikes/", "drop", why = "spikes whose results are in the docs" },
  { "^context/", "drop", why = "nomimono context; plans are Robot now" },
  { "^packages/", "drop", why = "nomimono and malleable submodules" },
  { "^%.gitmodules$", "drop", why = "tablua is the only submodule" },
  { "^%.agents/skills/", "drop", why = "generated nomimono skills" },
  { "^scripts/", "drop", why = "nomimono recipe glue" },
  { "^git/", "drop", why = "nomimono git hooks" },
  { "^library/", "drop", why = "nomimono library page" },
  { "^toolchains/", "drop", why = "buck2" },
  { "^BUCK$", "drop", why = "buck2" },
  { "^%.buck", "drop", why = "buck2" },
  { "^justfile$", "drop", why = "the CLI is core/cli" },
  { "^mono%.toml$", "drop", why = "nomimono" },
  { "^skills%.sh%.json$", "drop", why = "nomimono" },
  { "^%.github/", "drop", why = "CI is rewritten to run .robot" },
  { "^%.claude/", "drop", why = "a new .claude/settings.json loads .robot/rules.robot" },
  { "^%.gitignore$", "drop", why = "written new" },
}

-- the Rust crates, a rule each (Lua patterns have no alternation), placed after the scene font rule above
local crates = { "scene", "render", "play", "tabicl", "solid", "decode", "track", "layout", "embed", "cli", "scene3d" }
local at = 1
for i, r in ipairs(M.rules) do if r[1] == "^(scene/.+%.ttf)$" then at = i end end
for k, crate in ipairs(crates) do
  table.insert(M.rules, at + k, { "^(" .. crate .. "/.+)$", "port", "native/%1" })
end

-- the first rule a path matches: { act, to, why, rule = index } or nil
function M.match(path)
  for i, r in ipairs(M.rules) do
    if path:find(r[1]) then
      local to = r[3]
      if to and to:find("%%%d") then to = path:gsub(r[1], to) end
      -- a doc page's file name is lower case with hyphens: docs/CAPCUT_PARITY.md -> capcut-parity.robot
      if to and r[2] == "doc" then
        to = to:gsub("([^/]+)%.robot$", function(n) return n:lower():gsub("_", "-") .. ".robot" end)
      end
      return { act = r[2], to = to, why = r.why, rule = i }
    end
  end
end

return M
