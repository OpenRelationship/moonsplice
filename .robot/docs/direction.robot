*** Settings ***
Documentation    Direction: making the agent make something worth watching
...
...    2026-10-06. Why the producer agent's videos come out generic, one concept worked through to the
...    level we want, and how to get MiniMax M3 to produce work at that level, built on the plan in
...    `.robot/docs/capcut-parity.robot`.
Metadata    Source    cadence@56ddad1:docs/DIRECTION.md

*** Test Cases ***
1. Why the output is generic today
    [Documentation]    The problem is not the model. Three things in the code produce the generic result:
    ...
    ...    1. **The prompt asks for the average video.** `editor/core/host/producer.lua` gives a seven-step
    ...    \ \ \ recipe (transcript → keep → draw → captions) and a style note: "Vox-style means bold type, a
    ...    \ \ \ restrained palette, clean blocks". A model told to make the typical explainer makes it.
    ...    \ \ \ Nothing asks for an idea.
    ...    2. **The tools are a slide deck.** `draw` offers five kinds (text, rect, circle, image,
    ...    \ \ \ surface) and six entrances (fade, rise, pop, wipe, type, none). The renderer has 37 kinds,
    ...    \ \ \ including masks, `displace`, perspective cards, particles, kinetic type, the fx and shader
    ...    \ \ \ chains, `world` 3D, Lottie and blends. The agent reaches about a seventh of them, and only
    ...    \ \ \ the plainest seventh.
    ...    3. **The graphics cannot know what is in the picture, and the agent never looks.** Everything
    ...    \ \ \ is placed by pixel and second. The perception we already have (depth, tracking, people,
    ...    \ \ \ camera motion, words, OCR, tags) never reaches a tool, so a title cannot sit behind the boat,
    ...    \ \ \ follow the gull or land on the beat. Work that feels authored is almost always graphics in a
    ...    \ \ \ relationship with the footage. The agent also never sees a frame of its own result, although
    ...    \ \ \ M3 takes images and `moonsplice-vision` already makes contact sheets.
    [Tags]    doc    source:cadence@56ddad1:docs/DIRECTION.md
    Skip    prose

