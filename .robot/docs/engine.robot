*** Settings ***
Documentation    The engine: Rust + Lua on Bevy, our own motion-graphics renderer
...
...    Status: plan, 2026-10-06 (renderer decision revised the same day: Bevy as the one renderer). Superseded .robot/docs/canon.robot §2 "LÖVE as shell" on 2026-10-06 (Phase 1 done, LÖVE removed).
Metadata    Source    cadence@56ddad1:docs/ENGINE.md

*** Test Cases ***
Why move at all
    [Documentation]    LÖVE is a game framework we bent into a video renderer, and every tool in this space made the
    ...    same bend: Remotion and HyperFrames bend a browser. What we actually want is smaller and
    ...    sturdier -- **a Rust binary that embeds Lua, takes a composition, and writes frames** -- because
    ...    that is the shape that runs anywhere: a laptop, a GPU-less CI box, a Modal worker, the Studio's
    ...    backend, an agent's sandbox, and (with care) a browser tab.
    ...
    ...    The Studio stays web-rendered. Its UI is ten thousand lines of React that work, and nothing in
    ...    this plan touches it; what changes is what answers it.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

The rule: Rust and Lua
    [Documentation]    Everything we write, and everything the engine links, is Rust or Lua. LÖVE (C++), ThorVG (C++)
    ...    and Box2D (C, via LÖVE) all go. The exceptions are named here rather than discovered later:
    ...
    ...    - **The Lua VM itself** is C (mlua vendors Lua 5.4). That is the language we chose, not a leak.
    ...    - **ffmpeg, as a subprocess**, for encode and the audio mix (.robot/docs/canon.robot §3 already forbids linking
    ...    \ \ it). Decode is the one place ffmpeg is linked today (`decode/`, ffmpeg-the-third): there is no
    ...    \ \ production-quality pure-Rust H.264/HEVC/AAC decoder, so it stays, fenced in one crate, until
    ...    \ \ one exists (rav1d covers AV1 only). On macOS, VideoToolbox through objc2 is the alternative.
    ...    - **The OS's GPU driver**, under wgpu.
    ...    - **onnxruntime** in `track/` is perception tooling, outside the render path, and out of scope.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

