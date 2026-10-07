*** Settings ***
Documentation    moonsplice-scene — one rasterizer under the timeline
...
...    Status 2026-09-16: the default renderer (`MOONSPLICE_SCENE=0` = love canvas
...    fallback). Text, shapes, images, html textures, vector layers, clip masks,
...    blend modes, shadows, blur, colour effects, the fx chain and video paint
...    through vello_cpu; world, perspective and the GLSL escape hatches land in
...    image slots inside the same frame. Every eval renders on the direct path.
Metadata    Source    cadence@56ddad1:docs/SCENE.md

*** Test Cases ***
Why
    [Documentation]    The authoring layer (`core/moonsplice`: scene graph, recorder, overlap checking,
    ...    signals, `waitUntil`) is the asset. What it painted into was five engines:
    ...    love.graphics for shapes and text, Blitz for html, vello_cpu for vector nodes,
    ...    Taffy for flex, wgpu for 3D. Five antialiasers, three font stacks, no shared
    ...    compositing model. That is where "assembled from parts" comes from, and it is
    ...    why rich visual properties (letter-spacing, gradient stops, mask paths, blur)
    ...    were not tweenable: the timeline could express them but the pixels could not.
    ...
    ...    Measured before deciding (M-series Mac, 1080×1920):
    ...
    ...    | path | scene | per frame |
    ...    |---|---|---|
    ...    | love draw + GPU readback (render mode) | 24 text lines + 40 shapes | 0.3 + 2.6 ms |
    ...    | moonsplice-scene direct, 1 thread | same | 2.6 ms, no readback |
    ...    | moonsplice-scene direct, 4 threads | same | 1.8 ms |
    ...    | vello_cpu 0.2, 1 thread | 2500 glyph paths + 40 gradient cards + 3 radial washes + 600 strokes | 16.4 ms |
    ...    | vello_cpu 0.2, 8 threads | same | 6.2 ms |
    ...
    ...    vello_cpu is not the bottleneck; the readback and the ffmpeg pipe were.
    [Tags]    doc    source:cadence@56ddad1:docs/SCENE.md
    Skip    prose

