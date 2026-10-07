*** Settings ***
Documentation    Moonsplice Studio — the desktop epic (continued)

*** Test Cases ***
5. Phase 2 — the app shell
    [Documentation]    Greenfield at `editor/`. Custom chrome: stoplights left, project switcher centre,
    ...    export right.
    ...
    ...    ```
    ...    ┌─────────────────────────────────────────────────────────────┐
    ...    │ ● ● ● \ \ \ \ \ \ \ ▾ project-name \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ [ Export ] │
    ...    ├──────────────┬──────────────────────────┬───────────────────┤
    ...    │ assets \ \ \ \ \ \ │ \ ▸ 16:9 \ 9:16 \ 1:1 \ + \ \ \ │ \ agent \ \ \ \ \ \ \ \ \ \ \ │
    ...    │ \ footage/ \ \ \ │ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │
    ...    │ \ images/ \ \ \ \ │ \ \ \ \ \ preview \ \ \ \ \ \ \ \ \ \ \ \ │ \ \ messages \ \ \ \ \ \ \ │
    ...    │ \ audio/ \ \ \ \ \ │ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │
    ...    │ compositions │ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │
    ...    │ \ Hero \ \ \ \ \ \ \ ├──────────────────────────┤ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │
    ...    │ \ Cutdown \ \ \ \ │ \ timeline \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ │ \ \ composer \ \ \ \ \ \ \ │
    ...    └──────────────┴──────────────────────────┴───────────────────┘
    ...    ```
    ...
    ...    - **Left** — assets of any kind, plus compositions including empty ones. No code shown.
    ...    - **Centre** — tabs per video/variation/aspect ratio within one project. Below it the
    ...    \ \ timeline, which must make manual edits visibly distinct from relational ones, because a
    ...    \ \ comp is `f(t)` and a hand-pinned value is a different kind of thing from a tween.
    ...    - **Right** — the agent (§6).
    ...
    ...    Read from `desktop/` before rewriting: `editor/timeline.ts`, `useKeyframeDrag`, `params.ts`,
    ...    `time.ts`, and the Rust `secrets.rs` keyring work.
    ...
    ...    **The sync engine — decided 2026-09-21: local only.** No cloud sync, no CRDT. The design
    ...    falls out of a property the repo already has: `lower.py` states that a comp is never
    ...    regenerated from facts, only rewritten in place, and that `lower(comp, [])` is the identity
    ...    *byte for byte, so every frame hash holds*. So **the Lua source is the truth**, there is
    ...    exactly one representation, and drift is structurally impossible rather than prevented.
    ...
    ...    Three consequences worth stating here, with the rest in the `project-sync` feature:
    ...
    ...    - **Never round-trip a comp through an AST.** A parse-and-reprint changes bytes, and changed
    ...    \ \ bytes invalidate every hash in `.robot/golden/`. Edits are span replacements.
    ...    - **Three kinds of state stay apart** — comp state is the `.lua`; project state (comps,
    ...    \ \ variations, aspect ratios, assets) is a manifest; ephemeral state (playhead, zoom,
    ...    \ \ selection, tab) never leaves React. `desktop/src/editor/store.ts` conflates all three
    ...    \ \ behind a `dirty` flag, which is exactly the drift being designed out.
    ...    - **Undo is a source snapshot**, so an agent edit across twelve nodes and a one-node drag
    ...    \ \ are both a single undo entry with no transaction machinery.
    ...
    ...    The engine's real problem is therefore not state propagation but frame cache invalidation,
    ...    keyed on `(source hash, t, size)`.
    ...
    ...    *Built 2026-09-21 — what the shell turned out to need*
    ...
    ...    The twenty scenarios in `app-shell`, `agent-surface` and `project-sync` each have a test
    ...    named after them; `bin/studio-spec` parses the feature files and checks it, so coverage is
    ...    measured rather than claimed. Six decisions came out of building it that the plan did not
    ...    anticipate:
    ...
    ...    1. **The LÖVE host became a frame server, and the protocol is the Phase 4 seam.**
    ...    \ \ \ `core/runtime/serve.lua` takes one JSON request per line and answers with one `CS `-prefixed
    ...    \ \ \ reply, payloads landing in a small ring of files. Phase 4 replaces what is behind that
    ...    \ \ \ protocol without the app noticing, which is a better seam than the one §7 assumed.
    ...
    ...    2. **A node is aligned to its constructor by the line that wrote it.** `lower.py` pairs
    ...    \ \ \ nodes to constructor calls by counting, which lines up for 29 of the 43 compositions
    ...    \ \ \ here; the other fourteen build nodes in a loop, where one call makes many. `core/moonsplice`
    ...    \ \ \ now records the line each node was written on, which traces 99% of 331 things. A thing
    ...    \ \ \ built in a loop is *placed and marked shared*, so an edit naming one of eight is refused
    ...    \ \ \ by name rather than silently changing all eight.
    ...
    ...    3. **The manual/relational distinction is structural, not a flag.** It comes from `record`
    ...    \ \ \ versus `record_step` in the timeline model, so the UI cannot get it the wrong way round.
    ...    \ \ \ One correction: a caption's lines are recorded as steps too, and a spoken line is not a
    ...    \ \ \ hand-pinned value — the engine tags those `cue` so the lane draws them as lines.
    ...
    ...    4. **The vocabulary is closed in both directions, and shared.** Nodes, properties and
    ...    \ \ \ curves all have a word a person reads, and every word resolves back to the thing the
    ...    \ \ \ renderer honours. The words live in one `editor/vocabulary.json` that the UI and
    ...    \ \ \ Rust both read. This is load-bearing rather than cosmetic: with the agent reading ids it
    ...    \ \ \ said "rect4 is the teal bar" to a person who opened this app to avoid that, and with the
    ...    \ \ \ vocabulary open on the way in it invented a `z` property that the lowering wrote into the
    ...    \ \ \ source where nothing reads it — a change that renders identically while the person is
    ...    \ \ \ told it worked.
    ...
    ...    5. **A gesture with no verb is a real gesture that gets refused.** Moving where a movement
    ...    \ \ \ starts, and restacking, both have handles and both come back refused, so "no second edit
    ...    \ \ \ path" is demonstrable rather than asserted.
    ...
    ...    6. **Preview performance was never the renderer.** It paints a frame in 0.9 ms. The JPEG
    ...    \ \ \ encode was 406 ms, because the dev profile builds dependencies unoptimised; and the
    ...    \ \ \ playhead ran on unsnapped wall clock, so no two passes ever asked for the same cache key.
    ...    \ \ \ See §5's cache note — the key was right, the caller was not.
    ...
    ...    *Rebuilt 2026-09-21 — the timeline, after it was called unusable*
    ...
    ...    The first timeline was a lane per thing with the movements on that thing drawn into it. The
    ...    person it was built for read it and said it was "overly confusing and not usable really", and
    ...    they were right, for one reason that the rest follows from: **its widest shape carried no
    ...    information.** Every lane drew a hairline across the whole composition, because the shape of a
    ...    composition does not say when a thing is visible and inferring it from an opacity tween is a
    ...    heuristic that is wrong the first time somebody fades something out and back in. So the biggest
    ...    mark on screen meant nothing, and the small ones — unlabelled pills at whatever scale the pane
    ...    happened to be — were all that was left to read.
    ...
    ...    What every editor agrees on, and what this now does:
    ...
    ...    | The convention | Where it comes from | What it is here |
    ...    | --- | --- | --- |
    ...    | A clip's width is its lifetime | Premiere, Resolve, Final Cut, every NLE since the tape | `onscreen`, **measured** by the engine |
    ...    | Keyframes live on a named row per property, hidden until asked for | After Effects' layer/property model | a lane opens into one row per property |
    ...    | Front at the top, children under their parent | every layer list ever shipped | build order reversed, `parent` indented |
    ...    | Sound below a divider | every editor separates picture from sound | a `sound` group after the picture ones |
    ...    | The scale is pixels per second, and you can change it | all of them; none fits-to-pane only | `zoom`, with `fit` as one value of it |
    ...    | Scrub anywhere, drag the playhead | all of them | the ruler, empty lane, and the head itself |
    ...
    ...    The load-bearing part is the first row. `core/moonsplice/onscreen.lua` evaluates the composition at
    ...    each frame and applies the gates the painter applies — effective opacity through the parent
    ...    chain, a video's own `from`..`from + duration` window, a sound's `at` and duration, a container
    ...    being present while any of its children are — and returns the intervals. It is host-free (no
    ...    love, no ffi, no rasterizer), costs about 17 ms for a 40-thing composition a minute long, and
    ...    strides past 3000 samples so opening a long one stays quick; the stride comes back in the
    ...    outline so the UI can say it measured coarsely rather than quietly missing a one-frame flash.
    ...
    ...    Three smaller things fell out of building it, and then out of driving it:
    ...
    ...    - **A legend is a confession.** The footer key for "moves" and "set by hand" now appears only
    ...    \ \ when a lane is open and those marks are actually on screen. Closed, a clip is a clip.
    ...    - **Contrast is measurable, so it was measured.** The first pass drew clips at 1.3:1 against
    ...    \ \ the lane they sit in — painted, and invisible at a glance, which is the same defect in a new
    ...    \ \ costume. Clips have their own two tokens (`--clip`, `--clip-edge`) and their boundary reads
    ...    \ \ at 4.0:1 in dark and light alike, checked by sampling the rendered pixels rather than by
    ...    \ \ looking at them.
    ...    - **An empty composition is a normal thing to open.** Driving the built app rather than the
    ...    \ \ tests found it: a composition with nothing in it blanked the window, because the frame server
    ...    \ \ encodes a plain empty Lua table as `{}` and the app called `.map` on it. The server now says
    ...    \ \ `[]` for an empty instant the same way it already did for every other list, the stage and the
    ...    \ \ inspector check the shape they were handed instead of trusting it, and
    ...    \ \ `an_empty_composition_opens_rather_than_blanking` fails against the old server — which was
    ...    \ \ checked by reverting it.
    ...
    ...    *Rebuilt 2026-09-21 — the left pane, after "i dont really want automated groups"*
    ...
    ...    Two notes, one day apart from the person this is for:
    ...
    ...    > the assets panel … should be more like premiere or after effects really with preview on double
    ...    > click in the preview section and havign just compositiojnh items not sub composition variation
    ...    > types
    ...
    ...    > i dont really want automated groups i guess id rather have it be custom file folder tree by
    ...    > default
    ...
    ...    The pane had been two lists: compositions, each one opening into a row per shape, and assets
    ...    grouped under **Footage / Pictures / Sound / Type**. Both halves were the app organising somebody
    ...    else's project. What replaced them:
    ...
    ...    | Was | Is | Why |
    ...    | --- | --- | --- |
    ...    | Assets grouped by kind | The project's own folders | A grouping nobody chose is the app's idea of your project. A folder here is a real directory: making one makes one, renaming one renames it, dragging a thing in **moves the file**. |
    ...    | A row per shape under each composition | One row per composition | A wide cut and a vertical cut are one thing. Which one you are looking at is a control above the picture, beside the proportions it changes. |
    ...    | Nothing to do with an asset but drag it | Double-click loads it into the viewer | Premiere's source monitor, After Effects' footage panel. It opens as a tab beside the compositions, plays, and closes. |
    ...
    ...    Three things this cost, all of them worth it:
    ...
    ...    - **The folders are the truth.** `Project::open` reconciles: a composition somebody copied in
    ...    \ \ through the Finder is adopted, one they deleted leaves. The manifest says what each file *is*;
    ...    \ \ the filesystem says where it is, and the two can no longer disagree.
    ...    - **Bytes without paths.** A `casset://` scheme serves an asset by its id the way `cframe://`
    ...    \ \ serves a frame, with byte ranges answered — a player that cannot seek is a viewer that will not
    ...    \ \ start. So the window can show footage while still never being told where anything is.
    ...    - **A drop knows where it landed.** Tauri's drag-and-drop carries a position rather than an
    ...    \ \ element, so the pane hit-tests the folder under the cursor and the highlight follows it. Dropped
    ...    \ \ footage goes into the folder it was dropped on, and nowhere else.
    ...
    ...    *Also 2026-09-21 — three things found by testing the whole sitting*
    ...
    ...    A test that makes every gesture in the order a person would make them, rather than one test per
    ...    verb, found what the per-verb tests could not:
    ...
    ...    - **An edit the engine cannot load goes back.** An edit is a write, so by the time anything knows
    ...    \ \ the composition will not load, it is already on disk. Dragging a movement's right edge past the
    ...    \ \ end of a composition does exactly that — a composition's length is fixed, on purpose. The write
    ...    \ \ is now put back, and the person is told "that would run past the end of the composition, and a
    ...    \ \ composition's length is fixed, so nothing was changed".
    ...    - **A refusal is said in the same words as everything else.** `Display` for a refusal quotes the
    ...    \ \ node id and the property key, and the notice in the corner was showing it: `"rect2" has no "z"
    ...    \ \ to set`. That is code on screen, in the one app that shows none. Refusals now go through the
    ...    \ \ same names the timeline uses, and a property the vocabulary has no word for is "no such thing"
    ...    \ \ rather than its key.
    ...    - **A name that moves is not a name.** A captions node was labelled with its own first line, so
    ...    \ \ retyping that line renamed the lane and the notice read "changed line 2 of Hold the cut."
    ...    \ \ Spoken lines are called Captions; the lines themselves are in the lane.
    ...
    ...    *Also 2026-09-21 — the verb that was missing, and what a live model found*
    ...
    ...    An asset could be dragged out of the left pane and **nothing could take it**: no drop target, no
    ...    lowering verb, no tool. An editor that cannot bring footage in is not an editor, so `place` is now
    ...    a verb like the others — `Edit::Place` writes a constructor as the last statement of the scene, the
    ...    timeline and the picture both take a drop, the viewer is a drag source, and the agent's `place`
    ...    tool goes down the same path. What a dropped thing becomes is decided where the project is: a clip
    ...    starts where it landed, a picture fills the frame, a sound is heard from that moment, a typeface is
    ...    refused in words. There is still no making a shape out of nothing.
    ...
    ...    Building it turned up three defects that only running it could find:
    ...
    ...    - **The frame server read an image it had already released.** On the readback path — the one a
    ...    \ \ composition with video in it takes — the last line asked a freed image for its size, so the first
    ...    \ \ frame of any comp holding a clip came back as "Cannot use object after it has been released".
    ...    - **The outline was carrying file paths.** `src` and `font` went to the app in every node's props.
    ...    \ \ The inspector never showed them, which is exactly why it went unnoticed; `ProjectView` holds the
    ...    \ \ no-paths line by construction and the outline now does too.
    ...    - **Four live tests shared one scratch directory**, so run in parallel they deleted each other's
    ...    \ \ composition mid-turn. They had been passing by luck of timing.
    ...
    ...    And two the *model* found, which no double would have:
    ...
    ...    - It sent its edits as **strings of JSON** inside the array. Three refusals later it gave up, and
    ...    \ \ the person got nothing. The boundary now reads a string that is an edit, and still refuses
    ...    \ \ anything that is not one.
    ...    - Asked to add footage, it said it could not see any. `holds` is what is in the composition, which
    ...    \ \ is a different question from what the project holds — so it has `project` now, and with it, it
    ...    \ \ puts the clip in on the first try: *"Done. The Earth night clip now plays from the very start of
    ...    \ \ the composition."*
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

