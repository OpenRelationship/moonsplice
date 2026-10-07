*** Settings ***
Documentation    Moonsplice: the locked canon decisions. Why they are made this way is .robot/docs/design.robot (the bet).
...
...    Locked decisions. Change only with a written reason here.
Metadata    Source    cadence@56ddad1:DESIGN.md

*** Test Cases ***
1. Core invariants
    [Documentation]    1. **Seek, not playback** — composition = pure function of time `t`; any frame, any order.
    ...    2. **Seconds, not frames** — fps is a render parameter.
    ...    3. **Duration static** — declared in comp header, immutable at render time.
    ...    4. **Determinism by construction** — renderer owns the VM: clock stubbed, RNG seeded,
    ...    \ \ \ zero I/O during render. All network/asset work happens in the resolve phase.
    ...    5. **Audio never touches the engine** — resolved clips + volume envelopes → ffmpeg
    ...    \ \ \ `filter_complex` at encode; mux with `-c copy`.
    ...
    ...    **Amendment 2026-10-06: games.** The engine builds games as well as videos. Rules 1, 3 and 5
    ...    extend to them as follows:
    ...    - **Rule 1.** A game is a pure function of `t` *and the input log up to `t`*. The simulation
    ...    \ \ steps at a fixed rate and is deterministic: seeded RNG, rapier with `enhanced-determinism`, no
    ...    \ \ wall clock. Player input is a list of timed events, which are `happens` facts. Any frame is
    ...    \ \ reproducible by replaying the log from the nearest snapshot. A video is the case with an empty
    ...    \ \ or scripted log, so everything below still holds for it unchanged.
    ...    - **Rule 3.** A game has no declared duration while it is played. A recording has the duration
    ...    \ \ of its log.
    ...    - **Rule 5.** Live play mixes sound in the host, in real time. Rendering a recording still goes
    ...    \ \ through ffmpeg at encode.
    ...
    ...    Reason: the user wants the full engine available for interactive work. Making input part of the
    ...    function's argument, rather than a side effect, keeps seek, goldens, the fact log and the
    ...    agent's tools working for games. It also gives two things for free: a played session renders as
    ...    a trailer, and the agent can script a log to make a game play itself on camera.
    [Tags]    doc    source:cadence@56ddad1:DESIGN.md
    Skip    prose

