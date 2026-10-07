*** Settings ***
Documentation    What the port decided about each part of Cadence, and why; each decision checked against
...    manifest.lua, so a change to the manifest that breaks one fails here. Run: luajit .robot/run.lua port/decisions
Metadata    Source    ~/cadence at the commit port.robot pins

*** Test Cases ***
The Authoring API And The Runtime Are Core
    [Documentation]    lib/moonsplice is the API comps call; runtime/ is the engine's Lua. Their require names do not
    ...    change: core/ and core/runtime/ are on the engine's package.path.
    Placement Should Be    lib/moonsplice/init.lua    port    core/moonsplice/init.lua
    Placement Should Be    runtime/painter.lua    port    core/runtime/painter.lua
    Placement Should Be    engine/lua/boot.lua    port    core/runtime/boot.lua

Moonsplice's Side Of The Agent Is Core Host
    [Documentation]    agent/ is Moonsplice as tablua's world (its tools, asks and trials). It is named host, as its
    ...    host.lua was, because tablua's own core/agent and core/studio share the module path.
    Placement Should Be    agent/tools.lua    port    core/host/tools.lua

Rust Is One Workspace Under Native
    Placement Should Be    scene/src/lib.rs    port    native/scene/src/lib.rs
    Placement Should Be    engine/src/main.rs    port    native/engine/src/main.rs
    Placement Should Be    Cargo.toml    port    native/Cargo.toml
    Placement Should Be    tools/apple/main.swift    port    native/apple/main.swift

Comps Keep Their Media Beside Them
    [Documentation]    A comp names its media by relative path, so lesson, case and example folders move whole.
    Placement Should Be    evals/cases/bounce.lua    port    comps/cases/bounce.lua
    Placement Should Be    examples/basics/hello.lua    port    comps/examples/basics/hello.lua

Validation Lives In .robot
    Placement Should Be    evals/golden/bounce.scene.md5    copy    .robot/golden/bounce.scene.md5
    Placement Should Be    tests/fixtures/overlap.lua    port    .robot/fixtures/overlap.lua
    Placement Should Be    .robot/claims/tabicl.robot    port    .robot/claims/tabicl.robot

Every Markdown Page Becomes Robot
    Placement Should Be    DESIGN.md    doc    .robot/docs/canon.robot
    Placement Should Be    docs/ROWS.md    doc    .robot/docs/rows.robot
    Placement Should Be    agent/REFERENCE.md    doc    .robot/docs/reference.robot

The Commands Are One Lua CLI
    [Documentation]    bin/'s bash wrappers are rewritten as core/cli modules behind ./moonsplice; tablua's
    ...    ports.moonsplice is given that launcher as its bin.
    Placement Should Be    bin/moonsplice    rewrite    core/cli/init.lua
    Placement Should Be    bin/golden    rewrite    core/cli/golden.lua

The Studio App Is The Editor
    [Documentation]    app/studio comes over whole as editor/ (owner, 2026-10-07): Tauri in editor/src-tauri, its own
    ...    cargo project with a path dependency on native/engine; React in editor/src. It finds the engine by the
    ...    ./moonsplice launcher and core/moonsplice/init.lua. Its in-app agent ran on malleable, which is dropped:
    ...    agent.rs is rewritten to drive tablua's agent.loop, and editor.feature (Gherkin) becomes a Robot suite.
    Placement Should Be    app/studio/src-tauri/src/lib.rs    port    editor/src-tauri/src/lib.rs
    Placement Should Be    app/studio/src/timeline/Timeline.tsx    port    editor/src/timeline/Timeline.tsx
    Placement Should Be    app/studio/src-tauri/icons/icon.png    copy    editor/src-tauri/icons/icon.png
    Placement Should Be    app/studio/agent/editor.lua    port    editor/agent/editor.lua
    Placement Should Be    app/studio/agent/editor.feature    rewrite    .robot/suites/editor.robot

Python Is Parked
    [Documentation]    The vision MCP, the Modal worker, probes, lesson generators and research tools are Python.
    ...    They stay in Cadence; any that Moonsplice needs again is rewritten in Lua, or in Rust behind the engine.
    Placement Should Be    vision/moonsplice_vision/facts.py    park
    Placement Should Be    cloud/worker.py    park
    Placement Should Be    bin/moonsplice-audio    park

Nomimono, Buck And The Editor Model Are Dropped
    Placement Should Be    BUCK    drop
    Placement Should Be    justfile    drop
    Placement Should Be    model/Cargo.toml    drop
    Placement Should Be    packages/nomimono    drop
