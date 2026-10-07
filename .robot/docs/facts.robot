*** Settings ***
Documentation    The fact log — one grammar for what a comp is and what a clip shows
...
...    Status: built 2026-09-17, `vision/moonsplice_vision/{facts,lower,perceive,…}.py`. This is the layer
...    between Moonsplice and an editing model. It grew out of the vision MCP (`.robot/docs/vision.robot`), which
...    answers *how do we show a model a frame*; this answers the question after it — **what does the model
...    read, and how does what it says come back as Lua.**
Metadata    Source    cadence@56ddad1:docs/FACTS.md

*** Test Cases ***
Why not just show the model the video
    [Documentation]    Every measurement says frontier models cannot edit video from pixels. On VEBench, temporal IoU for
    ...    localizing an edit sits between 0.00 and 0.11. On AgenticVBench, the best agent scores 31% where
    ...    humans score 81–95%. Our own small eval agrees in shape: on five stock clips, five models got
    ...    81/88 questions right, and every failure clustered in the same three places — telling direction
    ...    across time (who handed what to whom), reading orientation from a single frame, and judging depth
    ...    where the shot has a shallow focus plane.
    ...
    ...    The failures are not a vocabulary problem. Models describe these clips fluently and wrongly. What
    ...    is missing is a representation with *times and identities in it*, which is exactly what a renderer
    ...    has and a caption does not.
    ...
    ...    So: do not ask a model to see. Measure what can be measured, write it in a grammar the model can
    ...    read and write, and lower its edits back to source.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

The grammar
    [Documentation]    Three predicates, event calculus, and nothing else:
    ...
    ...    ```prolog
    ...    holds(Fluent, T0, T1). \ \ \ \ \ \ \ % something true over an interval
    ...    happens(Event, T). \ \ \ \ \ \ \ \ \ \ \ % something that occurred at an instant
    ...    src(Fact, Producer, Conf). \ \ \ % who measured that fact, and how sure the measurement was
    ...    ```
    ...
    ...    **A fact with no `src` line is exact.** That single rule carries the whole design. A comp knows its
    ...    own truth — node ids, boxes, z-order, tween curves, cue times — so the lifter states it flatly. A
    ...    clip is only ever measured, so every perceived fact names its producer and its confidence. A reader
    ...    never has to ask which kind it is holding.
    ...
    ...    ```prolog
    ...    % lifted from motion.lua — exact, no provenance
    ...    entity(circle2, "circle", node("circle2")).
    ...    holds(motion(circle2, dir(right), fast, ease(quadIn)), -0.025, 0.692).
    ...    holds(in_third(circle2, center), 0.633, 1.167).
    ...
    ...    % perceived from woman_9032610.mp4 — every line carries its source
    ...    entity(e3, "camera", seed(3.240)).
    ...    src(entity(e3, "camera", seed(3.240)), vlm_agreement, 0.98).
    ...    holds(out_of_focus(e3), 0.000, 6.480).
    ...    src(holds(out_of_focus(e3), 0.000, 6.480), laplacian, 0.80).
    ...    ```
    ...
    ...    *The vocabulary is words, not numbers*
    ...
    ...    Times are the only numbers in the log, because an edit is a thing you do at a time. Everything else
    ...    is a term an editor would say out loud: `in_third(e, left)`, `in_band(e, lower)`,
    ...    `motion(e, dir(right), fast)`, `shot_scale(e, mcu)`, `camera(dolly(in))`, `facing(e, away)`,
    ...    `approaching(e)`, `speaking(e)`, `action_boundary(s1)`, `same_as(e4, e1)`. Ease curves come back as their names — `ease(quadIn)` — because that is what the
    ...    source says and what an edit must write back.
    ...
    ...    This was a deliberate reversal. A first version emitted coordinates and magnitudes, and reading it
    ...    back, a model could describe the numbers and still not know what to change. Positions became
    ...    thirds, velocities became adverbs, and the log became editable.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

Two sides, one grammar
    [Documentation]    | | comp (`facts.lift`) | footage (`perceive.perceive`) |
    ...    |---|---|---|
    ...    | entities | one per node, id is the node id | one per track, `seed(t)` records where it was found |
    ...    | truth | exact from the scene graph | measured, every line with `src` |
    ...    | motion | fitted to the actual tween, ease name and sub-frame endpoints | regression over a camera-compensated centroid |
    ...    | text | the string the comp drew | OCR, with the boundary bisected |
    ...    | depth | z-order | DA3 relief, cross-checked against focus |
    ...
    ...    Because the two sides share a grammar, a comp that composites a clip produces one log describing
    ...    both, and a producer can be measured against exact truth before it is trusted on footage. That is
    ...    the discipline the whole suite is built on: **no producer is believed on a clip until it has been
    ...    checked on a comp.**
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

