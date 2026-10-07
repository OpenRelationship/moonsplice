*** Settings ***
Documentation    Agent Instructions
...
...    Read `.robot/docs/agents.robot` for build, test and architecture. Follow-up work is tracked in
...    `.robot/docs/scene.robot` (renderer), `.robot/docs/checks.robot` (lint/check tiers) and `.robot/docs/desktop.robot`
...    (the desktop epic) — no issue tracker.
...
...    This repo is a nomimono consumer (`packages/nomimono`, pinned). `just` is the door;
...    `just check` is the repo-shape gate. The Moonsplice build gates below are separate and
...    still authoritative for renderer work — nomimono does not own the Cargo build yet.
Metadata    Source    cadence@56ddad1:.agents/AGENTS.md

*** Test Cases ***
The door
    [Documentation]    \ \ \ \ just \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ list recipes
    ...    \ \ \ \ just check \ \ \ \ \ \ \ \ \ \ \ doctor + gherkin + buck2 build //... + buck2 test //...
    ...    \ \ \ \ just context \ \ \ \ \ \ \ \ \ projects, features, the junk drawer
    ...    \ \ \ \ just doctor \ \ \ \ \ \ \ \ \ \ required binaries and repo shape
    ...
    ...    Spec-first: work under `context/projects/<p>/features/<f>/`. `bdd/*.feature` is the
    ...    spec and the test suite; `feature.md` is authored context. The desktop epic is the
    ...    `studio` project.
    [Tags]    doc    source:cadence@56ddad1:.agents/AGENTS.md
    Skip    prose

Session completion
    [Documentation]    1. Run the gates: `cargo build --release` + `moonsplice build`, then
    ...    \ \ \ `moonsplice golden compare` (scene path, the default) and `bin/lint-tests`.
    ...    \ \ \ Run `just check` as well when repo shape, toolchains or features changed.
    ...    \ \ \ `MOONSPLICE_SCENE=0 moonsplice golden compare` checks the love fallback and needs the
    ...    \ \ \ vendored LÖVE 12 fork to match (Homebrew 11.5 differs on fonts).
    ...    2. Commit, `git pull --rebase`, `git push`, `git status` must be up to date.
    ...    3. Leave a hand-off note in the commit body: what changed, what is left.
    [Tags]    doc    source:cadence@56ddad1:.agents/AGENTS.md
    Skip    prose

Non-interactive shell commands
    [Documentation]    `cp`, `mv`, `rm` may be aliased to `-i` on some systems and will hang an agent.
    ...    Use `cp -f`, `mv -f`, `rm -f` / `rm -rf`, `ssh -o BatchMode=yes`,
    ...    `HOMEBREW_NO_AUTO_UPDATE=1 brew …`, `apt-get -y`.
    [Tags]    doc    source:cadence@56ddad1:.agents/AGENTS.md
    Skip    prose