2. A concept at the level we want: *Tide Table*
    [Documentation]    A 60-second film of the harbour town in `evals/longform/Footage` (coastal road, harbour boats,
    ...    old town, aerial coastline, storm sea, nets, sunset, night lights, dock crane, ferry).
    ...
    ...    **Premise.** One tide, low to high to low, compressed into a minute. The town is shown the way
    ...    the water sees it.
    ...
    ...    **The governing rule.** There is one horizontal line in the film, the *waterline*. It rises and
    ...    falls over the minute as a tide does (a semidiurnal curve, 12 h 25 m compressed to 60 s). Every
    ...    shot is placed so that its own real waterline (where water meets land, hull or sky, measured per
    ...    frame) sits exactly on that line. Cuts are therefore match cuts on the water: the sea in one shot
    ...    continues into the harbour in the next at the same height. The rule creates the look. Nothing
    ...    needs decorating.
    ...
    ...    **Transitions are the tide.** No fades or wipes. The incoming shot is masked to everything below
    ...    the line, so it floods in as the line rises and drains out as it falls (`clip` on the line,
    ...    `clip_invert` for the ebb).
    ...
    ...    **Type is an almanac.** It is set like a nautical tide table, not a title card:
    ...    - one condensed grotesk with tabular figures carries the data;
    ...    - one serif italic carries a single human sentence per movement, at most six in the film;
    ...    - data sits above the line and the human line sits below it (the "underwater" voice);
    ...    - each data line is real-format almanac content (`04:12 \ LW \ 0.6 m`) whose clock advances with
    ...    \ \ the compressed tide.
    ...
    ...    No centred white titles, lower-thirds, drop shadows or caption bars.
    ...
    ...    **Palette from the footage.** Two colours sampled from the shots (the water at slack tide and
    ...    the sodium light of the night harbour) plus off-white. The line itself is the off-white,
    ...    1.5 px, the brightest thing on screen.
    ...
    ...    **Structure, six movements:**
    ...
    ...    | t (s) | Movement | Shots | The line |
    ...    |---|---|---|---|
    ...    | 0–8 | Low water | coastal road, aerial coastline | low in frame, barely moving; almanac fades up digit by digit |
    ...    | 8–20 | Flood | boats, nets, crane | rising; cuts on beats, each cut at a matched waterline |
    ...    | 20–32 | High water | storm sea | rises off the top of frame: the screen is "under"; type inverts to sit in the water |
    ...    | 32–40 | Slack | harbour at sunset | holds dead still for 4 s, the only stillness in the film |
    ...    | 40–52 | Ebb | ferry leaving, old town street | falling; shots drain away below it |
    ...    | 52–60 | Night | town lights on water | settles; last almanac line, then only the line |
    ...
    ...    **Sound.** One music bed with clear beats. Cuts land on beats only where the tide curve crosses
    ...    a shot's measured waterline within a beat's tolerance; that rule chooses the cut points. The
    ...    optional voice is a shipping-forecast reading of the six human lines (MiniMax speech-2.8,
    ...    low and even).
    ...
    ...    **Why it is not generic.** One rule produces every decision: framing, cuts, transitions, where
    ...    type may go, when stillness happens. The rule needs perception to execute, which a template tool
    ...    cannot do. And it describes something true about the subject: a harbour town runs on the tide.
    ...
    ...    *What it needs, and where it comes from*
    ...
    ...    | Need | Source | Status (CAPCUT_PARITY) |
    ...    |---|---|---|
    ...    | Waterline per frame per shot | water/sky segmentation (Vision foreground + depth discontinuity from Depth Anything 3); written as `holds(waterline_y(shot, t), …)` facts | depth have; line extraction build |
    ...    | Shot placed on the global line | per-frame offset/scale from the fact, smoothed (One-Euro), as Lua keyframes | auto reframe row, build |
    ...    | Calm moments to cut on | `camerafacts.py` camera motion | have |
    ...    | Beats | `beat_this` beat facts | build (audio pack) |
    ...    | Type kept off subjects | saliency (Vision) + `people.py` | build / have |
    ...    | Palette | colour sampling over the shots, as facts | small build |
    ...    | The six human lines | M3 watching 360p 2 fps proxies of the shots | build (MiniMax pack) |
    ...    | Voice | speech-2.8 | build (MiniMax pack) |
    ...    | Rendering | `s:video`, `clip` / `clip_invert`, `s:text`, `s:rect`, `t:` movements: all exist | have |
    ...
    ...    So the concept pins down the build order: a horizon/waterline fact, the reframe pack, beats,
    ...    and the MiniMax M3 + speech client. That is phases 2, 3, 5 and 6 of CAPCUT_PARITY §5, in an
    ...    order where each one shows up in a video.
    [Tags]    doc    source:cadence@56ddad1:docs/DIRECTION.md
    Skip    prose

