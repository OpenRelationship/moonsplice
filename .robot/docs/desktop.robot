*** Settings ***
Documentation    Moonsplice Studio — the desktop epic
...
...    A Tauri desktop app for Moonsplice: assets and compositions on the left, a tabbed
...    preview in the centre, a Malleable agent on the right. Perception runs locally.
...
...    This file tracks the epic the way `.robot/docs/scene.robot` tracks the renderer — there is no
...    issue tracker. Decisions here are provisional until they earn a line in `.robot/docs/canon.robot`.
Metadata    Source    cadence@56ddad1:docs/DESKTOP.md

*** Test Cases ***
Decisions taken (2026-09-21)
    [Documentation]    1. **Local-first perception.** The Modal worker stays for burst and batch, but the
    ...    \ \ \ product target is the Mac. The 19x-realtime number is treated as a bug, not a floor.
    ...    2. **Greenfield app.** A new app package; `desktop/` is read for patterns and retired,
    ...    \ \ \ not extended.
    ...    3. **LÖVE leaves the app, stays in the CLI.** The app ships scene-only. `moonsplice`
    ...    \ \ \ keeps the love path. This is the revisit `.robot/docs/canon.robot` §2 already named: "when a
    ...    \ \ \ release needs to drop the LÖVE dependency."
    ...    4. **monomono is the repo contract.** `just` door, buck2 graph, `AGENTS.md`, and the
    ...    \ \ \ spec-first lifecycle. The epic is planned as Gherkin features under `context/`.
    ...    5. **Perception consolidates to three tiers** (§3). One shared backbone, a router that
    ...    \ \ \ emits no facts, and today's producers run only where the router points.
    ...    6. **Jev and Laya are token-only**, so they sit *downstream* of the fact log as the fast
    ...    \ \ \ policy layer. They are not the router.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

What already exists
    [Documentation]    Worth knowing before anything is written, because most of this epic is assembly.
    ...
    ...    - `desktop/` — Tauri 2 + React 19 + Vite 8 + Tailwind v4 + Radix + zustand + wasmoon.
    ...    \ \ A React Flow DAG shell. Carries working code worth reading: `editor/` (TimelineBar,
    ...    \ \ useKeyframeDrag, PreviewPanel, TranscriptEditor, params, time), `ai/gateway.ts`, a job
    ...    \ \ dock, and a Rust side with `gateway.rs`, `jobs.rs`, `project.rs` and keyring-backed
    ...    \ \ `secrets.rs`.
    ...    - `track/` — `moonsplice-track`, EdgeTAM on ONNX Runtime from Rust, with a Core ML EP.
    ...    \ \ IoU 1.000 against transformers on CPU over a 70-frame track.
    ...    - `tools/edge-bench/export.py` — YOLO-World, YOLO11-pose, CLIP B/32 and DA3-small
    ...    \ \ already exported to ONNX. MediaPipe hands and RapidOCR were ONNX already; Whisper is
    ...    \ \ CTranslate2. **Every model perceive uses already has a torch-free form.**
    ...    - `cloud/` — the Modal worker and its client, with the measurements that justify it.
    ...    - `core/moonsplice/` — host-free authoring API. Untouched by this epic.
    ...    - The agent is Tablua (submodules/tablua), run as `./moonsplice studio`; the malleable harness
    ...    \ \ this page once named is gone.
    ...    - monomono at `jetway/submodules/monomono` — `moon` is also installed but unused here.
    ...
    ...    Not yet torch-free: **RAM++** (tagging), **SpeechBrain ECAPA** (diarization),
    ...    **facenet** (identity), **MMS forced alignment** (word times). Four models, and they are
    ...    the real porting work left.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

