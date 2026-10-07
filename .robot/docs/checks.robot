*** Settings ***
Documentation    moonsplice verification system — full scope
...
...    > **Status 2026-08-01:** Tier 0 ✅ (compile errors live) · Tier 1 ✅ `moonsplice lint`
...    > shipped — ~24 codes implemented incl. group-aware motion density (kinetic chars
...    > = one unit), spring-overshoot detection by sampling, off-frame life analysis
...    > (`parked_visible`/`off_frame_linger`/`never_onscreen`), brand tokens, audio
...    > rules; dogfooded on kinetic_promo (56→5 findings after fixes; caught 2 real
...    > bugs incl. spring-on-opacity). Tier 2 ✅ `moonsplice check` shipped — seek-grid
...    > pixel audits; caught yellow-text-over-red-slab 1.88:1 that tier 1 cannot see;
...    > cleared tier 1's vector-content blind spot (frozen not confirmed). Tier 3
...    > `moonsplice probe` — checks/probe.py + query.py in progress (model setup running).
...    > Known v1 sampler limits: check's 16×16 luma grid can miss small text
...    > (blank_frame false positives near sparse frames); contrast ring uses size
...    > heuristic not measured bbox.
...
...    Three ground truths, three tiers. Each tier is cheaper than the one after it and
...    runs first. Restraint and quality live here — in checks — not in prose guidance.
...
...    | tier | command | ground truth | cost | when |
...    |------|---------|--------------|------|------|
...    | 0 | (compile) | recorder state | free | every load |
...    | 1 | `moonsplice lint` | compiled timeline + scene graph | ms, no render | every edit |
...    | 2 | `moonsplice check` | rendered pixels | seconds (seek grid) | before preview |
...    | 3 | `moonsplice probe` | embeddings (perception) | ~render-speed | before delivery |
...
...    The structural advantage over HyperFrames/Remotion: their tools scrape a DOM to
...    *reconstruct* intent; our compiled timeline **is** intent. Most of what they can
...    only say in prose ("no more than 2 same-ease tweens per scene") is a computable
...    rule here. HF ships ~12 automated finding codes; this scope defines ~40.
...
...    ---
Metadata    Source    cadence@56ddad1:CHECKS.md

*** Test Cases ***
Tier 0 — compile errors (exist today)
    [Documentation]    - overlapping tweens on the same node.prop (incl. wiggle, path x/y)
    ...    - script exceeds static comp duration
    ...    - banned APIs in comps: `os.time/clock/date`, `io.*`; RNG force-seeded
    ...    - non-animatable prop in tween; missing required node props (`w/h` on svg/lottie…)
    ...    - unknown ease name; `after={ref}` referencing a later/non-audio node
    [Tags]    doc    source:cadence@56ddad1:CHECKS.md
    Skip    prose