Lowering: the log edits the source
    [Documentation]    `lower.lower(comp, edits)` maps node ids back to their constructor spans in the Lua and rewrites
    ...    fields in place. Verbs: `set_prop`, `set_ease`, `set_tween_duration`, `set_cue`.
    ...
    ...    Two properties make it safe. With an empty edit list it returns the source byte-for-byte. And
    ...    because Moonsplice renders deterministically, an edit can be verified by frame hashes rather than by
    ...    eye — retiming one caption cue from 0.55 s to 0.85 s changed exactly nine frames, 0.567–0.833 s, and
    ...    left the other ninety-nine identical.
    ...
    ...    Node ids are matched positionally against the constructors, not by name, because a constructor and
    ...    the node it builds need not share one: `s:captions{}` builds a *text* node whose id is `text6`.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

The agent surface: query, anchor, edit
    [Documentation]    Built 2026-09-18. Until then the fact layer was library code with tests: `facts.lift`,
    ...    `perceive.perceive` and `lower.lower` existed, nothing called them, and there was no way to
    ...    ask a log a question. `moonsplice-agent query` is unrelated — it is embedding search over a
    ...    `.npz` probe sidecar, not the grammar.
    ...
    ...    Four MCP tools now carry it, which also makes them shell commands
    ...    (`bin/moonsplice-vision call <tool> k=v`):
    ...
    ...    | tool | does |
    ...    |---|---|
    ...    | `fact_log(source, words, beats)` | lift a comp or perceive a clip; cached on size+mtime |
    ...    | `fact_query(pattern, sources, min_conf)` | pattern-match one or many logs |
    ...    | `fact_when(source, word, event)` | the time something was said, or a beat/onset |
    ...    | `fact_edit(comp, edits, verify, write)` | rewrite a comp from an assertion, and prove it |
    ...
    ...    *A query is a fact with holes in it*
    ...
    ...    `vision/moonsplice_vision/query.py`. There is no second language: a capitalised atom binds, `_`
    ...    matches anything, a quoted string is always a literal.
    ...
    ...    ```prolog
    ...    happens(release(A, B), T) \ \ \ \ \ \ \ \ \ % every handover, and who did it to whom
    ...    holds(camera(M), T0, T1) \ \ \ \ \ \ \ \ \ \ % every camera move
    ...    holds(text(E, "TYPE"), T0, T1) \ \ \ \ % "TYPE" is a literal, not a variable named TYPE
    ...    ```
    ...
    ...    Three rules earn their keep. `src` lines never come back as results — they are metadata about
    ...    another fact, and a query for `_` that returned them would double every answer. `min_conf`
    ...    filters perceived hits and **never** drops exact ones, because an exact fact has no confidence
    ...    at all and filtering on confidence must not become a way to hide what is certain. And
    ...    `holds(F, T0, T1)` is half-open, so abutting intervals never both match at their shared edge.
    ...
    ...    *Editing by what was said*
    ...
    ...    The comp side used to carry only `says(nid, "the whole sentence")`, which is too coarse to
    ...    anchor to. `lift(want_words=True)` force-aligns any audio node that declares its own `text`
    ...    and emits `happens(word(...))`; `want_beats=True` does tempo, beats and onsets. Both are off by
    ...    default because both cost a pass, and **both carry `src`** — a word timing is measured by the
    ...    aligner even inside an otherwise exact log, and the rule that a fact without `src` is exact
    ...    outranks the convention that a lifted log has none. The header says so when they are on.
    ...
    ...    So an agent edits by speech in two steps, neither of which involves looking at the video:
    ...
    ...    ```
    ...    fact_when \ source=said.lua word=Programmatic \ \ \ \ -> {"times": [1.445]}
    ...    fact_edit \ comp=said.lua edits='[{"verb":"set_cue","node":"text2","index":0,"t0":1.445}]' verify=frames
    ...    \ \ \ \ \ \ \ \ \ \ \ -> 41 frames changed, contiguous, 0.100-1.433s
    ...    ```
    ...
    ...    The same query works on footage, where the words come from `whisper_then_align` instead of
    ...    `forced_align` — ASR discovers the words, alignment times them, because ASR timestamps are
    ...    ~250 ms out and alignment ~15 ms.
    ...
    ...    *Propose, then commit*
    ...
    ...    `fact_edit` does not write unless asked. `write` defaults to False, so an agent proposes,
    ...    reads what the edit would do, and commits separately. Three verify levels: `none` rewrites,
    ...    `facts` lifts before and after and diffs the logs, `frames` also renders both and hashes every
    ...    frame — the only level that can prove an edit touched nothing else.
    ...
    ...    A malformed edit is refused with a reason rather than half-applied, and validation is a dry run
    ...    of the real lowering rather than a second copy of its rules, so the two cannot drift:
    ...
    ...    ```
    ...    {"ok": false, "problems": ["IndexError: rect4 has 0 cues, asked for #0"]}
    ...    {"ok": false, "problems": ["edit 0: unknown verb 'teleport' (have set_cue, set_ease, set_prop, set_tween_duration)"]}
    ...    ```
    ...
    ...    *A bug this surfaced*
    ...
    ...    `props.lua` evaluates a comp *without* the resolve phase, so an audio node that never declared
    ...    `duration` has none — resolve is what fills it in from the media. The lifter fell back to the
    ...    comp's duration, so all eleven narration clips of the lesson comp lifted as playing until the
    ...    end of a 160 s comp, simultaneously. Fixed by probing the media (exact, so no `src`), clamped
    ...    to the comp; regression tests cover the media-length, `media_start` and clamp branches.
    ...
    ...    Coverage: `vision/tests/test_query.py` (15), `test_edits.py` (14), `test_transcript.py` (15).
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

