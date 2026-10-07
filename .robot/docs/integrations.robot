*** Settings ***
Documentation    moonsplice — integration plan
Metadata    Source    cadence@56ddad1:INTEGRATIONS.md

*** Test Cases ***
Validation status (2026-08-01)
    [Documentation]    | item | status | result |
    ...    |------|--------|--------|
    ...    | C1 Lottie | ✅ **integrated** — as **ThorVG 1.1** (brew, C API, LuaJIT FFI direct; rlottie superseded — stale upstream, ThorVG is its successor). `s:lottie{}` live, determinism verified, premultiplied-alpha blend correct. `comps/examples/lottie_test.lua`. Bonus found: ThorVG scene effects (gaussian blur, drop shadow) — future vector post-fx. | render 21fps w/ 700²+900² vector layers over video |
    ...    | C2 resvg | ✅ **integrated** — brew resvg 0.47 (now a Linebender project), resolve-phase raster to content-addressed cache. `s:svg{}` live. `comps/examples/svg_test.lua`. | gradient/dash/text correct |
    ...    | D3 Taffy | ✅ **integrated** — `layout/` crate (taffy 0.9, 599K cdylib), `s:flex{}` live: row/column, justify/align/gap/pad/wrap. Solved in compile's `post_scene` hook so tweens see final positions. `comps/examples/flex_test.lua`. | build 11s, solve sub-ms |
    ...    | D1 vello_cpu | ✅ **integrated** — `vector/` crate: `s:vector{draw=fn(v,t)}` display-list node (rect/rrect/circle/bezier path fill+stroke/2-stop linear gradient), per-frame procedural, full transform motion composes. Full-frame 1080×1920: **60.6 fps render**, determinism PASS. `comps/examples/vector_test.lua`. (Spike numbers: 526 fps raw.) | 60.6 fps full pipeline |
    ...    | D2→node Blitz | ✅ **integrated** — `html/` crate: `s:html` fragments; `s:page` documents (linked CSS/images, **woff2 @font-face**, **script bake at resolve**). `moonsplice-html-shot` replaces Chrome. JS never in `evaluate(t)`. StarlingMonkey has no document — QuickJS + a tiny DOM is the bake engine. `comps/cases/html.lua`, `page.lua`, `page_bake.lua`. | fragments 30-41 fps; pages rasterize once at resolve |
    ...    | D2 Blitz | ✅ **validated** (spike) — 0.3.0-beta.1: headless HtmlDocument → paint_scene → vello_cpu buffer works; determinism PASS; **26.9 fps at 1080×300 in worst-case full-reparse-per-frame mode** (DOM mutation path would be far faster). Rendered a production-quality lower third (flexbox, gradient, radius, box-shadow, real text) with zero Chrome. Version pin gotcha: `anyrender_vello_cpu` 0.14 ↔ `anyrender` 0.11 (adapter lags core). `s:html{}` + HF-migration play both live options → promote to feature-flagged integration next. `spikes/blitz_spike/`. | DETERMINISM PASS, 26.9 fps worst-case |
    ...    | non-integrations | ✅ documented below | — |
    ...
    ...    Roadmap for ecosystem libs + pipelines. Rule for every entry: **seek-safe or it
    ...    doesn't ship** — stateless (pure f(t)), or stateful-but-baked at compile time.
    ...    Effort: S = day-ish, M = days, L = week+.
    [Tags]    doc    source:cadence@56ddad1:INTEGRATIONS.md
    Skip    prose

Phase A — pure Lua/LÖVE, no new deps
    [Documentation]    | # | integration | what moonsplice gets | how | effort |
    ...    |---|-------------|-----------------|-----|--------|
    ...    | A1 | **moonshine** (vendor) | glow/bloom, gaussian blur, chromatic aberration, vignette, grain, godrays | ✅ **integrated** — `s:fx{ chain={...}, w,h }` flattens children to a canvas; uniforms `fx_bloom` / `fx_vignette` / `fx_chroma` / `fx_grain` / `fx_glow` / `fx_blur` tween on the timeline. Shadertoy `mainImage` sources convert to a LÖVE pass (`iTime=t`). `comps/cases/fx.lua`. **LYGIA/POSTER extras:** dual-kawase, ACES tonemap, posterize, pixelate, filmgrain, worley (`comps/cases/grade.lua`). Tiny `#include` concatenator in `core/runtime/fx.lua`. Existing bloom hashes unchanged. | seek-safe shaders |
    ...    | A2 | **noise / wiggle** | After Effects `wiggle()` — organic drift on any prop | ✅ **integrated** — `t:wiggle(node, prop, { duration, amp, freq, seed })`. Pure Lua value noise (not `love.math.noise`, so the rust/web hosts match). Optional Worley domain-warp is an `s:fx` pass (`worley`). `comps/cases/motion.lua`. | S |
    ...    | A3 | **easing expansion** | bounce family + CSS-compat `cubicBezier(x1,y1,x2,y2)` | ✅ **integrated** — `bounceIn/Out/InOut`, `elasticIn/InOut`, `ease.cubicBezier`. Curves from flux/Penner; no timer. `comps/cases/bounce.lua`. | S |
    ...    | A4 | **audio-reactive curves** | music-video pulses ("scale to the beat") | ✅ **integrated** — `audio{ follow=true }` bakes 50 Hz PCM energy at resolve; `t:follow(node, prop, source, { gain, base, duration })` records a bake segment. Raw sample tables also accepted. `comps/cases/pulse.lua`. | M |
    [Tags]    doc    source:cadence@56ddad1:INTEGRATIONS.md
    Skip    prose