Tier 1 — moonsplice lint (static timeline analysis)
    [Documentation]    No rendering. Evaluate the compiled segment table + scene graph analytically.
    ...    Every rule has a code, a severity, a numeric threshold (configurable in
    ...    `moonsplice.toml`), and an escape hatch (`node.initial.lint_allow = {"code", ...}` or
    ...    comp-level `lint_allow`). Output `--json` with `_meta`, one finding per row:
    ...    `{code, severity, node_id, t0, t1, measured, threshold, suggestion}`.
    ...
    ...    *Motion restraint (their prose → our rules)*
    ...
    ...    | code | rule | default threshold |
    ...    |------|------|-------------------|
    ...    | `motion_density` | summed normalized amplitude (Δvalue/axis-dimension) per 0.5s bucket exceeds budget | 3.0 |
    ...    | `competing_beats` | ≥2 nodes with large amplitude (>0.4 normalized) in the same bucket | error at 3 |
    ...    | `ease_monoculture` | >N tweens sharing one ease within any 2s window | 2 |
    ...    | `overshoot_on_opacity` | spring/back/elastic ease on `opacity` segment | error |
    ...    | `overshoot_budget` | overshoot-family eases > X% of all tweens | 20% |
    ...    | `stagger_runaway` | stagger total span (`each×(n-1)`) exceeds cap | 0.5s |
    ...    | `tempo_flat` | ratio of slowest to fastest scene segment-density < X | 2.0 (info) |
    ...    | `cold_open` | first visible motion starts at exactly t=0 | warn |
    ...    | `flash_cut_rate` | zero-duration `set` steps per second exceed cap | 3/s |
    ...    | `wall_of_motion` | no bucket with density <0.5 for longer than X s (no rest beats) | 4s |
    ...    | `frozen_span` | visible nodes, zero active segments for > X s | 2s (error at 3s, HF parity) |
    ...    | `exit_symmetric` | exit duration ≥ entrance duration for same node (exits should be 60-70%) | info |
    ...    | `fx_opaque` | `s:fx` chain contains a GLSL pass (`worley`, `shadertoy`) lint cannot see through, same as `s:draw` | info |
    ...
    ...    *Geometry & visibility (analytic evaluation at segment endpoints + extrema)*
    ...
    ...    | code | rule |
    ...    |------|------|
    ...    | `off_frame` | node bbox fully outside canvas while opacity>0 — evaluated at segment endpoints AND ease extrema (spring overshoot peak is closed-form) |
    ...    | `partial_escape` | bbox >X% outside canvas held over multiple segments (5%) |
    ...    | `text_min_size` | text `size` (after scale) below floor at any visible time (32px @1080-wide, scaled) |
    ...    | `safe_area` | text/logo center inside margin band (80px sides / 100px top-bottom, scaled) |
    ...    | `zero_area` | w/h/scale animated to ≤0 while visible |
    ...    | `subpixel_drift` | tween Δ < 1px over > 0.5s (invisible motion = wasted segment) |
    ...
    ...    *Color, brand, type*
    ...
    ...    | code | rule |
    ...    |------|------|
    ...    | `contrast_static` | text color vs the color of the largest node underneath at that time (both known values) — WCAG 4.5:1 / 3:1 large; suggestion = nearest passing color in same OKLab direction |
    ...    | `brand_token` | comp color not within ΔE of any `brand.json` palette entry (when a brand file is declared) |
    ...    | `brand_font` | text node without `font=` when brand fonts are declared |
    ...    | `palette_sprawl` | > N distinct colors across comp (8) |
    ...    | `accent_overuse` | declared accent color present in > X% of visible area-time (one-voltage-moment rule, computable from node areas) |
    ...
    ...    *Audio (from resolved clips + envelope math, no decode)*
    ...
    ...    | code | rule |
    ...    |------|------|
    ...    | `audio_tail` | clip extends past comp duration (clamped silently today → surface it) |
    ...    | `audio_gap` | > X s with zero audible clips in a comp that has any audio (2s) |
    ...    | `vo_collision` | two speech clips (tts) overlapping in time |
    ...    | `duck_missing` | music/bed volume > X while a tts clip plays (0.3) — until envelope tweens exist, checks static volumes |
    ...    | `sfx_orphan` | sfx clip not within 0.25s of any visual segment boundary (impact without a beat) |
    [Tags]    doc    source:cadence@56ddad1:CHECKS.md
    Skip    prose