The stack, all Rust
    [Documentation]    Decided 2026-10-06, after the prior-art survey: **one renderer, and it is Bevy.** We fork what
    ...    MotionGfx (`voxell-tech/bevy_motiongfx`) proved -- a seekable timeline driving Bevy, with vector
    ...    graphics and type drawn by vello inside Bevy's render world -- and own that renderer ourselves,
    ...    rather than keeping vello_cpu, Blitz and Bevy as three renderers that each paint part of a frame.
    ...
    ...    | layer | crate | what it gives |
    ...    |---|---|---|
    ...    | time, authoring | mlua + `core/moonsplice` | the comp, evaluated at any t. Lua stays the comp format |
    ...    | motion maths | `core/moonsplice`'s recorder; **animato** where it earns it | tweens, springs, stagger, paths. animato is evaluated where Bevy's own motion or per-glyph text animation falls short -- not as a second timeline |
    ...    | renderer | **Bevy**, headless, with our owned vello integration (`moonsplice-render`, forked from MotionGfx's minimal Bevy-vello renderer) | shapes, paths, gradients, type, masks, blends, images, video textures, 3D, post effects -- one render world, one z-order |
    ...    | paint abstraction | vello scenes built through **anyrender** | the same scene paints on the GPU (vello) or the CPU (vello_cpu) -- the CPU path is how a GPU-less server, CI and exact goldens still work |
    ...    | HTML/CSS | **Blitz**, as one node kind only | `s:html` / `s:page`: markup laid out by Stylo + Taffy, painted into a texture the renderer composites. Not a layout engine for the rest of the frame |
    ...    | vector animation | velato (Lottie → vello) | replaces ThorVG |
    ...    | physics | rapier2d | replaces Box2D for `drop` |
    ...    | decode | `decode/` (ffmpeg, fenced) | the one C exception |
    ...
    ...    **Why not Blitz as the 2D layer.** It would make CSS the second way to describe a frame, beside the
    ...    comp, and a second layout and paint path beside Bevy's. Markup stays available for what it is good
    ...    at -- a card of styled text, a page -- as a node like any other.
    ...
    ...    **Why animato is a candidate, not a dependency.** The Lua recorder already does tweens, springs,
    ...    stagger, paths and wiggle, and it is the part an agent edits. animato (created 2026-05, 1.7.x by
    ...    2026-07, about 800 downloads a quarter) is young; it comes in only where a measured gap -- spring
    ...    quality, per-glyph text motion -- is shown, and then behind the same Lua API.
    ...
    ...    **Dioxus.** RSX is compiled Rust, so it cannot be a comp format. Dioxus Native remains the one
    ...    route to an all-Rust Studio later; nothing here depends on it.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

What the research found
    [Documentation]    Two inventories, both 2026-10-06 (Bevy 0.19.1 stable, 0.20-rc.2):
    ...
    ...    **Most of our stack is already engine-free.** `core/moonsplice` (4.1k LOC) is pure Lua -- it already
    ...    runs under wasmoon in `web/`. The rasterizer `scene/` (vello_cpu + parley), decode, html, layout,
    ...    effects and scene3d are Rust. The Studio talks to the engine through one line protocol
    ...    (`core/runtime/serve.lua`) and says in its own comments that a LÖVE-free server can replace it
    ...    unnoticed. LÖVE's real jobs have shrunk to: the frame loop and ffmpeg pipe, the painter's node
    ...    walk (`core/runtime/painter.lua`), the GLSL escape hatches (shadertoy, worley, perspective + DoF,
    ...    displace, `s:draw`), six kinds it still draws itself (lottie, spritesheet, particles, chart,
    ...    ornament, spine), Box2D for `drop`, and check mode's canvases.
    ...
    ...    **Bevy is strong at the GPU half and weak at the 2D half.**
    ...
    ...    | | Bevy 0.19 | what we have |
    ...    |---|---|---|
    ...    | Text | parley layout, but glyphs from a bitmap atlas -- animated scale and sub-pixel motion degrade | parley glyphs drawn as paths by vello_cpu |
    ...    | Vectors, masks, blends, blur | bevy_vello lags upstream (vello 0.9 vs 0.11), needs compute; the rest is custom shaders | all in `scene/` opcodes, CPU |
    ...    | Determinism | same GPU + driver only; first frames blank until pipelines compile, so every frame needs a readiness gate | byte-identical per platform + thread count |
    ...    | Lua | bevy_mod_scripting is WIP, goes through reflection, no wasm; **mlua outside the ECS is ready** | mlua already in the Studio |
    ...    | Browser | Bevy runs in wasm, but mlua does not on Bevy's wasm target | wasmoon + a wasm build of `scene/` |
    ...    | 3D, PBR, lights, DoF, post | first-class | scene3d (wgpu 24, hand-rolled), love GLSL |
    ...    | Headless offscreen + readback | works: no pipelining, warm-up gate, `Readback` | n/a |
    ...    | GPU-less servers | lavapipe/WARP, slow | vello_cpu needs no GPU |
    ...    | Release churn | breaking minor every 3-5 months | ours |
    ...
    ...    No one ships an offline video renderer on Bevy. The closest prior art, MotionGfx, learned what this
    ...    plan assumes: keep the timeline outside the renderer and make Bevy one backend.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

MotionGfx, read (2026-10-06, spikes/motiongfx at 50404ae)
    [Documentation]    About 11k lines in six crates: `motiongfx` (the timeline core), `motiongfx_interp` (easing),
    ...    `motiongfx_scene` (a serializable scene document), `bevy_motiongfx` (the Bevy integration),
    ...    `peniko_motiongfx` (interpolating vello's colour and brush types), `velyst_motiongfx` (Typst
    ...    content drawn as vello paths, revealed path by path).
    ...
    ...    **It has no renderer.** "MotionGfx describes what changes and leaves drawing to the backend":
    ...    `bevy_motiongfx` does not depend on Bevy's render crate. It writes sampled values into Bevy
    ...    components, and whatever draws those components draws -- Bevy meshes and sprites, or
    ...    `bevy_vello` in the examples. So "fork MotionGfx" means three concrete things, not a renderer:
    ...
    ...    - **Its timeline is the job our Lua recorder already does.** A compiled timeline is a table of
    ...    \ \ segments with precomputed start and end values; sampling at t eases one segment and writes it
    ...    \ \ through a typed field lens (`pipeline/sample.rs`). Stateless in t, which is the whole reason its
    ...    \ \ playback runs backwards for free -- the same property `Timeline:evaluate(t)` has. We keep Lua's.
    ...    - **What we take:** the lens pattern for writing evaluated values into ECS components;
    ...    \ \ `PassivePlayer::set_time(t)`, which is the seek mode; and the pipeline-readiness gate from
    ...    \ \ `comps/examples/recording.rs` (a system in the render sub-app's `ExtractSchedule` that flips a state
    ...    \ \ once `PipelineCache` has no waiting pipelines) -- which is the fix for Bevy's blank first frames.
    ...    - **What we do not take:** its recording (a real window, PNG screenshots per frame, real time)
    ...    \ \ and Typst via velyst as the type system. Glyphs drawn as vello paths are the right idea for
    ...    \ \ moving type; parley already lays out our text, so the path is parley glyph runs → vello, not a
    ...    \ \ second typesetting language.
    ...
    ...    The renderer we own is therefore Bevy plus `bevy_vello` (vello 0.9 inside Bevy's render world,
    ...    0.14 on Bevy 0.19), forked into `moonsplice-render` when we need to diverge.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

bevy_vello, read (spikes/bevy_vello at 659b06f)
    [Documentation]    About 4.9k lines. It already has the three integrations we need: text through parley (0.7, behind
    ...    ours at 0.11), SVG through vello_svg, and Lottie through velato -- which is the ThorVG
    ...    replacement. `comps/examples/headless` renders with `MinimalPlugins` + `RenderPlugin`, no window, into a
    ...    camera whose target is an `Image`, and saves it -- so offscreen is a supported path, not a hack.
    ...
    ...    **The constraint that shapes our design:** every vello item is drawn into one intermediate
    ...    storage texture (`VelloRenderTarget`), which is then laid over the camera view as a single
    ...    `Mesh2d` quad (`VelloCanvasMaterial`). Vello items sort among themselves (`sort_render_items`),
    ...    but they cannot interleave with Bevy-native items: a vello title cannot sit between a Bevy sprite
    ...    and a 3D layer. So in `moonsplice-render`:
    ...
    ...    - **All 2D lives in the vello scene** -- shapes, type, masks, blends, and also images and video
    ...    \ \ frames, which vello draws natively (peniko images). One z-order, the comp's.
    ...    - **Bevy-native rendering happens first, into textures** -- 3D worlds, perspective + DoF, shader
    ...    \ \ effects -- and those textures enter the vello scene as images at their place in the stack.
    ...    - **Post effects on the whole frame** (the fx chain) run after vello, as Bevy post passes on the
    ...    \ \ composited frame.
    ...
    ...    That is also what makes the CPU path possible: the same vello scene, minus the GPU-made images,
    ...    paints through vello_cpu.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

Compositing: vello as the compositor
    [Documentation]    The single layer is not a bevy_vello shortcut. Vello is a compute rasterizer: it renders a whole
    ...    scene into one texture in one pass and never emits per-item draw calls into Bevy's render
    ...    phases, so there is nothing to interleave at that level. Two ways to composite anyway:
    ...
    ...    **A. Vello is the compositor (chosen).** Everything in the comp's stack is a layer in one vello
    ...    scene. Bevy-native content -- footage, 3D, shader effects -- renders first into textures, which
    ...    vello draws as images at their place in the stack: `Renderer::register_texture(wgpu::Texture)`
    ...    (vello 0.9) lets a scene draw a GPU-resident texture, copied GPU-to-GPU into vello's image atlas
    ...    each frame, never through the CPU. Vello's own layer stack (`push_layer` with blend mode, alpha,
    ...    transform and clip) is then the compositing model: nested groups, the CSS blend modes, masks and
    ...    clips apply across every kind, footage included, in exactly the comp's z-order. bevy_vello does
    ...    not use `register_texture` yet; adding it is the first change in our fork.
    ...
    ...    **B. Split the stack into runs.** Cut the stack wherever a Bevy-native item sits, give each vello
    ...    run its own target, and composite the runs as quads in Bevy's 2D phase. Bevy items never pass
    ...    through vello -- but a blend mode or mask can no longer see what lies below a run boundary,
    ...    because each run renders onto transparent. Rejected as the model; kept as an optimisation, for
    ...    caching a static run as a texture that is reused until it changes.
    ...
    ...    Costs to watch: the atlas copy per textured layer per frame (8 MB at 1080p, 33 MB at 4K -- small
    ...    for a GPU, but it multiplies with layer count), and the atlas's maximum size, which bounds how
    ...    many 4K layers fit in one frame.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

