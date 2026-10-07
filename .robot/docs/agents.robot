*** Settings ***
Documentation    Moonsplice — project instructions for agents
...
...    Programmatic video from Lua. A composition is a pure function of time; the
...    renderer seeks any frame in any order. Canon decisions live in `.robot/docs/canon.robot`;
...    change them only with a written reason there.
Metadata    Source    cadence@56ddad1:CLAUDE.md

*** Test Cases ***
Build & test
    [Documentation]    This repo is a nomimono consumer. `just` is the door for repo shape and the
    ...    spec-first lifecycle; the Moonsplice commands below still own the renderer.
    ...
    ...    ```bash
    ...    just \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # list recipes
    ...    just check \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # doctor + gherkin + buck2 build //... + buck2 test //...
    ...    just context \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # projects and features; the desktop epic is `studio`
    ...    ```
    ...
    ...    ```bash
    ...    moonsplice build \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # cargo build --release + stage dylibs into native/target/release/
    ...    moonsplice doctor \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # engine, ffmpeg, ffprobe, wasmoon, project layout
    ...    moonsplice render comps/x.lua -o out.mp4 \ \ # moonsplice-scene rasterizer (default, .robot/docs/scene.robot)
    ...    moonsplice lint|check|verify comps/x.lua --json
    ...    moonsplice golden capture|compare [case…] \ \ \ \ # per-frame md5 (.robot/golden/<case>.scene.md5)
    ...    moonsplice eval --open \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # render the public eval suite to evals/out/eval.html
    ...    bin/vision-setup \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # one-time: vision/.venv (uv, py3.12, torch, mcp, Depth Anything 3)
    ...    bin/moonsplice-vision call contact_sheet source=comps/cases/camera.lua n=6 \ \ # any vision tool from the shell
    ...    bin/moonsplice-vision test \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # vision smoke tests (depth/geometry run when DA3 weights are cached)
    ...    bin/moonsplice-vision eval --clips DIR \ \ \ # perception scored on real pixels with exact truth (.robot/docs/facts.robot)
    ...    native/target/release/moonsplice-apple slowmo IN OUT.mov --factor 4 \ \ # Vision/SoundAnalysis/VideoToolbox (tools/apple)
    ...    MOONSPLICE_PROFILE=1 … \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # per-frame draw/read/out + scene timings
    ...    ```
    [Tags]    doc    source:cadence@56ddad1:CLAUDE.md
    Skip    prose