Producers, and what each was measured at
    [Documentation]    | goal | producer | measured |
    ...    |---|---|---|
    ...    | G0 | comp lifter | 43/43 eval cases lift and parse, 3956 facts, no `src` anywhere; identity lowering reproduces all 108 frame hashes |
    ...    | G1 | forced alignment + onset refinement | **17 of 17 words inside one frame** across two constructed comps (worst 16.0 ms, against 33.3 ms for a frame at 30 fps), and clip starts exact. Forced alignment alone got 15 of 17: CTC acoustic models emit late, so a word-initial sonorant is placed near the following vowel rather than at the consonant. That is not a model-quality problem — MMS_FA, wav2vec2 base and large, wav2vec2-lv60k and HuBERT-large all put "land" within 0–5 ms of each other at +50 ms, and the **largest model was the worst** (+114 ms on another word); every one of them is CTC. Snapping each boundary back to an independent energy onset removes the bias: stop and fricative onsets barely move (`past` −7 ms, `quietly` −9 ms), sonorants move 20–50 ms (`rain` +19→−3, `window` +30→−7, `yes` +45→−3). Held out properly — the constants were fixed on comp A and comp B, ten fresh words chosen for sonorant onsets, was then measured once at 10/10 |
    ...    | G1 | audio-visual correlation | in-sync vs out-of-sync margin 0.054 raw → 0.356 with 0.25 s smoothing |
    ...    | G1 | per-turn active speaker | on material where one shape moves on each word and another only in the gaps, every speech turn is attributed to the first and none to the second |
    ...    | G1 | diarization (ECAPA clustering) | 0.000 % speaker confusion over the 11.0 s of a four-turn two-speaker assembly; the same producer emits nothing for one speaker reading for 29 s, and nothing for two voices it cannot separate |
    ...    | G2 | DA3 intrinsics, signed focal trend | **dolly and zoom distinguished on a real test pair**, with two static controls: `zoom(in)` on a true zoom, `dolly(in)` on the man clip, `still` on both controls. Focal ratios 1.22 / 0.92 / 1.00, `focal_rise` +0.14 / −0.06 / +0.01. Without intrinsics a scale change is now `unknown`, never `dolly` — the second clause, which the code had been failing |
    ...    | G3 | camera-compensated motion | three parked cars stay scenery under a dolly; cat clip byte-identical |
    ...    | G4 | VLM cross-model grounding | an out-of-focus tripod camera no detector could seed: two models agreed at IoU 0.98, SAM 2 then tracked it 0.14–6.34 s (63 samples) |
    ...    | G5 | YOLO pose read as states | `facing` correct on a back view (`away`) and a piece to camera (`camera`) |
    ...    | G5 | MediaPipe hands via ONNX | palm detection 0.91–0.99 with landmarks on the hand (woman clip). On the handoff clip's gloved backlit hands it fails, and re-measured carefully it fails in a more specific way than "nothing is detected": on a right-half crop with the threshold dropped to 0.2 it fires on **every** frame at 0.52–0.68, but drawing the boxes shows they sit on the bare **forearm**, not the hand. Handpose then scores 0.004–0.43 against its own 0.5 gate on those boxes, i.e. it declines to landmark them. Two producers, both silent for the right reason (X2). The score alone would have read as success — the same trap as the 591×85 px "hand" earlier — so it was the picture that settled it, not the number |
    ...    | G5 | contact-break from native-resolution masks | release comp (truth exact) 2.44 against 2.400, **1.0 frame**; handoff clip 8.50 against a re-derived 8.42, **2.0 frames**. The alternatives on the same clip: box separation 0.22–0.32 s out, mask contact area at 10 fps has no event in it at all, frame-change peak 0.18 s out — it peaks where motion is fastest, which is after the hand has gone |
    ...    | G5 | palm orientation from the knuckle winding | `palm(e, camera\\|away\\|edge)` decided by the sign of the cross product of the two knuckle vectors, which flips with handedness; measured on constructed hands, since no clip here shows a palm presented to the lens |
    ...    | G8 | head pose from the same keypoints | `facing(e, camera)` rather than a separate `looking_at`: one fluent that also says `left`, `right` and `away`, instead of a synonym for one of its values |
    ...    | G6 | RapidOCR + bisected boundaries | three caption cues recovered verbatim; changes at 0.528 / 1.434 / 2.434 s against 0.55 / 1.45 / 2.45 — 22, 16 and 16 ms, all inside one frame. The round-trip closes with the lowering: retiming a cue moves only the frames between the old and new times |
    ...    | G7 | cross-shot identity from CLIP appearance | confidence is the pair's percentile against same-frame pairs, which cannot be one object; on the three-shot assembly the man in shot 1 (seed 2.400 s) and in shot 3 (seed 8.000 s) are rejoined across two cuts — `same_as(e5, e1)` at 1.00 — at different scale and stride. For the colour half, hue-rotating his second shot by 120° (navy jacket to maroon, and the street with it) still gives `same_as(e3, e1)` at 0.86; the appearance cosine falls only 0.915 → 0.873 across a full rotation against a 0.764 different-object baseline |
    ...    | G9 | shot scale from mask height | `mcu` on both the man and the woman clip |
    ...    | G10 | Laplacian sharpness vs DA3 | 0.17 against 3.16 between a soft and a sharp subject; the wrong `nearer` fact is now not emitted |
    ...    | G11 | self-similarity novelty | one boundary per clip, each where the other producers put the action: the cat's hop (2.500 s, against `motion` 2.0–3.0) and the bottle's arrival and departure (1.500 / 10.000 s, against `enter` 2.1 and `exit` 11.0) |
    ...
    ...    *What perception costs, and the tracker swap (2026-09-18)*
    ...
    ...    Measured on a base M4 (16 GB) with `MOONSPLICE_PROFILE=1 tools/bench_perceive.py`, cold, on the handoff
    ...    clip (14.3 s) with contact on. With SAM 2.1-small it took **1717 s, 120× realtime**, and SAM 2 was
    ...    96% of that: 631 s tracking 290 frames and 1023 s on 504 contact frames, about 2 s a frame at
    ...    `imgsz=1024`, barely ahead of the CPU. Everything else together was about 60 s: YOLO-World 74 ms a
    ...    frame, DA3 170 ms, OCR 206 ms, pose and hands 36 ms, CLIP negligible.
    ...
    ...    The tracker is now EdgeTAM (`segtrack.py`), SAM 2 with the memory attention replaced by a small
    ...    perceiver, and the same clip takes **214–279 s, 15–20× realtime**. The spread is run-to-run noise
    ...    on this machine, not configuration. It is also the more accurate tracker on hand-labelled truth,
    ...    DAVIS-2017 val, 8 sequences × 40 frames, prompted with the true box on frame 0:
    ...
    ...    | tracker | J | boundary F @ 8 px | @ 2 px | s/frame |
    ...    |---|---|---|---|---|
    ...    | EdgeTAM (MPS fp32) | **0.946** | **0.980** | **0.892** | 0.26 |
    ...    | SAM 2.1-small @ 1024 | 0.924 | 0.967 | 0.865 | 1.85 |
    ...
    ...    The release on the handoff reads 8.58 (reference 8.42, 4 frames). SAM 2's recorded 8.50 turned out
    ...    to depend on where the window fell: on identical windows SAM 2 read 8.52 and 8.62, and EdgeTAM read
    ...    8.58–8.60 on every window. A SAM 2 re-measure around the hit was tried and dropped: it cost 85 s and
    ...    moved the answer by half a frame. EdgeTAM's live memory holds at about 1 GB through a 70-frame
    ...    session, but the MPS pool grew to 7.7 GB across a clip, so it is emptied past 3 GB
    ...    (`MOONSPLICE_MPS_POOL_GB`).
    ...
    ...    **The same tracker from Rust, on Core ML.** `track/` (`moonsplice-track`) runs EdgeTAM on ONNX Runtime:
    ...    the four graphs of `jax-image-tools/edgetam-video-onnx`, a single-mask decoder exported by
    ...    `tools/edgetam_onnx_setup.py` (the published one always runs multimask, which gives a box-prompted
    ...    frame the wrong object pointer, 2.1 max abs off), and the memory bank ported from transformers.
    ...    Resizing is Pillow's bilinear reproduced exactly (0 differing pixels); transformers' processor uses
    ...    PIL, and torch's bilinear moved the frame-0 memory tokens by 2.8. Against transformers on the CPU the
    ...    Rust tracker gives **IoU 1.000 on every frame of a 70-frame track**. Against transformers on MPS it
    ...    drops to 0.974, and transformers on MPS against itself on the CPU gives the same 0.974: MPS float
    ...    noise flips an ambiguous frame at the release, so the ONNX tracker is the more reproducible of the two.
    ...
    ...    `MOONSPLICE_TRACKER=coreml` puts the vision encoder, the memory encoder and the steady-state memory
    ...    attention on Core ML (GPU); the decoders stay on the CPU, where Core ML refuses to compile them. The
    ...    tracker runs as one long-lived process (`moonsplice-track serve`), because loading its sessions costs
    ...    about 2 s even from Core ML's compile cache and a clip makes about 20 tracking calls. Back to back on
    ...    the handoff clip:
    ...
    ...    | tracker | whole clip | tracking | release | peak MPS pool |
    ...    |---|---|---|---|---|
    ...    | `edgetam` (PyTorch, MPS) | 314 s | 114 s | 8.58 | 5.1 GB |
    ...    | `coreml` (Rust, ONNX Runtime + Core ML) | **275 s** | **93 s** | 8.54 | **1.6 GB** |
    ...
    ...    Fixed-shape Core ML graphs for all 16 memory shapes a track passes through were faster one at a time
    ...    and slower together, at 0.34–0.37 s/frame against 0.28 with only the steady state, so only that
    ...    shape ships. `MOONSPLICE_TRACKER=onnx` is the CPU-only path, also the Linux one. An MLX build would mean
    ...    re-implementing the network in Rust over `mlx-rs`, because MLX does not run ONNX graphs; it has not
    ...    been done.
    ...
    ...    **Off the Mac: the same stack in the cloud (2026-09-18).** Every model perceive uses now has a
    ...    torch-free form: EdgeTAM through `moonsplice-track` (new `--device cuda`, built with `--features cuda`);
    ...    YOLO-World, YOLO11-pose, CLIP B/32 and DA3-small exported to ONNX (`tools/edge-bench/export.py`;
    ...    DA3 needed `torch.cartesian_prod` replaced with a meshgrid, and matches torch to 5e-5); the MediaPipe
    ...    hand models and RapidOCR were ONNX already; Whisper runs on CTranslate2. Harness and raw results:
    ...    `tools/edge-bench/`. Model time for the 14.3 s handoff clip, projected from per-model timings times the
    ...    calls a real perceive makes:
    ...
    ...    | where | tracker s/frame | tracker share | model total | per clip |
    ...    |---|---|---|---|---|
    ...    | M4 CPU (ONNX Runtime) | 0.33 | 264 s | 309 s | — |
    ...    | Modal, 8 CPU cores (x86, AVX-512) | 0.47 | 378 s | 422 s | ≈ $0.06 |
    ...    | Modal T4 | 0.26 (incl. start-up) | 208 s | 232 s | ≈ $0.04 |
    ...    | Modal L4 | **0.09–0.10 steady** | ≈ 80 s | ≈ 100 s | ≈ $0.03 |
    ...
    ...    Three things set those numbers. **The tracker's first frame costs 1.5–2.9 s of CUDA and cuDNN start-up per
    ...    process**, which is most of a 30-frame track: the L4 profile is 2.9 s for frame 0 and 0.09–0.10 s for
    ...    every frame after. So a GPU deployment must run the tracker as one long-lived process (`serve`) per
    ...    container, never a process per track. **Tracks share a GPU well:** four at once on the L4 raised
    ...    throughput from 0.23 to 0.08 s/frame including start-up, so a clip's ~18 tracking calls should fan out
    ...    on one card rather than across containers. **Every other model is small on a GPU** (YOLO-World 10 ms,
    ...    DA3 8 ms, CLIP 5 ms, Whisper 0.05× realtime on the L4); RapidOCR stays on the CPU at 0.18–0.56 s a
    ...    frame, where socialite also measured it winning.
    ...
    ...    **How many at once on one L4.** One tracker process uses 1.7 GB of GPU memory and 17% of the GPU. Throughput rises
    ...    with processes until the GPU saturates: 11 frames/s with one, 37 with four, 39 with six to twelve (86-89% busy),
    ...    and sixteen run out of the 24 GB. So an L4 does about **39 EdgeTAM frames/s, reached at 4-6 concurrent tracks**.
    ...    A 14.3 s clip needs ~812 tracker frames, about 21 GPU-seconds at saturation, which puts one L4 at roughly
    ...    **4-6 clips in flight and ~150 clips an hour**. Past six, tracks only wait on each other.
    ...
    ...    **fp16 does not help this tracker.** Converted with ONNX Runtime's float16 tool (the Resize scales in the vision
    ...    encoder have to stay fp32 or the graph will not load), the tracker loses the object on every frame (IoU 0.000)
    ...    and each stream is slower, 0.14 s/frame against 0.09, because casts are added around the ops that stay fp32.
    ...    What limits one stream is the host side: resizing on the CPU and copying the features back and forth between
    ...    graphs. Keeping those on the GPU (IoBinding) was the next single-stream lever; for throughput, concurrency
    ...    already fills the card.
    ...
    ...    **IoBinding and a lean encoder: 0.09 → 0.027 s/frame on one L4 stream.** Two things were wasted per frame.
    ...    The vision encoder also returned positional encodings pos0/pos1, 84 MB computed and copied back every
    ...    frame and never read; `vision_encoder_lean.onnx` outputs only the three feature maps, and pos2, which is a
    ...    constant, is read once from `pos2.f32`. Then `track_bound` keeps features, memories and masks on the device
    ...    between graphs (ONNX Runtime IoBinding), with `memory_attention_nchw.onnx` taking and returning NCHW so no
    ...    transpose round-trips through the host; the resize for the next frame is prefetched on a thread. Steady
    ...    state is 0.027 s/frame with TF32 (IoU 0.9976 against the Mac) and 0.038 with `MOONSPLICE_TRACK_TF32=0` (IoU
    ...    1.000). What remains is GPU compute, so one stream now reaches the ~37-39 frames/s the card managed
    ...    before only with four concurrent processes. `MOONSPLICE_TRACK_PROFILE=1` prints the stage totals.
    ...
    ...    **Full recognition, with no prompts (tag-then-ground).** A fixed large vocabulary does not work: YOLO-World
    ...    asked for all 1205 LVIS labels at once returned parrot, flamingo and pelican on the handoff clip and never
    ...    the person. Instead RAM++ (`tags.py`) tags keyframes, the tags that are LVIS names or synonyms (plus hand
    ...    and face) become YOLO-World's vocabulary, labels are suppressed across classes above IoU 0.7, and a label
    ...    has to appear on ≥3 keyframes at ≥0.15 to become an entity (instance count is the 75th percentile of
    ...    per-frame counts). Tags that are not objects become `holds(scene_tag("beach"), t0, t1)` with
    ...    `src(…, ram_plus, …)`. Tracks whose masks overlap above IoU 0.6 are one thing under two names and are
    ...    merged (`person/glove`), and contact releases are not timed between two agents. On the handoff clip this
    ...    found `release(bottle, person)` at 8.500 with no prompt (prompted: 8.54; truth ≈ 8.42). RAM++ is fp16 on
    ...    CUDA, with identical tags on 8 of 8 frames and half the memory.
    ...
    ...    **The worker (`cloud/worker.py`, `bin/moonsplice-cloud`).** Anything with a URL goes in: a page yt-dlp
    ...    understands, a signed CDN link from ScrapeCreators (with its headers, downloaded at once because the
    ...    links expire), or a file on the media volume. `fetch.py` stores each one by a stable key
    ...    (`youtube:<id>`, `tiktok:<id>`) with its metadata and sha256; perceive runs with full recognition, and
    ...    `clips.py` cuts the result into clips (shots, split at action boundaries when both halves are ≥1 s),
    ...    each with an mp4, a poster and its own fact log sliced from the whole one, plus a `manifest.json` of
    ...    entities, events, words, on-screen text and scene tags per clip. One L4 per container runs three videos
    ...    at a time over a spawn pool, each slot holding its models warm and one long-lived tracker; containers
    ...    stop after 60 s idle, and at most three run. Four slots ran the 24 GB out of memory (a slot holds
    ...    ~1.6 GB of models and up to ~1.7 GB of tracker), so the CUDA arena now grows by what is requested and
    ...    torch uses expandable segments. Frames are decoded once per clip into a cache (`sources.frame_at`,
    ...    2 GB budget) because a per-call ffmpeg seek cost 0.37 s in the container: that took `frame_at` from
    ...    66 s to 2.5 s a clip, posture from 33 to 6, depth from 17 to 2.2.
    ...
    ...    Measured warm, 2026-09-18, one batch of three submitted together: the 14.3 s handoff clip in 117 s
    ...    (3 clips, 274 facts), a 13.3 s 640×360 download in 81 s (3 clips, beach, sea, person, dress), and
    ...    "Me at the zoo" in 188 s (4 clips, elephant, fence, the transcript split across clips). YouTube refuses
    ...    downloads from Modal's addresses ("Sign in to confirm you're not a bot"); a YouTube video goes in as an
    ...    upload fetched elsewhere. The spend cap ($50 a month) is enforced by the client from `modal billing
    ...    report`; Modal's own budget has to be set in the dashboard.
    ...
    ...    Exactness holds across machines: the x86 CPU tracker gives IoU 1.000 against the Mac on every frame. The
    ...    L4 gives 0.9988, because Ampere GPUs run fp32 matmuls as TF32; `MOONSPLICE_TRACK_TF32=0` turns that off
    ...    for about 7%. int8 was tried on each tracker graph. Quantizing the image encoder breaks tracking (IoU
    ...    0.001) and runs 2.5× slower. Quantizing memory attention keeps IoU at 0.998 but is no faster on any
    ...    machine measured, so nothing ships quantized. Fly no longer has GPUs (retired 2026-08-01); a Fly
    ...    machine would be the CPU row.
    ...
    ...    Depth does not sharpen EdgeTAM's outlines. Snapping the mask edge to DA3 depth edges inside a thin
    ...    band, gated on the depth difference, on the tracker's own uncertainty, and at 504 and 756 px, and a
    ...    depth-guided filter, all lowered DAVIS boundary F. The best variant scored 0.876 at 2 px against
    ...    0.892 for EdgeTAM alone, and an image-guided control did as well as any depth variant. Depth is
    ...    for z-order and occlusion, not outlines.
    ...
    ...    A row in this table is a claim about code that keeps changing underneath it, so the rows are re-run
    ...    rather than trusted. After the cut-crossing test replaced `survives_cut`, the hands moved to ONNX
    ...    and the grip confidences started being derived, the whole set was re-measured from a cold track
    ...    cache (`CACHE_VERSION` had been bumped, so nothing was reused): G2 `camera(dolly(in))` with
    ...    `focal_stability(0.037)`, G3 the car `still` 0.100–8.200 under that dolly, G4 the tripod camera at
    ...    `vlm_agreement` 0.98, G9 `mcu` on both the man and the woman, G10 `out_of_focus(e2)` with no
    ...    `nearer` fact emitted at all, G11 `action_boundary(s1)` at 2.500 inside the hop's own motion
    ...    interval. Nothing regressed. The habit is worth keeping: five modules had changed, and "the doc says
    ...    so" is not a measurement.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

