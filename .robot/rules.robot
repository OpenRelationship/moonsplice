*** Settings ***
Documentation    Moonsplice: games and videos as Lua comps, a comp being a pure function of time (and of the input log,
...    for a game). Tablua, the agent that builds them, is a submodule at submodules/tablua. These are the laws of this
...    repository, each a test over the files git tracks; each submodule keeps its own.
...
...    AGENTS.md states the bet this repository makes and how to work in it; read it first. CLAUDE.md links to it.
...
...    The tree, and nothing else at the root:
...    moonsplice    the launcher: execs core/cli (luajit) or the engine
...    core/    Lua, one folder per area: moonsplice (the authoring API comps call), runtime (the engine's Lua:
...    painter, resolve, render, serve, rows mode), host (Moonsplice as tablua's world: tools, asks, trials), cli
...    (every command)
...    native/    Rust, one cargo workspace (engine, scene, render, play, tabicl, solid, decode, track, layout,
...    embed, cli, scene3d), and native/apple (Swift for VideoToolbox and Vision)
...    editor/    the desktop app: Tauri (src-tauri, its own cargo project) and React (src), driving the engine
...    and tablua
...    comps/    compositions with their media: cases (the eval suite), examples, lessons, film, projects
...    assets/    fonts, brand and shared media
...    test/    run.lua: every core/**/*_test.lua, with tablua's test/spec.lua
...    submodules/    other repositories: tablua (the agent) and connectory (the APIs a comp or agent can call)
...    .robot/    all Robot: these rules, docs/ (every page of documentation), claims/, golden/, fixtures/, eval/,
...    suites/, and port/ (how Cadence came over)
...
...    luajit .robot/run.lua    runs this suite; luajit .robot/run.lua docs/design runs a doc page
Metadata    Limit    400 lines

*** Test Cases ***
Every File Is Within The Limit
    [Documentation]    No code, config or Robot file is over 400 lines: split by responsibility, never by line count.
    ...    Data (fixtures, goldens, JSON, cargo's lock) and media are exempt (laws.lua lists the kinds).
    [Tags]    law
    Every File Is Within The Limit

There Is No Markdown But AGENTS.md
    [Documentation]    Documentation is Robot: a page is a suite whose sections are test cases tagged doc, each
    ...    made checkable when it can be. AGENTS.md is the one exception (CLAUDE.md is a link to it), and the one file
    ...    exempt from the limit: the bet and the practical knowledge every agent reads whole (owner, 2026-10-07).
    ...    README.md is GitHub's front page for people: it introduces Moonsplice and links to the docs, and
    ...    documents nothing of its own.
    [Tags]    law
    No Markdown

The Root Is The Tree Above
    [Tags]    law
    Root Holds Only    moonsplice    core    native    editor    comps    assets    test    submodules    .robot
    ...    .claude    .gitignore    .gitmodules    LICENSE    AGENTS.md    CLAUDE.md    README.md

Robot Lives In .robot
    [Tags]    law
    Robot Lives In .robot

Core Is At Most Three Folders Deep
    [Documentation]    core/area/module.lua, or core/area/module/part.lua for a module cut in three or more.
    ...    native/ follows cargo's layout, and comps/ and assets/ keep their media's own folders.
    [Tags]    law
    Folders Are At Most 3 Deep

Lua Is Most Of The Code
    [Documentation]    Lua is the language; Rust is the engine's host, rasterizer and models, Swift reaches Apple's
    ...    frameworks. editor/ (TypeScript and Rust) is counted apart. Kill: Lua under 60% of the lines of code
    ...    outside editor/ once the port is done.
    [Tags]    law
    ${share}=    Lua Share Of Code
    Should Be True    ${share} >= 0.6