Tier 2 — moonsplice check (rendered pixels)
    [Documentation]    Seek-grid render (default 9 samples + every scene boundary + lint-flagged times;
    ...    `--samples`, `--at`). One process boot. Audits:
    ...
    ...    - `render_error` — any runtime error, missing asset, decode failure at sample
    ...    - `blank_frame` — frame variance below floor while nodes claim visibility
    ...    - `frame_diff` — consecutive-sample pixel delta: confirms `frozen_span` and
    ...    \ \ `wall_of_motion` against real pixels (post-fx/shader effects invisible to tier 1)
    ...    - `contrast_measured` — sampled fg/bg from actual pixels at text bboxes (we know
    ...    \ \ the bboxes analytically — no OCR needed); catches gradient/video backgrounds
    ...    \ \ tier 1 can't
    ...    - `bounds_measured` — rendered content breaching canvas (vector/lottie/html nodes
    ...    \ \ whose content exceeds declared w/h)
    ...    - `golden` — per-frame hash vs golden (same machine+engine); SSIM tier for
    ...    \ \ cross-machine (thresholds calibrated like r2hf: set ~0.02 below measured p05)
    ...    - `determinism` — render-twice + shuffled-order hash compare (exists in tests;
    ...    \ \ promoted to a check any comp can run)
    ...
    ...    Escape hatches carry from tier 1. `check --snapshots` writes annotated frames +
    ...    per-finding crops (agent eyeballs). Exit code gates on held errors only
    ...    (persistence model: single-sample transients demote to info — HF parity).
    [Tags]    doc    source:cadence@56ddad1:CHECKS.md
    Skip    prose

