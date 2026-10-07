*** Settings ***
Documentation    When the port is done: every test here passes. Until then each failure is the next piece of work,
...    in the order port.robot gives (rewrites, leftover references, splits). Run: luajit .robot/run.lua port/done

*** Test Cases ***
The Launcher And The CLI Exist
    [Documentation]    bin/'s wrappers are one Lua CLI behind ./moonsplice (Rewrites Left To Write lists them).
    Path Exists    moonsplice
    Path Exists    core/cli/init.lua

The Laws Hold
    [Documentation]    rules.robot: no file over 400 lines, no markdown, the root as written, Lua most of the code.
    Command Succeeds    luajit .robot/run.lua rules

The Unit Tests Pass
    Command Succeeds    luajit test/run.lua

The Workspace Builds And Its Tests Pass
    Command Succeeds    cargo test --workspace --release -q    native

The Editor Builds And Its Tests Pass
    [Documentation]    Tauri's tests run against this checkout; the React tests under vitest. The editor's MCP plugin
    ...    (src-tauri/../.tauri-plugin-mcp) is not tracked in Cadence: it is vendored or fetched by a build step.
    Command Succeeds    cargo test --release -q    editor/src-tauri
    Command Succeeds    npm ci && npx vitest run    editor

The Editor's Agent Is Tablua
    [Documentation]    malleable is gone; agent.rs drives tablua's agent.loop.
    Command Succeeds    ! grep -rn malleable editor/src-tauri/src

The Goldens Hold
    [Documentation]    Every eval case renders the per-frame hashes it rendered in Cadence (.robot/golden, scoped to
    ...    platform and thread count), so no cut changed a pixel.
    Command Succeeds    ./moonsplice golden compare

The Claims Still Run
    [Documentation]    Cadence's claims, now run by .robot/claims.lua with tablua at submodules/tablua/.
    Command Succeeds    luajit .robot/claims.lua reds

Tablua Names Moonsplice's Paths
    [Documentation]    tablua's comments and ports.moonsplice still say cadence/docs/ROWS.md, cadence/agent/REFERENCE.md
    ...    and bin/moonsplice. They become .robot/docs/rows.robot, .robot/docs/reference.robot and ./moonsplice in
    ...    a tablua commit, and the submodule is bumped to it.
    Command Succeeds    ! grep -rn -e 'cadence/' -e 'bin/moonsplice' submodules/tablua/core