2. Hosts
    [Documentation]    - **Engine host (decision 2026-10-06, supersedes the LÖVE host):** `moonsplice-engine`
    ...    \ \ (`engine/`, Rust + LuaJIT via mlua) runs `core/runtime/*.lua` for `render`, `hash`, `lint`,
    ...    \ \ `check` and `serve`, and every frame is painted by `scene/`. LÖVE and `the vendored LÖVE fork`
    ...    \ \ are deleted. Reason: the project is Rust + Lua only (.robot/docs/engine.robot), and LÖVE is C++; once
    ...    \ \ the direct path painted every scene-owned comp, LÖVE was only a frame loop, a font metric
    ...    \ \ and a JPEG decoder. Gate met: every case that renders is byte-identical to the scene goldens
    ...    \ \ (25/43), `image` recaptured once because JPEG now decodes in Rust (zune-jpeg), and the Studio
    ...    \ \ suites pass against the engine. A comp that uses a feature not yet ported (LÖVE-drawn kinds,
    ...    \ \ GLSL hatches, perspective/camera, `t:drop` physics) fails with status 3 and a sentence naming
    ...    \ \ the node and feature; .robot/docs/engine.robot phases 2-3 port them. `preview` is gone (use Studio).
    ...    \ \ Golden hashes are scoped to platform + `MOONSPLICE_SCENE_THREADS`.
    ...    - **Blend modes (decision 2026-10-06):** `blend` is the CSS set (vello's Mix: multiply ...
    ...    \ \ luminosity) plus `add`. LÖVE's `subtract` and `replace` are authoring errors that name the
    ...    \ \ nearest mode. Reason: they were LÖVE's GL blend equations; neither CSS nor vello (CPU or GPU)
    ...    \ \ has them, and a mode one backend cannot draw is a mode the comp cannot rely on.
    ...    - **web host** (preview only): Lua 5.4 via wasmoon (official Lua compiled to
    ...    \ \ WebAssembly) plus a Canvas2D painter. Same host-free `core/moonsplice` compositions;
    ...    \ \ seek is still `evaluate(t)`. This is not the encode path — ffmpeg and native
    ...    \ \ helpers stay on LÖVE fork. Reason: shipping the Metal/LuaJIT fork through
    ...    \ \ Emscripten would throw away FFI dylibs and the virtual backbuffer; the painter
    ...    \ \ contract already exists so a second host can be small.
    ...    - **Scene rasterizer (decision 2026-09-16, supersedes the line below):** the
    ...    \ \ evaluated node tree paints into ONE rasterizer, `scene/` (`moonsplice-scene`,
    ...    \ \ vello_cpu + parley), streamed as a flat command list over the C ABI. One
    ...    \ \ antialiaser, one font stack, one gamma. LÖVE shrinks to a frame loop and the
    ...    \ \ ffmpeg pipe; when every node in a comp is scene-owned the renderer skips the
    ...    \ \ canvas and GPU readback entirely (`PROF direct=1`). Node kinds move over one at
    ...    \ \ a time behind `MOONSPLICE_SCENE=1`; kinds the crate cannot paint yet fall back to
    ...    \ \ love per node, with a z-order-preserving flush. See `.robot/docs/scene.robot` for
    ...    \ \ coverage, opcodes and the measurements that justified the direction.
    ...    - **Default renderer (decision 2026-09-16, gate of .robot/docs/scene.robot item 7):**
    ...    \ \ the scene rasterizer is the default; `MOONSPLICE_SCENE=0` is the fallback. Gate
    ...    \ \ met: 42/42 renderable evals green and eyeballed in scene mode, scene goldens
    ...    \ \ captured (`drop` needs the LÖVE 12 physics API and is the one case this Mac
    ...    \ \ cannot run under Homebrew 11.5). Love now does three things for `render`:
    ...    \ \ the frame loop + ffmpeg pipe, the GLSL escape hatches (`shadertoy`,
    ...    \ \ `worley`, `s:draw`, perspective homography, world/wgpu) painted into slots,
    ...    \ \ and `preview`.
    ...    - ~~**LÖVE-as-shell vs mlua (decided 2026-09-16): LÖVE stays the shell for now.**~~
    ...    \ \ Reversed 2026-10-06 by the engine host above.
    ...    \ \ Reason: the escape hatches above still need `love.graphics` canvases, and
    ...    \ \ they are used by shipped evals (fx, camera, perspective_*, world3d, draw).
    ...    \ \ An mlua host for `render`/`hash` becomes worth it only when those hatches
    ...    \ \ are either CPU-ported (perspective: a projective warp in Rust; world: wgpu
    ...    \ \ already, needs only a slot without love) or declared preview-only. Until
    ...    \ \ then a second host would be a second painter to keep in parity. Revisit when
    ...    \ \ a release needs to drop the LÖVE dependency (Linux/Windows bundles).
    ...    - ~~A Rust renderer is not a planned replacement host.~~ Rust owns distribution,
    ...    \ \ the native helpers, and the rasterizer. The LÖVE-compatible `love.*` surface
    ...    \ \ remains for `s:draw` escape hatches, `shadertoy`/`worley`, perspective
    ...    \ \ surfaces and the 3D world layer, all composited through image slots.
    ...    - Authoring core = Lua-native scene graph + signals + coroutine timeline
    ...    \ \ (`waitUntil` events). React model (`react-moonsplice` via react-lua/react-luau host
    ...    \ \ config) = later optional skin, never the core.
    ...    \ \ Optional `e.comp { inputs = { bg = { kind = "video" } } }` lets a host bind
    ...    \ \ media without rewriting Lua: `scene(s)` reads `s.input.bg` (a string path).
    ...    \ \ Studio writes a sibling `<comp>.inputs.json`; the CLI accepts `--inputs FILE.json`
    ...    \ \ and repeatable `--input KEY=PATH`. Merge is key-wise: defaults < sibling JSON <
    ...    \ \ `--inputs` file < `--input` flags. Hardcoded `src=` remains valid. Missing
    ...    \ \ required inputs error at compile (`moonsplice: input "bg" is not bound`). The host
    ...    \ \ injects the resolved string table into `Comp:compile`; `core/moonsplice` stays disk-free.
    [Tags]    doc    source:cadence@56ddad1:DESIGN.md
    Skip    prose

3. Encode (canon)
    [Documentation]    Bundled ffmpeg subprocess only — never linked, never GStreamer. Three invocations per render:
    ...    raw-RGBA video pass → `filter_complex` audio mix → `-c copy` mux. `ffprobe` at
    ...    resolve. Pin and ship the ffmpeg build inside each Moonsplice distribution.
    ...    Formats: mp4/h264 default; webm/vp9 + mov/prores4444 for alpha; png-sequence; gif.
    [Tags]    doc    source:cadence@56ddad1:DESIGN.md
    Skip    prose