1. The numbers this epic has to move
    [Documentation]    Base M4 (16 GB), the 14.3 s handoff clip, cold. From `.robot/docs/facts.robot`.
    ...
    ...    | path | whole clip | tracking | peak |
    ...    |---|---|---|---|
    ...    | SAM 2.1-small (PyTorch MPS) | 1717 s (120x realtime) | 1654 s | — |
    ...    | EdgeTAM (PyTorch MPS) | 314 s | 114 s | 5.1 GB |
    ...    | **EdgeTAM (Rust, ort + Core ML)** | **275 s (19x realtime)** | **93 s** | **1.6 GB** |
    ...    | Modal L4 | ~100 s model time | ~80 s | ~$0.03 |
    ...
    ...    Projected model-only time on the M4 CPU ONNX path (`results_mac_cpu.json`):
    ...
    ...    | model | ms/call | projected s |
    ...    |---|---|---|
    ...    | track[edgetam] | 325.3 /frame | **264.1** |
    ...    | yolo_world_960 | 224.4 | 26.9 |
    ...    | da3_small_504 | 156.5 | 5.8 |
    ...    | rapidocr | 129.7 | 3.8 |
    ...    | whisper_small_en_int8 | 0.246 /audio s | 3.5 |
    ...    | clip_b32_visual | 15.4 | 2.3 |
    ...    | yolo11n_pose_640 | 23.9 | 1.7 |
    ...    | palm + handpose | 6.5 | 0.5 |
    ...    | | | **308.6** |
    ...
    ...    **The arithmetic that sets Phase 1.** On the Core ML path the whole clip is 275 s and
    ...    tracking is 93 s, leaving 182 s for everything else — but every non-tracking model
    ...    together is only ~44 s. **About 138 s, half the wall clock, is not model inference.**
    ...    It is frame decode, resize and Python. Modal hit the same wall and fixed it with a decode
    ...    cache: `frame_at` went 66 s → 2.5 s a clip, posture 33 → 6, depth 17 → 2.2. That fix has
    ...    never been applied on the Mac.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