Footage
    [Documentation]    Seek, not playback, holds for video too: each frame asks for the source frame at its media time.
    ...
    ...    1. **Decode** stays `decode/` (ffmpeg, verified-index seeking, a prefetch worker). It returns
    ...    \ \ \ YUV 4:2:0 planes. The display matrix is applied here -- the fix for the iPhone take that
    ...    \ \ \ renders sideways today.
    ...    2. **Upload** the three planes into R8 textures each frame (3.1 MB at 1080p).
    ...    3. **Convert** in a compute pass into an Rgba8Unorm texture, using the pinned BT.709 maths ported as
    ...    \ \ \ **integer** arithmetic, so the GPU result matches the CPU path byte for byte and does not
    ...    \ \ \ depend on the GPU's float behaviour.
    ...    4. **Resample** to the size the frame is drawn at, in the same pass when downscaling (4K footage
    ...    \ \ \ into a 1080p frame), rather than letting the atlas sampler alias it.
    ...    5. **Composite:** the texture is registered with vello and drawn as an image with the clip's
    ...    \ \ \ framing (fill, fit, or a focus point), crop, transform and opacity -- one layer like any other.
    ...
    ...    Scrubbing keeps a small cache of converted textures around the playhead. Hardware decode
    ...    (VideoToolbox → IOSurface → a Metal texture handed to wgpu, zero-copy) is for preview only: it is
    ...    fast, but it is not bit-exact across machines, so offline renders keep the software path. Audio
    ...    never touches any of this; it is mixed at encode by ffmpeg, as now.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