Shape
    [Documentation]    ```
    ...    core/moonsplice \ (pure Lua) \ ──evaluate(t)──▶ \ core/runtime/painter.lua
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │ \ scene_owns(node)?
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ ├─ yes → core/runtime/scene.lua builder (f32 ops + string table)
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ └─ no \ → love.graphics (flush scene layer first, z-order kept)
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ ▼
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ scene/src/lib.rs \ cs_render() \ → premultiplied RGBA
    ...    ```
    ...
    ...    - `core/runtime/scene.lua` — FFI bridge + command builder. Same verbs as the vector
    ...    \ \ builder (`rect circle move line curve fill stroke gradient radial grain`) plus
    ...    \ \ `text image clip_push blend_push filter_push opacity_push pop transform clear`.
    ...    - `scene/src/lib.rs` — interpreter. Opcodes documented at the top of the file.
    ...    \ \ Fonts: `cs_font_load(path)`; id 0 is the bundled NotoSans (love's default).
    ...    \ \ Text layout is parley (shaping, line breaking, letter-spacing, weight/style
    ...    \ \ synthesis, `{c:#hex}{b}{i}` runs), glyphs via vello_cpu `glyph_run`, outline
    ...    \ \ text as a real vector stroke. Layouts are cached per (font,size,text,runs,…).
    ...    - Direct path: `painter.scene_direct_ok(comp)` is true when every drawn node is
    ...    \ \ scene-owned; `core/runtime/main.lua` then renders straight into an ImageData and
    ...    \ \ writes it to ffmpeg / md5. `MOONSPLICE_SCENE_DIRECT=0` disables.
    [Tags]    doc    source:cadence@56ddad1:docs/SCENE.md
    Skip    prose

Coverage
    [Documentation]    | node kind | scene | notes |
    ...    |---|---|---|
    ...    | text, kinetic chars | ✅ | wrap, leading (metrics-relative like love), tags, reveal, outline, weight, **`tracking` (letter-spacing, tweenable — scene only)** |
    ...    | rect, circle, flex(color) | ✅ | rx, anchor, group transforms |
    ...    | image, svg, page | ✅ | registered once per file; rx |
    ...    | html | ✅ | Blitz texture, re-uploaded when `progress` changes |
    ...    | vector | ✅ | node box clip, grain scoped to the box, opacity via layer |
    ...    | clip_node mask | ✅ | `clip_invert` falls back |
    ...    | blend | ✅ | alpha multiply screen darken lighten add; subtract/replace fall back |
    ...    | shadow | ✅ | blur layer over a rounded rect |
    ...    | effect_blur / effect_opacity | ✅ | |
    ...    | brightness contrast saturate grayscale sepia invert hue | ✅ | opcode 111 `fx_push`: the node renders into a scratch context sized to its transformed box, `moonsplice-effects::apply` (rlib) runs the same maths as the love shader, composited back as an image. `effects` eval vs love: mean 1.3–2.0/255, max 8 outside glyphs (glyph diffs are the font stack, see Determinism) |
    ...    | video | ✅ | yuv420 → `ed_yuv420_to_rgba` (fixed-point BT.709, row-parallel) → slot (opaque, no premultiply); rgba/jpg frames → slot. Image opacity goes through an opacity layer (vello_cpu 0.2 panicked on sampler alpha ≠ 1; kept on 0.3 so frames did not move) |
    ...    | fx chain: bloom glow blur vignette chroma grain tonemap pixelate posterize filmgrain kawase | ✅ | opcode 112 `chain_push`: children stream into a scratch frame the size of the fx box, `scene/src/fx.rs` runs the same maths as the GLSL passes, result composites in z-order. `fx_native` eval vs love: mean 1–2/255 per pass (grain/filmgrain differ in noise pattern only; max diffs sit on circle edges where love's polygonal circles and vello's AA disagree) |
    ...    | fx chain: worley | ✅ | pass 12 in `scene/src/fx.rs` |
    ...    | fx chain: shadertoy | ✅ GPU | the comp's own GLSL: naga (glsl → wgsl) on Bevy's wgpu device (`render/`), between CPU pass runs |
    ...    | perspective (rect/surface/image/svg/page with `perspective = true`) | ✅ | opcode 114: `scene/src/persp.rs` warps the node's flat page through the camera (inverse homography + thin-lens defocus), row-parallel, stage sized to the projected corners |
    ...    | lottie | ✅ | opcode 116: velato walks the composition into the frame's own anyrender Scene (`scene/src/lottie.rs`); pre-5.5 keyframes upgraded at load; image layers inside a Lottie not drawn |
    ...    | spritesheet, spine, chart, ornament, particles, draw, surface | ✅ | drawn through `core/runtime/sceneg.lua`, the `love.graphics` subset recorded into the stream |
    ...    | displace | ✅ | opcode 115: `scene/src/displace.rs` |
    ...    | world/mesh/camera/light | ✅ via slot | `scene3d/` (wgpu) renders into an image slot |
    [Tags]    doc    source:cadence@56ddad1:docs/SCENE.md
    Skip    prose

Determinism
    [Documentation]    Same thread count ⇒ byte-identical frames (checked, `moonsplice golden`). Different
    ...    thread counts differ by ±1 in ~0.03% of bytes, so goldens are scoped by
    ...    `MOONSPLICE_SCENE_THREADS` (default 0 = single). Any filter layer in a frame pins
    ...    that frame to single-threaded rendering (vello_cpu constraint).
    ...
    ...    Love-path hashes additionally depend on the LÖVE build: the checked-in
    ...    `<case>.md5` goldens were captured on the vendored LÖVE 12 fork (NotoSans).
    ...    Homebrew LÖVE 11.5 draws Vera, so every text-bearing love case differs there
    ...    and `drop` fails (`newRectangleShape(body, …)` is the 12 API). Scene-owned
    ...    comps bundle NotoSans and hash the same under either LÖVE — that is the
    ...    portability argument for the direction. `moonsplice golden` records the love version
    ...    in the tag and prints a tag mismatch before the frame counts.
    [Tags]    doc    source:cadence@56ddad1:docs/SCENE.md
    Skip    prose

Tools
    [Documentation]    - `moonsplice golden capture|compare [case…]` — per-frame md5 for every eval case,
    ...    \ \ tagged with platform/threads/scene/love. Love-path goldens are
    ...    \ \ `.robot/golden/<case>.md5` (`MOONSPLICE_SCENE=0`), scene-path goldens
    ...    \ \ `<case>.scene.md5` (the default), captured 2026-09-16 for 41/42 cases (`drop` needs LÖVE
    ...    \ \ 12). Compare in scene mode after any port, eyeball `moonsplice eval --open`, then
    ...    \ \ recapture deliberately.
    ...    - `MOONSPLICE_PROFILE=1` prints `PROF scene=… flushes=…` and `PROF direct=1`.
    [Tags]    doc    source:cadence@56ddad1:docs/SCENE.md
    Skip    prose

Plan for the remaining gaps (2026-09-16)
    [Documentation]    Ordered by leverage per hour. Each item names its proof so it can be closed
    ...    without opinion.
    ...
    ...    *1. Lint blind spots (hours) — first, because they lie about every reel*
    ...    - **reveal is motion.** Add `reveal` to the amplitude calculation in
    ...    \ \ `core/moonsplice/lint.lua`: Δreveal × visible glyph count, normalised like x/y.
    ...    - **outlined text has contrast.** `contrast_static` uses `outline_color` when
    ...    \ \ `outline > 0`; fill colour alone is not what the eye sees.
    ...    - **vector draw callbacks are measurable.** Lint already samples the timeline
    ...    \ \ per frame; give it a recording builder (pure Lua, same verbs as
    ...    \ \ `core/runtime/scene.lua`) and call `draw(v, t)` at each sample. The diff between
    ...    \ \ consecutive command streams is real motion amplitude. No FFI, host-free.
    ...    \ \ Proof: both `comps/examples/vv` reels lint with zero false frozen-span findings and
    ...    \ \ a deliberately static vector node still trips one.
    ...
    ...    *2. 3D world and shader-fx output into scene slots (hours)*
    ...    `world` (wgpu) and `fx` (Moonshine GLSL) already produce an RGBA buffer per
    ...    frame. Feed it to `scene.image_slot` like html does, so one frame composites in
    ...    one rasterizer with correct z-order and no per-node flush. Proof: `world3d` and
    ...    `fx` evals render on the direct path (`PROF direct=1`) and match their goldens
    ...    within antialiasing.
    ...
    ...    *3. Colour effects — DONE 2026-09-16*
    ...    Landed as opcode 111 (see Coverage). The scratch context is the node's
    ...    transformed box, not the frame, so blur edges match love; per-pixel maths is
    ...    the `effects` crate as an rlib. Original plan:
    ...    vello_cpu 0.2 has blur/drop-shadow/flood/offset only. Add opcode `111
    ...    colour_push kind amount … 105 pop`: render the enclosed commands into a scratch
    ...    `Pixmap`, run the per-pixel maths that `effects/` already has (make it an rlib
    ...    dependency of `scene/`), composite back as an image paint. Covers brightness,
    ...    contrast, saturate, grayscale, sepia, invert, hue-rotate, and gives tonemap,
    ...    posterize, pixelate a home. Proof: `effects` eval hash-stable in scene mode,
    ...    side-by-side with love within ±2/255 per channel.
    ...
    ...    *4. Video frames into slots — DONE 2026-09-16*
    ...    `video` and `video_layers` render on the direct path and match love visually.
    ...    Per-frame draw in scene mode is 5.6 ms / 7.0 ms vs love's 1.8 + 1.4 readback /
    ...    2.6 + 1.4: the CPU YUV→RGBA (row-parallel) plus the slot copy cost more than
    ...    love's GPU yuv shader. Next win if it matters: hand the Y/U/V planes to
    ...    `cs_image_update` and convert straight into the premultiplied Pixmap (one copy
    ...    fewer). Original plan:
    ...    `painter.lua` video branch: the jpg-frames and rgba paths call
    ...    `scene.image_slot(node, imagedata, changed)` per frame; the yuv path goes
    ...    through `ed_frame_rgba` (the one pinned YUV→RGB path, DESIGN §4). Add an
    ...    opaque fast path to `cs_image_update` (skip premultiply when alpha is 255).
    ...    Proof: `video` and `video_layers` evals on the direct path at ≥ the love fps.
    ...    Blocker: Wikimedia assets 429; fetch with backoff or mirror to R2.
    ...
    ...    *5. fx chain as layers — DONE 2026-09-16*
    ...    Landed as opcode 112 (see Coverage) plus `.robot/fixtures/lint/fx_opaque.lua`. A chain
    ...    goes native when every pass has a CPU port and every child is scene-owned;
    ...    otherwise the whole node takes the love canvas + slot path, so mixed chains
    ...    (the `fx` eval, which ends in shadertoy) still work. Original plan:
    ...    Once 3 lands, most of the chain is expressible without GLSL: bloom/glow =
    ...    blur layer + `Plus` blend, vignette = radial gradient multiply, chroma =
    ...    three offset copies with channel masks, grain exists. Worley and shadertoy stay
    ...    GLSL and are declared an escape hatch like `s:draw` (lint marks them opaque).
    ...    Proof: per-effect A/B against love on the `fx` eval; agents get the same
    ...    `s:fx{}` API.
    ...
    ...    *6. Perspective surfaces — DONE 2026-09-16 (slot route)*
    ...    `camera`, `perspective_focus`, `perspective_explode` render on the direct path
    ...    and match love (mean < 0.7/255, edge AA only). Original plan:
    ...    Projective transforms are outside vello (affine only). Keep the love homography
    ...    shader and route its output through a slot (item 2). A CPU warp with the same
    ...    depth-defocus is possible in Rust if love ever goes preview-only.
    ...
    ...    *7. Retire the canvas path — DONE 2026-09-16*
    ...    Gate met: `MOONSPLICE_SCENE=1 moonsplice eval` 42/42 pass (`drop` needs LÖVE 12), contact
    ...    sheets eyeballed, scene goldens captured for every case. The rasterizer is now
    ...    the default (`core/runtime/scene.lua`: on when the dylib is present,
    ...    `MOONSPLICE_SCENE=0` opts out); `moonsplice golden` defaults to the `.scene.md5` files.
    ...    LÖVE-as-shell vs mlua: LÖVE stays the shell while the GLSL escape hatches
    ...    (shadertoy, worley, s:draw, perspective, world) still paint through love
    ...    canvases into slots — see .robot/docs/design.robot §2 for the reasoning and the revisit
    ...    condition. Original plan:
    ...    Gate: all 42 evals green in scene mode, goldens recaptured, `moonsplice eval --open`
    ...    eyeballed. Then direct is the default and the canvas is the fallback. Only
    ...    then decide LÖVE-as-shell vs mlua hosting LuaJIT: render/hash would drop the
    ...    love dependency entirely; preview keeps it.
    [Tags]    doc    source:cadence@56ddad1:docs/SCENE.md
    Skip    prose