Tier 3 — moonsplice probe (perceptual / embeddings)
    [Documentation]    The locked Mac-first stack (see .robot/docs/design.robot §5): **MobileCLIP2-S2** (frames,
    ...    text-queryable), **C-RADIOv3-B** (patch-level spatial + text via adaptor),
    ...    **X-CLIP-B** (temporal windows), **CLAP** (audio windows). Probe embeds the
    ...    rendered output (stride ~4/s + scene boundaries) into a sidecar
    ...    (`comp.probe.npz`: frame vectors, patch grids, clip-window vectors, audio-window
    ...    vectors, derived signals) — then checks and queries run against the sidecar
    ...    without re-embedding.
    ...
    ...    **Runtime architecture (decided 2026-08-01): in-process, no Python sidecar.**
    ...    `embed/` = Rust cdylib on **ONNX Runtime** (`ort` crate) + `tokenizers`, loaded
    ...    via LuaJIT FFI like decode/layout/vector/html. CoreML EP → ANE on Mac; CUDA EP
    ...    on the 4070 box. Models as one-time ONNX exports (community exports exist;
    ...    Python only as an offline export tool if an export is missing). Frames feed
    ...    straight from the render loop / decode crate's in-memory RGBA — no ffmpeg
    ...    frame-extraction step. The Python implementation (`checks/probe.py`) is kept as
    ...    the validation baseline (score-parity harness) and dev tool, not the runtime.
    ...
    ...    *Assertions (comp-declared, compiled to embedding queries)*
    ...
    ...    ```lua
    ...    s:assert{ visible = "company logo", from = 2, to = 4, min = 0.75 } \ \ -- MobileCLIP2 prob
    ...    s:assert{ region = "top-right", visible = "logo", from = 2, to = 4 } -- C-RADIO patch crop
    ...    s:assert{ audible = "female speech", from = 1, to = 8 } \ \ \ \ \ \ \ \ \ \ \ \ \ -- CLAP margin
    ...    s:assert{ mood = "calm ocean scenery", from = 0, to = 4, min = 0.6 } -- semantic scene check
    ...    s:assert{ motion = "camera pans across city", from = 4, to = 8 } \ \ \ \ -- X-CLIP window
    ...    ```
    ...
    ...    Missing/never-crossing assertion = loud failure (HF's selector-missing rule).
    ...
    ...    *Derived signals (free from embedding deltas)*
    ...
    ...    - `cut_detect` — frame-embedding distance spikes = actual cuts; verified against
    ...    \ \ timeline's declared scene boundaries (`cut_unplanned` if mismatch)
    ...    - `freeze_detect` / `motion_energy` — perceptual confirmation of tier-1/2 signals
    ...    - `black_blank_detect` — embedding collapse to known black/blank cluster
    ...    - `vo_sync` — CLAP speech-activity envelope vs tts clip windows (mix actually
    ...    \ \ audible when the timeline says it is; catches mix bugs tier 1 can't)
    ...    - `caption_sync` — (once word timestamps land) on-screen text-region change times
    ...    \ \ vs word times, ±1 frame
    ...
    ...    *Query surface (agent tooling)*
    ...
    ...    - `moonsplice query <comp> "text"` → timestamped cosine hits (which second shows X)
    ...    - `moonsplice describe <comp>` → per-scene nearest-text summaries + contact sheet
    ...    - golden embeddings: `probe --golden` stores vectors; CI fails on drift > ε —
    ...    \ \ survives encoder/font drift that breaks pixel hashes (PLAN M5)
    [Tags]    doc    source:cadence@56ddad1:CHECKS.md
    Skip    prose

Blue sky (ranked by leverage/feasibility)
    [Documentation]    1. **Saliency-weighted restraint** — C-RADIO patch features → per-frame saliency
    ...    \ \ \ map. `motion_density` weighted by where the eye actually is; `focus_miss`
    ...    \ \ \ finding when the intended beat (largest amplitude) is NOT the salient region.
    ...    \ \ \ The "motion hierarchy" rule, measured instead of preached.
    ...    2. **Perceptual brand check** — embed the brand's captured `page.png` regions;
    ...    \ \ \ rendered frames must stay within distance band of brand cluster → "does this
    ...    \ \ \ even look like their brand" as a number. Pairs with `moonsplice-capture`.
    ...    3. **Arc grammar** — X-CLIP window classification over the piece → build/breathe/
    ...    \ \ \ resolve curve extraction; flag monotone-energy pieces (`arc_flat`).
    ...    4. **Suggest-and-fix lint** — every finding carries an executable patch
    ...    \ \ \ (`suggestion = { node, prop, value }`); `moonsplice lint --fix` applies safe ones
    ...    \ \ \ (HF's suggestedColor generalized to timing/ease/amplitude).
    ...    5. **Reference-corpus scoring** — embed a curated corpus of strong motion work
    ...    \ \ \ (X-CLIP + MobileCLIP2); score new renders by distribution distance; per-scene
    ...    \ \ \ "which reference is this closest to". Taste, approximated by retrieval.
    ...    6. **A/B perceptual diff** — `moonsplice compare a.lua b.lua`: render both, report
    ...    \ \ \ per-scene embedding distance, assertion deltas, and a stitched side-by-side
    ...    \ \ \ (HF grade-compare analog, but semantic not just visual).
    ...    7. **VLM judge pass** (network tier, optional) — keyframe strip → multimodal LLM
    ...    \ \ \ critique with the lint findings as context; prose review grounded in
    ...    \ \ \ machine findings rather than replacing them.
    ...    8. **Host-parity fleet** — same comp on love host vs rust host vs cuda-box:
    ...    \ \ \ SSIM + embedding-drift matrix in CI (the D1 vello_cpu path makes this real).
    ...    9. **Loudness pipeline** — EBU R128 loudnorm analysis pass; `lufs_target`,
    ...    \ \ \ `true_peak`, `vo_music_lra` findings; platform presets (Reels/TikTok specs).
    ...    10. **Auto-storyboard** — `probe` emits a timeline map (scene boundaries, motion
    ...    \ \ \ \ energy curve, audio envelope, assertion states) as one PNG/JSON — the agent's
    ...    \ \ \ \ "watch the video" replacement, one glance.
    [Tags]    doc    source:cadence@56ddad1:CHECKS.md
    Skip    prose

Implementation order
    [Documentation]    1. Tier 1 static analyzer (pure Lua over compiled timeline — biggest value, no deps)
    ...    2. Tier 2 seek-grid + measured contrast/bounds (reuses render loop)
    ...    3. Tier 3 probe sidecar + assert/query (models already locked; Python sidecar
    ...    \ \ \ process, same stack as 11l media-DNA)
    ...    4. Blue-sky #1/#2/#4 (saliency, brand check, --fix) — each is a week-ish
    ...    5. `moonsplice.toml` thresholds + JSON output contract stabilize alongside tier 1
    [Tags]    doc    source:cadence@56ddad1:CHECKS.md
    Skip    prose