3. Prompting M3 for this kind of work
    [Documentation]    *3.1 Three passes, not one loop*
    ...
    ...    1. **Director: a treatment before any tool call.** M3 watches the proxies (image/video input)
    ...    \ \ \ and writes three treatments in a fixed shape, then picks one. The shape is the prompt:
    ...    \ \ \ - premise in one sentence;
    ...    \ \ \ - **the governing rule**: one constraint that will decide framing, cuts and type;
    ...    \ \ \ - the grammar: at most two typefaces and their jobs, a palette sampled from facts, **one**
    ...    \ \ \ \ \ signature motion, and a ban list;
    ...    \ \ \ - structure in movements with times;
    ...    \ \ \ - for every visual element, the fact it is computed from. An element that cannot name its
    ...    \ \ \ \ \ fact must justify why it exists.
    ...    \ \ \ - the one thing a viewer will remember.
    ...    2. **Builder: the tools, at low temperature.** It executes the chosen treatment and nothing
    ...    \ \ \ else.
    ...    3. **Critic: looks at frames.** After a build, `contact_sheet` and `keyframes` from
    ...    \ \ \ `moonsplice-vision` go back to M3 as images, with a rubric (§3.3). At most two revision
    ...    \ \ \ rounds. The critic quotes the treatment's rule and says where the picture breaks it.
    ...
    ...    Diverge, then converge: run the treatments at higher temperature, then the build and critique
    ...    at low temperature.
    ...
    ...    *3.2 What goes in the system prompt*
    ...
    ...    - **Exemplars, not adjectives.** Replace "Vox-style" with two or three worked treatments at the
    ...    \ \ level of §2 (*Tide Table* is the first), each showing a governing rule doing real work. The
    ...    \ \ model copies the depth of thinking in an example far more readily than a style word.
    ...    - **An explicit ban list of defaults:**
    ...    \ \ - a centred white title over footage;
    ...    \ \ - fade in / fade out as the way things arrive;
    ...    \ \ - lower-thirds;
    ...    \ \ - drop shadows used for legibility;
    ...    \ \ - captions on footage with no speech;
    ...    \ \ - stock "pop" entrances;
    ...    \ \ - more than two typefaces;
    ...    \ \ - colour not taken from the footage.
    ...    \ \ Each is allowed only if the treatment argues for it.
    ...    - **"Restraint is a choice."** One signature motion used everywhere beats six effects used once.
    ...    \ \ The best moment in a minute is often stillness the rest of the film has earned (the slack
    ...    \ \ water in §2).
    ...    - **Relate, don't decorate.** Every graphic must be in a stated relationship with the picture:
    ...    \ \ behind, attached to, cut by, measured from, or timed to something in the footage.
    ...
    ...    *3.3 The critic's rubric (scored 1–5, built only if all ≥ 3)*
    ...
    ...    1. **Rule:** can the governing rule be inferred from the contact sheet alone?
    ...    2. **Relationship:** does each graphic relate to the footage, rather than float on it?
    ...    3. **Defaults:** count the banned defaults present (target 0).
    ...    4. **Rhythm:** do cuts and motion follow a structure (beats, the rule), not even spacing?
    ...    5. **Memory:** what is the one frame someone would screenshot?
    ...
    ...    *3.4 Tools that make the good thing the easy thing*
    ...
    ...    Keep `draw` for plain jobs, and add tools whose arguments are the footage's own structure. The
    ...    Rust side resolves each one from facts into ordinary Lua keyframes, so comps stay pure `f(t)`:
    ...
    ...    | Tool | What it does |
    ...    |---|---|
    ...    | `line` | a persistent rule (horizontal, a path, a curve over time) other things can be cut by |
    ...    | `mask_by` | show a thing only above, below, inside or outside a line, a subject or a shape (`clip`, `clip_invert`) |
    ...    | `pin` | attach a thing to a tracked subject (EdgeTAM boxes), smoothed |
    ...    | `behind` | put a thing behind a subject (person/subject matte, or depth cut) |
    ...    | `align` | place a shot so a measured feature (waterline, horizon, eye line, subject) lands at a given height or point |
    ...    | `on_beats` | time cuts or movements to beat facts, with a tolerance |
    ...    | `palette` | colours sampled from the shots, by role |
    ...    | `look` | the fx chain (grade, grain, bloom, vignette) as a named, consistent look for the whole piece |
    ...
    ...    Then raise the ceiling from slide kinds to the renderer's kinds: `kinetic`, `displace`,
    ...    perspective cards, `particles`, `world`. Each as a structured tool, not raw Lua.
    ...
    ...    One decision is the team's: `producer.lua` says no Lua the model writes reaches a composition.
    ...    A narrower alternative is to let the builder submit a Lua fragment that must pass
    ...    `moonsplice lint` and `check` before it is applied. That opens the whole renderer to it,
    ...    with the linter as the gate.
    ...
    ...    *3.5 Model routing*
    ...
    ...    `editor.lua` names `openrouter:minimax/minimax-m3`. CAPCUT_PARITY's constraint is local or the
    ...    MiniMax API only, so the director and critic passes (which send images and proxies) should go
    ...    through the MiniMax API client in its §5 phase 5.
    [Tags]    doc    source:cadence@56ddad1:docs/DIRECTION.md
    Skip    prose