Architecture
    [Documentation]    - `core/moonsplice/` — host-free authoring API: scene graph, recorder (overlap
    ...    \ \ checking), signals, `waitUntil`, lint. Never touches love or Rust.
    ...    - `engine/` — `moonsplice-engine`, the only host: Rust + LuaJIT (mlua) running `core/runtime/*.lua`
    ...    \ \ behind a `love` shim that draws nothing. A feature not yet ported exits 3 and names the node
    ...    \ \ (.robot/docs/engine.robot). LÖVE was removed 2026-10-06.
    ...    - `core/runtime/` — the host runtime in Lua. `painter.lua` walks the evaluated tree;
    ...    \ \ `scene.lua` streams scene-owned nodes to the Rust rasterizer; `main.lua`
    ...    \ \ owns the frame loop, ffmpeg pipe and the no-readback direct path.
    ...    - `scene/` — `moonsplice-scene` (anyrender scene → our vello_cpu 0.3 painter, `src/cpu.rs`; parley
    ...    \ \ text; Blitz html in `src/html` behind the `html` feature), the renderer. One
    ...    \ \ rasterizer for text, shapes, images, html, vector, masks, blends, shadows,
    ...    \ \ effects, the fx chain and video; world, perspective and GLSL escape hatches
    ...    \ \ land in image slots. Opcodes at the top of `scene/src/lib.rs`. Coverage:
    ...    \ \ `.robot/docs/scene.robot`.
    ...    - `core/runtime/derive.lua` — media and facts made in the resolve phase and cached by hash:
    ...    \ \ `video{ derive = { stabilize, deflicker, denoise, slowmo, motion_blur, reframe, cutout } }`,
    ...    \ \ `s:derive(src, { beats, words, silence, loudness })`. Apple frameworks via `tools/apple`
    ...    \ \ (VideoToolbox frame processors for slowmo/blur), ffmpeg as the fallback.
    ...    - `vision/` — `moonsplice-vision`, the visualization MCP (`.mcp.json` registers
    ...    \ \ it): renders comps, clips and images into what a vision/video model reads
    ...    \ \ best. Profiles per model, keyframes, contact sheets, Set-of-Mark annotation
    ...    \ \ from the comp's own nodes, scene text, diffs, Depth Anything 3 depth and
    ...    \ \ multi-view geometry with rendered views. Design and measurements:
    ...    \ \ `.robot/docs/vision.robot`.
    ...    - `vision/moonsplice_vision/facts.py` and friends — the fact log: one event-calculus
    ...    \ \ grammar (`holds`/`happens`/`src`) for both what a comp *is* (lifted, exact) and
    ...    \ \ what a clip *shows* (perceived, every line carrying its producer and a derived
    ...    \ \ confidence). `lower.py` writes edits back into the Lua. A fact with no `src`
    ...    \ \ line is exact — that rule is load-bearing, do not emit perceived facts without
    ...    \ \ one. Design, measurements and known gaps: `.robot/docs/facts.robot`.
    ...    - `track/` — `moonsplice-track`, EdgeTAM on ONNX Runtime from Rust (Core ML on macOS).
    ...    \ \ `MOONSPLICE_TRACKER=edgetam` (default, PyTorch MPS) | `coreml` | `onnx` (CPU) | `sam2`;
    ...    \ \ `tools/edgetam_onnx_setup.py` prepares its models. Exact against transformers on CPU.
    ...    - `cloud/` — the Modal worker (`worker.py`, L4, three videos per card) and its client
    ...    \ \ (`bin/moonsplice-cloud process URL… | --batch items.ndjson`): fetch → full-recognition perceive →
    ...    \ \ clips with their own fact logs (`vision/moonsplice_vision/{fetch,tags,clips}.py`). The client refuses
    ...    \ \ work past $50/month of Modal spend.
    ...    - `tabicl/` — `moonsplice-tabicl`, TabICLv2 in Candle: tablua's move ranker, registered in the engine as
    ...    \ \ `MOONSPLICE_ENGINE.tabicl` and served by `moonsplice tabicl` (a JSON body per line). Parity with
    ...    \ \ tabicl 2.2.0 against tablua-local's fixtures: `native/target/release/moonsplice-tabicl parity FIXTURE…`.
    ...    - `model/` — `moonsplice-model`, the earlier editor-model harness. Direction
    ...    \ \ scrapped 2026-09-16 (a timeline-only model cannot read pixels); kept for
    ...    \ \ its validation code, not developed further.
    ...    - `solid/` — `moonsplice-solid`, Manifold CSG: a tree of plain values (an asset's `solid = {...}`)
    ...    \ \ built once into a watertight mesh, cached by hash, drawn by Bevy; measurements (parts, genus,
    ...    \ \ size) are the agent's check. `.robot/docs/solids.robot`.
    ...    - `decode/ layout/ scene3d/` — native helpers over a
    ...    \ \ C ABI, loaded by LuaJIT FFI.
    ...    - `comps/cases/` — public visual suite; `.robot/golden/` — hashes per case.
    ...    - `context/projects/studio/` — the desktop epic as Gherkin features (`.robot/docs/desktop.robot`
    ...    \ \ is the narrative; `bdd/*.feature` is the spec).
    ...    - `packages/nomimono/` — the repo contract, pinned submodule. Do not edit in place.
    [Tags]    doc    source:cadence@56ddad1:CLAUDE.md
    Skip    prose

Conventions
    [Documentation]    - Comps are pure `f(t)`: no clocks, no I/O, seeded RNG. All fetching happens in
    ...    \ \ the resolve phase (`core/runtime/resolve.lua`).
    ...    - Every renderer change: capture goldens before, compare after, eyeball
    ...    \ \ `moonsplice eval --open`, then recapture deliberately.
    ...    - Determinism is scoped to platform + `MOONSPLICE_SCENE_THREADS`; do not compare
    ...    \ \ hashes across thread counts.
    ...    - Use non-interactive flags (`cp -f`, `rm -rf`, `ssh -o BatchMode=yes`).
    [Tags]    doc    source:cadence@56ddad1:CLAUDE.md
    Skip    prose

