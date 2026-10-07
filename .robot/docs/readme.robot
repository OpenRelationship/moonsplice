*** Settings ***
Documentation    Moonsplice
...
...    <p align="center">
...    \ \ <picture>
...    \ \ \ \ <source media="(prefers-color-scheme: dark)" srcset="brand/logo.svg" />
...    \ \ \ \ <img src="brand/logo-light.svg" alt="Moonsplice" width="320" />
...    \ \ </picture>
...    </p>
...
...    <p align="center">
...    \ \ <strong>Programmatic video from Lua.</strong> No browser. No React scaffold.<br/>
...    \ \ One <code>.lua</code> file → headless LÖVE → ffmpeg → mp4.
...    </p>
...
...    <p align="center">
...    \ \ <a href="https://github.com/shinyobjectz/cadence">GitHub</a> ·
...    \ \ <a href=".robot/docs/checks.robot">Verification</a> ·
...    \ \ <a href="skills/moonsplice/SKILL.md">Agent skill</a> ·
...    \ \ <code>npx skills add shinyobjectz/cadence</code>
...    </p>
...
...    ---
...
...    Moonsplice is a seek-not-playback motion framework: compositions are pure functions of time. Agents author `.lua` files; the renderer evaluates any frame in any order; verification runs in milliseconds before you ever encode.
Metadata    Source    cadence@56ddad1:README.md

*** Test Cases ***
Watch: how Moonsplice works
    [Documentation]    <p align="center">
    ...    \ \ <a href="docs/media/how-moonsplice-works.mp4">
    ...    \ \ \ \ <img src="docs/media/how-moonsplice-works.jpg" alt="How Moonsplice Works: play the 2:40 video" width="100%" />
    ...    \ \ </a>
    ...    </p>
    ...
    ...    **Start here.** A 2:40 lesson that goes one layer deeper at each step: a comp as a function of time,
    ...    seeking any frame, declaring motion instead of drawing it, determinism and frame hashes, then the
    ...    fact log, perception and edits written back into the Lua. It was rendered by Moonsplice from
    ...    [`comps/lesson/how-moonsplice-works.lua`](comps/lesson/how-moonsplice-works.lua).
    ...    [▶ Play the video](docs/media/how-moonsplice-works.mp4)
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

Watch: facts on real footage
    [Documentation]    <p align="center">
    ...    \ \ <a href="docs/media/facts-on-footage.mp4">
    ...    \ \ \ \ <img src="docs/media/facts-on-footage.jpg" alt="Facts on footage: play the 1:46 video" width="100%" />
    ...    \ \ </a>
    ...    </p>
    ...
    ...    What the fact log looks like on a real clip, and how an agent works with it. A stock shot of a
    ...    bottle changing hands is perceived into facts, and every overlay is drawn from one of them:
    ...    tracker boxes, the third of the frame an object is in, its direction and speed, and the moment of
    ...    release. Then an agent edits a comp from the log alone: it asks when the release happens, asserts
    ...    a caption there, and proves the edit by hashing every frame (100 of 358 changed, in exactly two
    ...    windows). Rendered from [`comps/agent/facts-on-footage.lua`](comps/agent/facts-on-footage.lua);
    ...    the grammar is in [`.robot/docs/facts.robot`](.robot/docs/facts.robot).
    ...    [▶ Play the video](docs/media/facts-on-footage.mp4)
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

Quick start
    [Documentation]    ```bash
    ...    git clone https://github.com/shinyobjectz/cadence.git && cd moonsplice
    ...    cd desktop && pnpm install && cd ..
    ...
    ...    \# environment check
    ...    moonsplice doctor
    ...
    ...    \# instant compile (wasmoon, ~30ms)
    ...    cd comps/projects/launch-spot
    ...    ../../bin/moonsplice verify comps/launch.lua --wasm-only
    ...
    ...    \# render
    ...    ../../bin/moonsplice render comps/launch.lua -o out.mp4
    ...    ```
    ...
    ...    Install the agent skill (Cursor, Claude Code, Codex, Copilot, …):
    ...
    ...    ```bash
    ...    npx skills add shinyobjectz/cadence
    ...    ```
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