4. Order of work
    [Documentation]    1. **Build *Tide Table* by hand, as a comp, from the ten clips.** Waterlines are measured once
    ...    \ \ \ with depth plus a little manual correction where the measurement fails. This proves the
    ...    \ \ \ renderer can carry the concept and gives the director prompt its first exemplar.
    ...    2. **Waterline and horizon facts, and `align`.** Replace the hand measurement.
    ...    3. **Beat facts and `on_beats`; `mask_by`, `line`, `palette`.**
    ...    4. **Director → builder → critic in `producer.lua`**, with the treatment shape, ban list,
    ...    \ \ \ exemplar and rubric above; contact sheets to M3 through the MiniMax client.
    ...    5. **Test.** Give the agent the same footage and only "a minute about this town". Judge its
    ...    \ \ \ treatment and its film against the hand-built one, then give it different footage and see
    ...    \ \ \ whether it finds a different governing rule.
    [Tags]    doc    source:cadence@56ddad1:docs/DIRECTION.md
    Skip    prose

5. The whole engine, for games as well as videos
    [Documentation]    The agent should be able to use everything the engine has, and build a game as readily as a
    ...    video. .robot/docs/canon.robot (amendment 2026-10-06) makes that compatible with the canon: a game is a pure
    ...    function of `t` and its input log, and a video is a game with no input.
    ...
    ...    **What the agent gets.** The full Lua API, not a tool per kind. It submits a composition or a game
    ...    as Lua. Before anything is applied, the Lua must pass `moonsplice lint` and `check` and render
    ...    a contact sheet, which goes back to the critic. The linter is the gate, which replaces "no Lua the
    ...    model writes". The structured tools in §3.4 stay, as the fast path for common jobs and as
    ...    fact-backed helpers the Lua can call.
    ...
    ...    **What the engine needs for games.** Most of it exists:
    ...    - deterministic fixed-step simulation: rapier2d with `enhanced-determinism` (`engine/src/physics.rs`,
    ...    \ \ today only `t:drop` bakes);
    ...    - a pure `f(t)` scene graph and one rasterizer;
    ...    - a long-lived session in the Studio's process (`moonsplice_engine::Session`).
    ...
    ...    The missing pieces:
    ...    1. **Input as events.** A serve op `input` that appends a timed event to the session's log, and
    ...    \ \ \ an authoring API (`s:on("key", …)`, `s:state(…)`) whose state is a fold over the log at fixed
    ...    \ \ \ steps. Snapshots every N steps make seeking cheap.
    ...    2. **Live play.** The Studio's preview pane already receives frames from the session. It forwards
    ...    \ \ \ keyboard, mouse and pad events and runs the clock in real time. No new window: the pane is the
    ...    \ \ \ game's screen.
    ...    3. **Live physics.** Rapier stepping per tick inside the fold, not only baked at compile time.
    ...    4. **Live audio.** Sound events mixed in the host while playing; the same events go through
    ...    \ \ \ ffmpeg when a recording is rendered.
    ...    5. **Recordings.** A played session saves its input log; `render` with that log is the trailer,
    ...    \ \ \ and a hand-written or agent-written log is an attract mode.
    ...
    ...    **First proof.** A small game in Lua, for example a harbour boat steered between buoys with
    ...    rapier physics. It is played in the Studio's preview pane, its input log is saved, and the same
    ...    log renders to an mp4 that hashes the same on every run.
    [Tags]    doc    source:cadence@56ddad1:docs/DIRECTION.md
    Skip    prose