The decision
    [Documentation]    **One Rust engine, `moonsplice-engine`. Lua owns time. Bevy renders, through a vello integration
    ...    we own, and every scene can also paint on the CPU. Blitz is a node.**
    ...
    ...    ```text
    ...    \ comp.lua ──► mlua: core/moonsplice (compile, evaluate(t)) \ \ ◄── Lua owns time: any t, any order
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ ▼ \ evaluated nodes (values, never a clock)
    ...    \ \ \ \ \ \ \ \ \ \ moonsplice-render (Bevy render world, headless)
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ ├─ shapes · paths · type · masks · blends ──► vello scene (anyrender)
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ ├─ GPU: vello in Bevy
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ └─ CPU: vello_cpu (no GPU, goldens)
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ ├─ images · video frames ──► textures
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ ├─ html / page ──► Blitz ──► texture
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ └─ 3D · perspective + DoF · shader fx ──► Bevy cameras, materials, post
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │
    ...    \ \ \ \ \ \ \ \ \ \ RGBA (readback) ──► hash | ffmpeg (+ audio filter_complex) | serve | check
    ...    ```
    ...
    ...    Why this shape:
    ...
    ...    - **One render world.** z-order, blending, masks and effects compose in one place instead of being
    ...    \ \ stitched from three renderers' outputs.
    ...    - **Bevy never sees a clock.** Each frame is posed from values Lua evaluated for t. No `Time`, no
    ...    \ \ animation player state, nothing carried between frames -- which is what MotionGfx's two-way
    ...    \ \ playback relies on too.
    ...    - **Exactness and portability survive the GPU.** Because 2D is a vello scene, the CPU path renders
    ...    \ \ the same scene byte-exactly on any machine; GPU frames are scoped to platform + GPU + driver.
    ...    - **We own the fork.** MotionGfx is young (0.4, a few hundred downloads); its renderer is small, so
    ...    \ \ we take the pattern and the code we need and track Bevy releases on our schedule.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