2. The accuracy bar, which constrains everything
    [Documentation]    Three rules from `.robot/docs/facts.robot` that any redesign must preserve.
    ...
    ...    - **A fact with no `src` line is exact.** Perceived facts always name a producer.
    ...    - **Confidence is derived from inter-sample agreement, never self-reported** (§"Confidence
    ...    \ \ is derived"). A model's own score is about the model, not the clip. This caught an
    ...    \ \ out-of-focus camera every detector missed, and caught tracks carrying a lucky seed score
    ...    \ \ while the mask had slid off the object.
    ...    - **Facts are per-instance and the vocabulary is words, not numbers.** `in_third(e, left)`,
    ...    \ \ `release(bottle, person)`. `lower.py` writes edits back onto those instances.
    ...
    ...    Timing: hand-eye truth for the handoff release is **8.30 s ± 0.02**. Core ML reads 8.54.
    ...
    ...    These rules are why a single video encoder with a decision head cannot *be* the fact log.
    ...    A clip embedding has no instance index, a head self-reports its confidence, and V-JEPA's
    ...    representations are weak at precise temporal localization by construction — it predicts
    ...    masked regions inside a fixed clip with bidirectional context and no Markovian transition
    ...    operator. V-JEPA 2.1's dense predictive loss exists to attack exactly that gap.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

3. Phase 1 — perception in three tiers
    [Documentation]    The consolidation, in the form the rules above allow.
    ...
    ...    ```
    ...    frames
    ...    \ \ ├─ TIER 0 \ one shared backbone pass (RADIO-class), every sampled frame
    ...    \ \ │ \ \ \ \ \ \ \ \ \ → semantics + dense per-patch features
    ...    \ \ │ \ \ \ \ \ \ \ \ \ feeds: keyframes, scene tags, shot scale, thirds/bands, CLIP's current job
    ...    \ \ │
    ...    \ \ ├─ TIER 1 \ a small spatiotemporal head over the Tier-0 feature sequence
    ...    \ \ │ \ \ \ \ \ \ \ \ \ → WHERE and WHEN to spend the expensive producers
    ...    \ \ │ \ \ \ \ \ \ \ \ \ EMITS NO FACTS. Routing only.
    ...    \ \ │
    ...    \ \ └─ TIER 2 \ today's producers, run only where Tier 1 points
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ EdgeTAM, DA3, OCR, forced alignment, pose, hands
    ...    \ \ \ \ \ \ \ \ \ \ \ \ \ → facts, with the same src lines they carry today
    ...    ```
    ...
    ...    **Why a router and not a replacement.** Perceive currently tracks everything RAM++
    ...    discovered — about 18-20 tracking calls a clip — and nothing decides whether a track is
    ...    worth paying for. Skipping a track beats speeding one up: the win is multiplicative, and
    ...    provenance is untouched because the producer still measures whatever it is pointed at.
    ...
    ...    **Why RADIO for Tier 0.** [AM-RADIO](https://github.com/NVlabs/RADIO) is multi-teacher
    ...    distillation into one backbone; the current teacher set is SigLIP2-g-384, DINOv3-7B and
    ...    **SAM3** — the segmentation lineage EdgeTAM descends from. One pass gives semantics, dense
    ...    correspondence and segmentation-grade features together. It stays a *spatial* backbone, so
    ...    it keeps the per-patch locality the fact log needs and V-JEPA trades away, and ViT shapes
    ...    export to ONNX, landing on the `ort` + Core ML path `track/` already proves.
    ...
    ...    **The gate.** Tier 1 ships only when it reaches a stated recall against the entity-facts
    ...    current logs emit, measured on `bin/moonsplice-vision eval` with exact truth. A router's
    ...    failure mode is a *skipped* track, which surfaces as a missing fact — cheap to detect,
    ...    unlike a wrong one. Recall target to be set from the first spike; it should be near 1.0,
    ...    because a missed entity is an edit the agent cannot make.
    ...
    ...    *Steps, cheapest first*
    ...
    ...    Each is independently valuable and shippable, and the first three are engineering against
    ...    measured hot spots rather than research.
    ...
    ...    1. **`MOONSPLICE_TRACK_BOUND=1` on Core ML.** `track/src/lib.rs:214` gates the IoBinding +
    ...    \ \ \ lean-encoder path on `Device::Cuda || MOONSPLICE_TRACK_BOUND=1`. That path took CUDA from
    ...    \ \ \ 0.09 → 0.027 s/frame by dropping the unused pos0/pos1 outputs (84 MB copied per frame)
    ...    \ \ \ and keeping features on the device between graphs. It has never been on by default for
    ...    \ \ \ Core ML. One flag, then measure. Highest leverage per unit of work in this document.
    ...    2. **The frame-decode cache on the Mac.** Port `sources.frame_at`'s Modal behaviour. Target
    ...    \ \ \ is the ~138 s of non-model wall clock identified in §1.
    ...    3. **Core ML EP for YOLO-World.** 224.4 ms/frame on CPU, the #2 cost after tracking.
    ...    4. **One process, not many.** Perception moves into a long-lived Rust process. Core ML
    ...    \ \ \ session load is ~2 s and a clip makes ~20 tracking calls; `moonsplice-track serve` already
    ...    \ \ \ proves the shape.
    ...    5. **Tier 0 spike** — RADIO to ONNX, Core ML, measured against the CLIP B/32 job it replaces.
    ...    6. **Tier 1 spike** — router head, with the recall gate above.
    ...    7. **The four remaining torch models** — RAM++, ECAPA, facenet, MMS. Port or replace. RAM++
    ...    \ \ \ is the one Tier 0 might absorb outright.
    ...
    ...    **Not doing:** MLX. `.robot/docs/facts.robot:243` records that an MLX build means reimplementing the
    ...    network over `mlx-rs`, because MLX does not run ONNX graphs. Revisit only if the Core ML EP
    ...    provably plateaus.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

4. Phase 0 — monomono (done, 2026-09-21)
    [Documentation]    The repo is a monomono consumer at v0.4.3, attached as a pinned submodule.
    ...    `just check` is green: 21 ok, 2 warn, 0 fail.
    ...
    ...    **What was done**
    ...
    ...    - `AGENTS.md` content moved to `.agents/AGENTS.md` **before** init. This mattered:
    ...    \ \ `agents-host.sh sync` does `rm -f` on the root `AGENTS.md` and symlinks it, and the
    ...    \ \ template ships a generic `.agents/AGENTS.md`. An unprepared init would have replaced
    ...    \ \ the repo's real contract with boilerplate.
    ...    - `monomono init --name moonsplice` scaffolded 22 files. `scaffold()` skips anything that
    ...    \ \ already exists, so `.robot/docs/agents.robot`, `README.md` and `.gitignore` were untouched.
    ...    - Toolchains declared: `rust`, `lua`, `python`, beside the default genrule / bootstrap / test.
    ...    - `.gitignore` merged selectively. monomono's template ignores `.claude/`, but
    ...    \ \ `.claude/settings.json` is tracked here, so that line was **not** taken.
    ...    - `context/projects/studio/` created with five features, all five in the buck2 graph:
    ...    \ \ `local-perception`, `app-shell`, `agent-surface`, `project-sync`, `love-free-render`.
    ...    - `AGENTS.md` and `.robot/docs/agents.robot` updated to describe the new door.
    ...
    ...    **Deliberately not done: the ecosystem manifests.** `just doctor` warns that `Cargo.toml`,
    ...    `desktop/package.json` and the rest sit outside `packages/`. The cargo adapter writes a
    ...    *new* `Cargo.toml` under `packages/cargo/`, which would make a second workspace root and
    ...    break `cargo build --release` from the repo root along with `moonsplice build` — both named
    ...    as session gates in `AGENTS.md`. The eleven-member workspace plus staged dylibs is its own
    ...    epic and is not on this one's critical path. The warning stands as the reminder.
    ...
    ...    **Also not done:** buck2-native Rust. `toolchains/rust.BUCK` is declared and ready when the
    ...    manifests move; until then cargo builds the Rust and buck2 owns repo shape and the features.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