Phase B — engineered features (Lua, ours)
    [Documentation]    | # | feature | design | effort |
    ...    |---|---------|--------|--------|
    ...    | B1 | **seek-safe particles** | `s:particles{ n, seed, emit_window, life, vel, spread, gravity, sprite }`. Each particle i = closed-form f(t − birth_i) from hash(seed, i) params. No simulation state, any-order render. Competitors can't do this (HF bans particles outright). | ✅ **integrated** — `s:particles{ seed, n, life }`. `comps/cases/particles.lua`. |
    ...    | B2 | **kinetic typography** | Text node splits to per-char subnodes (Font:getWidth incremental layout at compile); `t:stagger(title, dur, props, { each = 0.05, ease, from = "center" })` GSAP-style. | ✅ (prior) + **wrap/tagged type-on** — `s:text{ wrap=, reveal=, text="{c:#hex}…{/c}" }`. `comps/cases/type_wrap.lua`. |
    ...    | B3 | **physics bake** | Compile-phase Box2D (built into LÖVE) sim: fixed dt 1/240, seeded, run once → sample body transforms → ordinary timeline segments. `s:physics_group{...}` + `t:drop(nodes, {...})` sugar. Falling/colliding letters in one line. Render stays pure. | ✅ **integrated** — `t:drop(nodes, { gravity, duration, ground_y })`. `comps/cases/drop.lua`. |
    ...    | B4 | **camera/group transforms** | `s:group{}` with animatable x/y/scale/rotation (pan/zoom scenes, parallax). Prereq for B1–B3 composability. | ✅ (prior) |
    ...    | B5 | **mesh displacement** | Image or rasterized type as a UV grid, vertex shader warp. `s:displace{ src\\|text, cols, rows, amp, freq }`. | ✅ `comps/cases/displace.lua` |
    ...    | B6 | **Aseprite spritesheet** | Frame-addressed sheet. `s:spritesheet{ src, fps }` plus Aseprite JSON. | ✅ `comps/cases/spritesheet.lua` |
    ...    | B7 | **HSLuv / OKHSL color** | Color tweens that don't go muddy; brand palettes | ✅ `color_space = "hsluv"` / `"okhsl"`; `e.palette{ h, n, s, l0, l1 }`. `comps/cases/hsluv.lua`, `comps/cases/okhsl.lua`. |
    ...    | B8 | **charts** | Data as motion | ✅ `s:chart{ type="line\\|area\\|bar\\|stack\\|pie\\|arc", data=, reveal=, mix=, stroke="rough" }`. d3-shape port. `comps/cases/chart.lua`. |
    ...    | B9 | **ornaments** | Motion-bumper primitives | ✅ `s:ornament{ kind="star\\|compass\\|egg\\|linker" }`. Polylines (vello `Builder:polyline` too). `comps/cases/ornaments.lua`. |
    ...    | B10 | **SDF type** | Outlines / weight without re-raster TTF | ✅ `s:text{ outline=, weight=, outline_color= }` coverage SDF shader. `comps/cases/type_sdf.lua`. |
    [Tags]    doc    source:cadence@56ddad1:INTEGRATIONS.md
    Skip    prose