CLI
    [Documentation]    | Command | What it does |
    ...    |---------|----------------|
    ...    | `moonsplice verify comp.lua --json` | Compile → lint → check pipeline |
    ...    | `moonsplice verify … --wasm-only` | Instant tier-0 compile feedback |
    ...    | `moonsplice doctor` | Probe love, ffmpeg, wasmoon, project layout |
    ...    | `moonsplice feedback comp.lua` | Agent-readable summary + next steps |
    ...    | `moonsplice lint / check` | Static + pixel verification (`--json`) |
    ...    | `moonsplice render` | Offline encode to mp4 |
    ...
    ...    All verification commands emit **`moonsplice.result/v1`** JSON — structured findings agents can parse without reading stack traces.
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

Vision MCP
    [Documentation]    `bin/moonsplice-vision` is an MCP server (registered in `.mcp.json`) that shows a
    ...    comp, clip or image to any vision or video model in the shape it reads best:
    ...    per-model profiles, keyframes, labeled contact sheets, numbered marks bound to
    ...    the comp's own node ids, scene text, diffs, and Depth Anything 3 depth and
    ...    multi-view geometry with rendered top/iso views. `bin/vision-setup` builds its
    ...    venv; `bin/moonsplice-vision call TOOL k=v` runs any tool from the shell.
    ...    Design and measurements: `.robot/docs/vision.robot`.
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

Composition sketch
    [Documentation]    ```lua
    ...    local e = require("moonsplice")
    ...
    ...    return e.comp {
    ...    \ \ width = 1080, height = 1920, duration = 6, fps = 30,
    ...    \ \ background = "#0B0D12",
    ...
    ...    \ \ scene = function(s)
    ...    \ \ \ \ local title = s:text { x = 540, y = 960, text = "moonsplice", size = 120,
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ color = "#5EEAD4", anchor = "center", opacity = 0 }
    ...    \ \ \ \ s:script(function(t)
    ...    \ \ \ \ \ \ t:tween(title, 0.8, { opacity = 1, size = 140 }, "backOut")
    ...    \ \ \ \ end)
    ...    \ \ end,
    ...    }
    ...    ```
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

Why Moonsplice
    [Documentation]    - **Deterministic by construction** — no clocks, no I/O in comps; RNG seeded
    ...    - **Agent-first** — lint/check/verify JSON, skill on [skills.sh](https://skills.sh)
    ...    - **~10MB engine** — vendored LÖVE fork, not headless Chrome
    ...    - **Three hosts, one API** — native encode, wasmoon preview, Rust helpers
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

Renderer
    [Documentation]    Frames are painted by `moonsplice-scene` (vello_cpu + parley): one rasterizer for
    ...    text, shapes, images, html, vector, masks, blends, shadows, colour effects, the
    ...    fx chain and video, with no GPU readback. World (wgpu), perspective and the
    ...    GLSL escape hatches (`shadertoy`, `worley`, `s:draw`) render through love into
    ...    image slots inside the same frame. `MOONSPLICE_SCENE=0` selects the old love
    ...    canvas path. Details, coverage and measurements: [.robot/docs/scene.robot](.robot/docs/scene.robot).
    ...    `moonsplice golden capture|compare` holds per-frame hashes across renderer changes.
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

Layout
    [Documentation]    | Path | Purpose |
    ...    |------|---------|
    ...    | `moonsplice` | CLI entry (render, verify, doctor, …) |
    ...    | `core/moonsplice/` | Host-free authoring API |
    ...    | `core/runtime/` | LÖVE offline host (`scene.lua` = bridge to the rasterizer) |
    ...    | `scene/` | `moonsplice-scene`: the vello_cpu + parley rasterizer |
    ...    | `desktop/` | Tauri + React editor (optional) |
    ...    | `skills/moonsplice/` | Official agent skill |
    ...    | `evals/` | Public visual suite |
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

Moonsplice → Moonsplice
    [Documentation]    This project was formerly **moonsplice**. The Lua module alias `require("moonsplice")` remains for compatibility; new work should use `moonsplice` naming. The archived repo: [github.com/shinyobjectz/moonsplice](https://github.com/shinyobjectz/moonsplice).
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

License
    [Documentation]    MIT — see [LICENSE](LICENSE) if present, otherwise check repo root.
    [Tags]    doc    source:cadence@56ddad1:README.md
    Skip    prose