Phases
    [Documentation]    Each phase ends at a gate. Nothing is deleted until its gate is green.
    ...
    ...    *0. Spikes (decide with numbers)*
    ...    - **mlua host:** a Rust binary that loads `core/moonsplice` in mlua, compiles three cases
    ...    \ \ (`type_wrap`, `chart`, `captions`), walks the nodes in Rust and renders through `scene/` as an
    ...    \ \ rlib. Gate: frames byte-identical to the scene goldens.
    ...    - **Renderer bake-off** (`spikes/bakeoff/`): one real 1080p frame -- footage, a gradient card with
    ...    \ \ a shadow, a moving title, a wrapped paragraph, a blur -- rendered by Bevy alone, by Bevy with
    ...    \ \ vello (the MotionGfx pattern), by Blitz into a Bevy texture, and by vello_cpu as the reference.
    ...    \ \ Measured: ms/frame with readback, cold start, run-to-run and seek-order determinism, glyph
    ...    \ \ quality under sub-pixel motion, LOC, wasm. Decides the shape of Phase 2.
    ...    - **Browser:** the renderer crate compiled to `wasm32-unknown-unknown` on WebGPU, with Lua on
    ...    \ \ wasmoon. Measure wasm size.
    ...
    ...    *1. LÖVE leaves the 2D path*
    ...    `moonsplice-engine` (Rust): mlua + the comp sandbox (no clocks, no io, RNG seeded), the
    ...    painter's node walk ported from `core/runtime/painter.lua` (z-order, group affine chains, opacity, fx
    ...    ancestry), `scene/` and `decode/` as rlibs (no FFI), the ffmpeg pipe and audio mix from
    ...    `core/runtime/main.lua`, hash mode, and the serve protocol byte-compatible with `core/runtime/serve.lua`.
    ...    The resolve phase stays Lua (it uses love only for sha1/base64) and lint stays Lua (fix
    ...    `lint.lua:183` `unpack` → `table.unpack` for 5.4).
    ...    - Gate: every scene-owned case byte-identical; Studio and `moonsplice-agent` unchanged and green.
    ...    - Then: `moonsplice` runs the engine, not LÖVE, for every comp that does not use a LÖVE kind.
    ...
    ...    **Done 2026-10-06, and LÖVE removed outright the same day.** The engine is a host swap, not a
    ...    port: it runs `core/runtime/*.lua` unchanged on mlua/LuaJIT behind a `love` shim (`core/runtime/love.lua`)
    ...    whose `love.graphics` draws nothing, because on the direct path `scene/` paints the frame. Text
    ...    metrics come from parley (`scene.measure`), PNG and JPEG decode in Rust, check mode reads the
    ...    direct path's buffer. There is no fallback: `moonsplice` runs only the engine, and
    ...    `the vendored LÖVE fork`, the love-path goldens, `core/runtime/conf.lua` and `preview` are gone.
    ...    - 25/43 cases byte-identical to the scene goldens; `image` recaptured (JPEG via zune-jpeg, IDCT
    ...    \ \ rounding only, eyeballed). Audio mp4 md5 identical. Engine 0.88 s vs LÖVE 1.02 s on `audio`.
    ...    - Studio: `--lib` 141, `studio` 25, `spec` 18, `playback` 3, `offline` 5 -- all green, none skipped.
    ...    - Not ported, failing with status 3 and the node named (phases 2-3): kinds surface, draw, lottie,
    ...    \ \ particles, chart, ornament, spine, spritesheet, displace; blends subtract and replace;
    ...    \ \ `clip_invert`; perspective cards and the camera/world canvas; the fx/grade GLSL chain;
    ...    \ \ `t:drop` physics. Cases: compositing, blend_modes, clip_mask, draw, perspective_explode,
    ...    \ \ perspective_focus, camera, lottie, fx, fx_native, displace, spritesheet, particles, drop,
    ...    \ \ grade, chart, ornaments, spine.
    ...
    ...    *2. The renderer moves onto Bevy + vello (`moonsplice-render`)*
    ...    Fork MotionGfx's minimal Bevy-vello renderer into our crate. The painter's node walk emits vello
    ...    scenes through anyrender instead of `scene/` opcodes; images and video frames become textures.
    ...    Text is vello glyph runs from parley layout (the same layout `scene/` uses today). The kinds LÖVE
    ...    still draws move here as vello paths: particles, chart, ornament, spritesheet, spine, lottie
    ...    (velato), `clip_invert`, subtract/replace blends. `drop` physics moves to rapier2d.
    ...    - Gate: every 2D case renders through `moonsplice-render` on both paths (GPU vello and CPU
    ...    \ \ vello_cpu); `moonsplice eval --open` eyeballed against Phase 1 frames; then the goldens are recaptured
    ...    \ \ once, deliberately -- CPU-path goldens are the portable reference, GPU-path goldens are scoped.
    ...    - animato is measured here, against the recorder, on spring quality and per-glyph text motion.
    ...
    ...    **First step done 2026-10-06: the rasterizer is on anyrender.** `scene/` no longer paints its
    ...    opcode stream straight into vello_cpu; it records an `anyrender::Scene` (backend-free), and a
    ...    painter of our own (`scene/src/cpu.rs`, vello_cpu 0.3) rasterises it. The GPU path replays the
    ...    same `Scene` through a vello backend, so this is the seam Bevy plugs into. anyrender is 0.13, not
    ...    0.14, because that is what Blitz 0.3.0-beta.2 paints with, and one scene type for both is the
    ...    point: `html/` (Blitz) and `effects/` are folded into `scene/` (html behind the default `html`
    ...    feature, Blitz fenced to `scene/src/html`), and `vector/` is gone -- the scene path draws vectors
    ...    itself, and only the dead LÖVE canvas branch ever loaded it.
    ...    - The painter is ours rather than `anyrender_vello_cpu` because that backend picks its own thread
    ...    \ \ count (goldens are scoped to it), compiles filters out whenever threads are on, and re-copies
    ...    \ \ image blobs every frame; ours takes the caller's threads, keeps filters (the frame pins threads
    ...    \ \ to 0 instead), and treats image slots as resources so a video frame replaces pixels in place.
    ...    - vello_cpu 0.2 -> 0.3 moved almost nothing: 22/25 renderable cases byte-identical. `svg` (1
    ...    \ \ frame) and `video_layers` (1 frame) differ by at most 1/255 on <0.1% of pixels; `html` (9
    ...    \ \ frames) changed with the Blitz upgrade (beta.1 -> beta.2) and was eyeballed. Those three were
    ...    \ \ recaptured. `--shuffle` hashes stable; Studio suites green.
    ...    - Cost: recording then replaying adds 0.2-0.7 ms of draw per frame (captions 0.55 -> 0.75 ms,
    ...    \ \ video_layers 6.6 -> 7.3 ms) against ~4.7 ms of output per frame.
    ...
    ...    *3. Bevy takes the GPU kinds*
    ...    world / mesh / light / camera (retires `scene3d/`), the perspective homography with depth of field,
    ...    shadertoy and worley (GLSL through naga's GLSL frontend, or ported to WGSL), displace -- now in the
    ...    same render world as the 2D, not image slots. `s:html` / `s:page` render through Blitz into
    ...    textures. `s:draw(fn(t, g))` cannot survive: `g` *is* `love.graphics`; it is replaced by
    ...    `s:vector`'s display list and deprecated with a lint error pointing there.
    ...    - Gate: every case in `evals/cases` renders with no LÖVE binary present.
    ...
    ...    **Perspective planes stay on the CPU (decided 2026-10-06).** The plan above put the homography
    ...    on Bevy. It is a 2D warp of a flat page, so `scene/src/persp.rs` runs the former GLSL exactly
    ...    (inverse homography per stage pixel, thin-lens defocus over a 20-tap golden-angle spiral),
    ...    row-parallel, as opcode 114 around the card's own flat content. On the CPU it is deterministic
    ...    and in the goldens, and it runs where there is no GPU (CPU-only Linux, the browser). Two fixes
    ...    came with it: the stage is sized to where the page's corners project, not to a fixed margin,
    ...    so a card near the lens is not cut off by its own canvas; and every plane takes the frame's
    ...    focal length, not its own height's, so planes sharing a camera foreshorten alike. Bevy keeps
    ...    what needs a GPU: the comp's own GLSL (`shadertoy`) and the 3D world.
    ...
    ...    **Lottie stays on the CPU too.** velato 0.12 walks a composition into a `RenderSink` trait, not
    ...    into vello, so `scene/src/lottie.rs` records it straight into the frame's `anyrender::Scene`
    ...    (opcode 116, velato built without its vello feature). A Lottie is then vectors in the same
    ...    rasterizer as everything else: in the goldens, seek-safe (`--shuffle` hashes identical), no
    ...    second renderer. velato reads Lottie 5.5+ keyframes only; the loader upgrades the older shape
    ...    (end value in `e`, a bare `{"t": n}` last keyframe) the way lottie-web does. Image layers inside
    ...    a Lottie are not drawn yet.
    ...    - Gate met 2026-10-06: 43/43 cases render on the engine with no LÖVE binary and match their
    ...    \ \ goldens; Studio suites green (`--lib` 141, `studio` 25, `spec` 18, `playback` 3, `offline` 5).
    ...    \ \ The 3D world still renders through `scene3d/` (wgpu) into a slot, not in Bevy's render world.
    ...
    ...    *4. The Studio loads the engine in-process*
    ...    `engine.rs` stops spawning a subprocess per composition and calls `moonsplice-engine` directly.
    ...    The mmap ring and stdout parsing go; `cframe://` and `casset://` stay, so the React side does not
    ...    change. The agent's `outline`/`at` calls become function calls.
    ...    - Gate: Studio spec suite green; first-frame and scrub latency no worse (perf.rs numbers).
    ...
    ...    **Done 2026-10-06.** `moonsplice-engine` is a library as well as the binary, and
    ...    `moonsplice_engine::Session` runs `core/runtime/serve.lua` under the same boot on a thread of the
    ...    Studio's own process. The protocol did not change, which kept `engine.rs` small: requests go over a
    ...    channel where stdin was, `CS` lines come back where stdout was, and a frame's bytes are copied out of
    ...    the rasterizer's buffer (`ENGINE_HAND` in serve.lua) where they were written to a mapped file.
    ...    Export (`run_export`) runs `--render` the same way. Three things a process used to give the
    ...    runtime are given per session, since a process now holds several:
    ...    - `os.exit` throws an `ENGINE_EXIT` that the boot unwinds, so a composition that will not open
    ...    \ \ ends its session with status 1 and the app carries on (`engine/tests/session.rs`);
    ...    - `os.getenv` reads the session's own variables first. Every relative path in the runtime
    ...    \ \ resolves against `MOONSPLICE_CWD`, so each composition has its own working directory and the
    ...    \ \ process's is never changed;
    ...    - stderr is kept per session, which is where "why it would not open" comes from.
    ...
    ...    One Lua in the app: the engine's LuaJIT. The agent is not Lua in the app any more: it is a Tablua run
    ...    in its own process (`./moonsplice studio`, started by src-tauri/src/run.rs).
    ...    A session cannot be killed the way a child could. Dropping one hangs up without waiting, and a
    ...    composition stuck in a loop stays stuck until the app exits.
    ...
    ...    Measured with `tests/playback.rs` at load average about 23, in-process against the subprocess
    ...    build of the same tree, three runs each (engine up plus first frame, ms): video 84-121 against
    ...    186-257, type 13-17 against 139-151, primitives 138-414 against 119-387. Primitives is the first
    ...    composition opened in the process and pays the one-time dylib load that each child used to.
    ...    Warm frames are unchanged: p50 2.3 against 2.4 on primitives, 18.4 against 18.2 on video. Suites:
    ...    `--lib` 141, `studio` 25 (export included), `spec` 18, `playback` 3, `offline` 5, `longform` 7.
    ...
    ...    *5. Portability, as a tested matrix*
    ...    - macOS / Linux / Windows CLI: one binary + bundled ffmpeg.
    ...    - Linux CPU-only (CI, small servers): every 2D comp on the vello_cpu path; 3D and shader kinds via
    ...    \ \ lavapipe, slow but correct.
    ...    - Modal L4: verify the container exposes Vulkan graphics capability before relying on it.
    ...    - Browser: Bevy + vello on WebGPU (vello needs compute, so no WebGL2), the CPU path as the
    ...    \ \ fallback where WebGPU is missing. mlua cannot run on this target; Lua runs on wasmoon -- the same
    ...    \ \ `core/moonsplice` files on a different VM.
    ...    - iOS/Android: later; Lua as an interpreter (no LuaJIT JIT on iOS).
    ...    - Retire `the vendored LÖVE fork` and the love-path goldens (`<case>.md5`). Done in phase 1.
    ...
    ...    **Measured so far (2026-10-06, macOS arm64).** `moonsplice-scene` built without the `gpu` feature
    ...    (no Bevy, no wgpu: 15.8 MB against 36.7 MB) renders 41 of 43 cases byte-identical to the goldens.
    ...    The two it does not render are `fx` and `fx_native`, the cases that run the comp's own GLSL
    ...    (`shadertoy`); they stop with "this build has no GPU" rather than drawing something else. So
    ...    the goldens are a property of the CPU path, and a GPU only adds the comp's own shaders and the 3D
    ...    world (`world` passed here on Metal through `scene3d`). On CPU-only Linux the build to ship is the
    ...    `gpu` one over lavapipe, which keeps those two working, slowly. The build without `gpu` is the
    ...    floor, for targets with no Vulkan at all. Linux, Modal and the browser are not yet run.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

Risks
    [Documentation]    - **Bevy churn** -- pin one minor, upgrade deliberately, keep it behind `moonsplice-gpu`.
    ...    - **GPU determinism** -- weaker than vello_cpu by nature; scoped per GPU + driver and labelled.
    ...    - **Painter port** -- 1.6k lines of subtle ordering rules; Phase 1's byte-identical gate is what
    ...    \ \ makes this safe, so the gate is not negotiable.
    ...    - **`s:draw` removal** breaks any comp using it; lint first, remove later.
    ...    - **Compile time** -- Bevy is minutes cold; only `moonsplice-gpu` pays it, behind a cargo feature,
    ...    \ \ so a 2D-only build stays light.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