Phase C — FFI integrations (decode-crate pattern: Rust/C cdylib → LuaJIT FFI)
    [Documentation]    | # | integration | pipeline unlocked | how | effort |
    ...    |---|-------------|-------------------|-----|--------|
    ...    | C1 | **rlottie** | **After Effects → Bodymovin/Lottie → moonsplice** | C API (`lottie_animation_from_file`, render frame N into RGBA buffer) → same replacePixels path as video. `s:lottie{ src, from, duration }`. Frame-addressed = seek-safe. | M |
    ...    | C2 | **resvg** (Rust, maintained) | real SVG: logos, icons | Preferred over reviving TÖVE: resvg has a C API, best-in-class correctness. Rasterize at resolve (per needed scale) or runtime FFI. `s:svg{ src, w, h }`. | M |
    ...    | C3 | **rive-rs** | Rive interactive/vector anims | ✅ API — `s:rive{ src, w, h }` is frame-addressed like Lottie. Runtime dylib (`moonsplice_rive`) is not bundled yet; nodes skip until the crate ships. | M |
    ...    | C4 | **spine-lua** | 2D skeletal character anim | ✅ **integrated** (seek-safe subset) — `s:spine{ skeleton=, animation= }`. Bone rotate/translate/scale keys evaluated at t. `comps/cases/spine.lua`. Official runtime meshes still optional. | S |
    ...    | C5 | **LPeg / captions** | SRT/ASS caption parsing | ✅ **integrated** — `s:captions{ cues= }` or `src=` (.srt/.csv). Pure-Lua parser (LÖVE has no lpeg.so). Cue table → text steps. `comps/cases/captions.lua`. | S |
    ...    | C6 | **scene3d** (glam + gltf + wgpu) | Real 3D as a Lottie-shaped layer | ✅ **integrated** — `scene3d/` cdylib, C ABI, `ffi.load`. `s:world{w,h}` is an offscreen RGBA node; `s:mesh` / `s:light` parent into it. Pose from `t`, raster into ImageData. CPU Lambert fallback if wgpu has no adapter. Not Bevy/Godot — their loops fight seek. `comps/cases/world3d.lua`. Shared plane camera: `s:camera` + `perspective=true`. `comps/cases/camera.lua`. | M |
    [Tags]    doc    source:cadence@56ddad1:INTEGRATIONS.md
    Skip    prose

Phase D — Rust renderers (rust host track)
    [Documentation]    | # | integration | role | notes | effort |
    ...    |---|-------------|------|-------|--------|
    ...    | D1 | **Vello** (+ parley text) | THE painter impl for the headless rust host | Canon already names it: GPU compute 2D, vello_cpu fallback for hash-exact CI renders. Painter trait over vello scene API; comps unchanged. Alpha-status risk accepted — pin a rev. | L |
    ...    | D2 | **Blitz** (DioxusLabs: Stylo CSS + Taffy layout + Vello) | (a) `s:html{}` fragments; (b) `s:page{}` documents + Chrome-free capture; woff2 `@font-face`; script bake (QuickJS + tiny document at resolve — StarlingMonkey has no DOM). Never JS in `evaluate(t)`. | ✅ page + bake + woff2 shipped. Do not embed Servo/Ladybird/Lightpanda/Chrome. | L |
    ...    | D3 | **Taffy alone** (flexbox/grid, Rust) | layout engine for Lua scene graph (no CSS parser) | Lighter alternative to full Blitz if we only want flex layout: expose `s:flex{}` containers; solve at compile per keyframe. Also FFI-able into the love host. | M |
    [Tags]    doc    source:cadence@56ddad1:INTEGRATIONS.md
    Skip    prose

Sequencing
    [Documentation]    A1 → A2 → A3 (days, immediate visual payoff) → B4 → B1 → B2 (the "wow" tier)
    ...    → C1 rlottie (ecosystem unlock) → C2 resvg → A4 → B3 → C3–C5 opportunistic.
    ...    D-track runs parallel with the rust host build; D3 Taffy can land early (FFI into
    ...    love host) if layout pressure shows up before the rust host exists.
    [Tags]    doc    source:cadence@56ddad1:INTEGRATIONS.md
    Skip    prose

Explicit non-integrations
    [Documentation]    - love.graphics.newParticleSystem, hump.timer, raw Box2D at render time — stateful,
    ...    \ \ break seek. Replaced by B1/B3 designs.
    ...    - TÖVE revival — superseded by resvg (C2) unless animated vector morph demand appears.
    ...    - GStreamer, libmpv — rejected in .robot/docs/design.robot §4.
    ...    - **cpml** — superseded by `core/moonsplice/math3d.lua` (look-at, euler quats) plus the
    ...    \ \ `scene3d` crate (glam). Do not vendor cpml.
    ...    - **Lucide / Phosphor / Tabler as Lua** — icons are SVG. `s:svg` + resvg is the icon system.
    ...    \ \ Do not invent an icon font.
    [Tags]    doc    source:cadence@56ddad1:INTEGRATIONS.md
    Skip    prose