6. Phase 3 — the agent
    [Documentation]    Malleable is **Lua**, not TypeScript, and rule 1 of its eight forbids the core from naming a
    ...    vendor. So:
    ...
    ...    ```
    ...    React \ ─ AI SDK UI (useChat)
    ...    \ \ \ │ \ \ \ \ \ custom ChatTransport.sendMessages → Tauri command
    ...    \ \ \ ▼ \ \ \ \ \ Tauri channel → stream of UIMessageChunk back
    ...    Rust \ \ ─ mlua host + the OpenRouter port + tool bodies
    ...    \ \ \ │
    ...    Lua \ \ \ ─ Malleable: agent declaration, turn loop, approval gate
    ...    ```
    ...
    ...    - AI SDK 5's `ChatTransport` is the seam; a custom transport over Tauri channels replaces the
    ...    \ \ HTTP route, so there is no local server.
    ...    - The OpenRouter client is a **port** written on the Rust side and handed in. Malleable's core
    ...    \ \ never sees it.
    ...    - Tools reach Moonsplice through the same commands the UI uses: read the fact log, query it, edit
    ...    \ \ a comp via `fact_edit`, render, export.
    ...    - Approval is the harness's, never the tool's — a refusal is a normal result the model reads.
    ...    \ \ This maps onto the UI's confirmation affordances directly.
    ...    - **Models:** [MiniMax M3](https://openrouter.ai/minimax/minimax-m3) as the agent — 1M context,
    ...    \ \ native image *and video* input, $0.23/M in and $0.96/M out. [Hailuo 3](https://openrouter.ai/minimax/hailuo-3)
    ...    \ \ for pixel edits to a rendered video (remove text, add an object). Note the split: M3 reasons
    ...    \ \ over the fact log and the comp; H3 only ever touches rendered pixels, never the composition.
    ...    - **Where Jev and Laya go:** downstream. They are token-only, so they read the fact log and make
    ...    \ \ fast typed decisions on it. They are not, and cannot be, Tier 1.
    ...    - Agent behaviour is specified as Malleable `.feature` files, which are also its test suite, and
    ...    \ \ run through monomono's Gherkin lifecycle. This is the SDLC the epic is planned in.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

7. Phase 4 — dropping LÖVE from the app
    [Documentation]    `.robot/docs/design.robot` §2 records that love now does three things: the frame loop plus ffmpeg pipe, the
    ...    GLSL escape hatches, and `preview`. To ship the app without it:
    ...
    ...    - **Perspective** — port the homography to a CPU projective warp in Rust. `.robot/docs/scene.robot` costs
    ...    \ \ it at 9.8 ms/frame through the current slot, so a CPU port is not obviously worse.
    ...    - **world3d** — already wgpu; it needs a slot that does not go through love.
    ...    - **shadertoy / worley / `s:draw`** — GLSL. Either port or declare CLI-only and have `lint` say so
    ...    \ \ when a comp in the app uses one.
    ...    - **preview** — the app's own preview replaces it.
    ...    - **The frame loop and ffmpeg pipe** — move to the Rust host.
    ...
    ...    Gate: `moonsplice golden compare` green on the scene path, and `moonsplice eval --open` eyeballed, before the
    ...    app's renderer is declared love-free. Goldens are recaptured deliberately, never incidentally.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

8. Open questions
    [Documentation]    - The recall target for the Tier-1 router. Set it from the first spike, before building on it.
    ...    - ~~Whether RADIO's licensing permits shipping the weights in a desktop app.~~ **Answered
    ...    \ \ 2026-09-21: it does not.** `nvidia/RADIO`'s LICENSE §3.3 limits use to "research or
    ...    \ \ evaluation purposes only". Replaced: `facebook/PE-Spatial-*` and `facebook/pe-av-*` are
    ...    \ \ Apache-2.0, and `nvidia/C-RADIOv3-*` carries the NVIDIA Open Model License, which permits
    ...    \ \ commercial use. See the `av-encoder` feature for the measured comparison.
    ...    - Whether `PE-Spatial-B16-512` or `C-RADIOv3-B` gives better dense features per unit of time.
    ...    - `pe-av-small` is 847M parameters, which is heavy for a per-window pass even at 1.27 s on MPS.
    ...    \ \ Check `pe-av-small-16-frame` and whether the video tower runs without the text tower loaded.
    ...    - Whether Tier 0 can absorb RAM++ tagging outright, which would remove one of the four
    ...    \ \ remaining torch models rather than porting it.
    ...    - buck2-native Rust and the manifest move into `packages/`: when, if ever. Blocked
    ...    \ \ on not breaking `cargo build --release` and `moonsplice build`.
    ...    - ~~What a project file is: a directory with a manifest, or a single document.~~
    ...    \ \ **Answered 2026-09-21: a directory with a manifest** (`moonsplice.json`). A single document
    ...    \ \ cannot have a third writer, and a text editor outside the app is a first-class editor of
    ...    \ \ this project by construction. Reasoning in the `app-shell` feature.
    ...    - Whether the pixel model belongs in this app at all. The tool exists and is gated so it can
    ...    \ \ never reach the composition, but it returns a refusal in this build: it takes a rendered
    ...    \ \ video and answers with another one, which enters the project as footage. Wiring it is
    ...    \ \ Phase 1 work, not shell work.
    [Tags]    doc    source:cadence@56ddad1:docs/DESKTOP.md
    Skip    prose