4. Decode (canon) — moonsplice-decode
    [Documentation]    Lib-first Rust crate, zero IPC assumptions in core.
    ...
    ...    - **rsmpeg + vendored FFmpeg 8** shared libs (only stack covering
    ...    \ \ h264/h265/vp9/av1/prores across mp4/mov/webm/mkv).
    ...    - **BestSource-style verified index**: first-open linear pass → frame→(PTS, keyframe,
    ...    \ \ position) table (+ opt-in per-frame 8-byte hash, "paranoid" mode); index cached on
    ...    \ \ disk. Seek = keyframe-back + decode-forward + verify landed PTS; anomaly → linear
    ...    \ \ fallback from known-good point. FFI-linking BestSource itself is an approved
    ...    \ \ alternative to reimplementation.
    ...    - **Hw decode via FFmpeg hwaccel layer** (one code path): VideoToolbox on macOS
    ...    \ \ (ProRes hw on M1 Pro+), NVDEC on 4070 (sessions unlimited; 10-bit h264 = sw
    ...    \ \ fallback), VAAPI on Linux, transparent sw fallback.
    ...    - **Determinism**: decoded YUV is bit-exact by spec across conformant decoders (incl.
    ...    \ \ hw). Only post-decode conversion diverges → ONE pinned YUV→RGB path we own;
    ...    \ \ fixed-point/integer path when cross-machine hash-exactness required. Never hw
    ...    \ \ scalers/CSC on the deterministic path.
    ...    - **Cache**: per-stream sequential decode state machine (forward fast path within a
    ...    \ \ render chunk), small per-stream NV12 LRU (never RGBA in cache), global cap
    ...    \ \ 256MB–1GB, mpv-style packet cache for back-seeks as needed.
    ...    - **Linkage — one crate, three consumers** (lib-first, zero IPC assumptions in core):
    ...    \ \ 1. **love host (primary): cdylib with C ABI, loaded via LuaJIT FFI** (`ffi.load`)
    ...    \ \ \ \ \ — in-process, no IPC; decoded frames land in memory LuaJIT wraps as ImageData.
    ...    \ \ \ \ \ (mlua is the inverse direction — Rust hosting Lua — and applies only to the
    ...    \ \ \ \ \ rust host; it cannot be injected into love, which already owns its LuaJIT VM.)
    ...    \ \ 2. rust host: plain rlib in-process; mlua embeds LuaJIT/Luau to run comps.
    ...    \ \ 3. isolation fallback: daemon + msgpack unix socket + shm ring buffer (crash
    ...    \ \ \ \ \ isolation for hostile files; shm sustains multiple 4K60 streams). macOS
    ...    \ \ \ \ \ IOSurface zero-copy = profiling-gated later optimization.
    ...    - Rejected: GStreamer (random access fights pipeline model), libmpv render API
    ...    \ \ (unsuited by design), vk-video (unmaintained), pure-Rust hevc/prores (doesn't exist).
    [Tags]    doc    source:cadence@56ddad1:DESIGN.md
    Skip    prose

5. Perceptual layer (canon) — moonsplice probe
    [Documentation]    Mac-first stack (locked 2026-08-01):
    ...
    ...    | role | model | note |
    ...    |------|-------|------|
    ...    | frames / text-query | **MobileCLIP2-S2** | CoreML/ANE, single-digit ms/frame |
    ...    | spatial / patch lint | **C-RADIOv3-B** | commercial-OK license; DINOv3 runs hot locally |
    ...    | temporal | **X-CLIP-B** | vanilla transformers; V-JEPA2 too heavy locally |
    ...    | audio | **CLAP** | same stack as 11l media-DNA pipeline |
    ...
    ...    Probe → embedding sidecar (stride frames + patch grids + audio windows + derived:
    ...    motion energy, cut/freeze/black via embedding deltas) → `moonsplice query` timestamped
    ...    hits; comp asserts (`assert.visible("logo", 2, 4)`) compile to calibrated
    ...    probability thresholds at check time. License tripwires: VideoCLIP-XL (NC),
    ...    RADIOv2.5/E-RADIO (NC — C-RADIO only).
    [Tags]    doc    source:cadence@56ddad1:DESIGN.md
    Skip    prose

6. Resolve phase + ElevenLabs
    [Documentation]    Pre-render, network allowed, content-hash cached. ElevenLabs first-class: TTS
    ...    (`eleven_v3`), SFX, Music → clip durations known before render; Scribe word
    ...    timestamps → `waitUntil('word:…')` sync + karaoke captions for free.
    [Tags]    doc    source:cadence@56ddad1:DESIGN.md
    Skip    prose

