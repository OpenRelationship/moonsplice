*** Settings ***
Documentation    Moonsplice: the bet
...
...    An engine for games and videos where the representation is uniform enough that a model can treat creation
...    itself as a prediction problem. Authoring becomes next-row prediction. The agent is not writing code against an
...    opaque system. It is extending a table it fully understands.
...
...    *Representation is the whole game.* Every serious engine makes a bet about where its intelligence lives. Most
...    put it in the code: a renderer, a scene graph of objects with methods, an editor full of special cases, and on
...    top of that a person or a model writing more code against all of it. The system is powerful and opaque. To know
...    what a scene is, you have to run it.
...
...    We put the bet somewhere else. If everything is data, everything is predictable. We force the whole engine into
...    one tabular, data-oriented shape: the state, the behaviour, the edits, the results of every check, the history
...    of every agent step. Rows and columns, with stable ids and plain values. We do this because it is the shape
...    foundation models are getting good at:
...    - Tabular prediction models eat rows and columns. A model like TabICL takes a table of examples and predicts a
...    new row's label in context, with no training run. If our world is rows, it can rank the next move, spot the
...    anomaly and fill in the gap.
...    - Language models read rows well when the rows are small, typed, named and consistent. A comp printed as rows
...    (moonsplice rows COMP --brief) is something a model can hold whole. A thousand-line render loop is not.
...    - Anomaly is a row that does not fit. When state is a table, "something is wrong" becomes "this row is far from
...    its neighbours". Findings and critic scores are rows too, so a model can learn which states lead to which.
...    So the engine is legible to models by construction, not by documentation. We do not explain an opaque system
...    to the model. We give it a system with nothing hidden.
...
...    *What predictable means.* Three things, and we want all three. Deterministic: a comp is a pure function of time
...    t (for a game, of t and the input log up to t); any frame, in any order, is the same bytes every time. Legible:
...    a model or a person can read the whole state as rows and know what is on screen, what moves, what a system sets
...    and what the ask requires, without running anything. Forecastable: every step an agent takes is also rows (the
...    state before, the move, the outcome), so a model can learn which move tends to work in a state like this one.
...    Determinism makes legibility trustworthy. Legibility makes forecasting possible. Forecasting is the payoff.
...
...    *The unification.* Because everything is one tabular substrate, the same model that helps build a game helps
...    edit a video. To the model they are the same kind of object, just different rows. A video is nodes, props, keys,
...    motions, assets, facts from the footage and expectations. A game is the same rows plus an input table (the
...    player's log) and a game table (rate and seed), with game.init and game.step as systems that fold the input at a
...    fixed step. A 3D world is the same rows drawn by Bevy: entities are node ids, components are props, systems are
...    small pure functions. A played session renders as a trailer, because a recording is the case where the input
...    log is fixed. None of this needed a second engine; it fell out of keeping one representation. That is the
...    ambitious version of the bet: one substrate, one set of moves, one learner and one record of experience for
...    everything we make.
...
...    *Every choice serves the same master.* Keep it tabular. Keep it declarative. Keep it predictable.
...    - Bevy, because ECS is a table: entities are row ids, components are columns, systems are functions over rows.
...    It forces the data-oriented discipline that makes the world model-legible down to the renderer.
...    - Lua, as the thin typed move layer: Lua tables are the authoring form of rows, and behaviour is a small pure
...    function stored as text in a row, sandboxed. Behaviour stays data.
...    - SQLite and JSON: the same rows in the harness's form and on the wire, converted losslessly, one digest.
...    - Typed moves and selectors: an edit is a checked patch that names its target by a query over rows, never an
...    imperative script or a file rewrite; the editor's gestures lower to the same moves the agent sends.
...    - Expectations, findings, scores and claims: the ask, the checks and our beliefs are rows keyed like the steps
...    that caused them, so outcomes join to causes.
...    - TabICL, local, inside our own binary: a hook that ranks moves from the rows we keep, never the driver.
...    - Robot Framework: tests, tasks and docs are keyword trees, which are rows too.
...    - Tablua: one model, a short prompt, a few tools, a loop that ends when the model says it is done, and a
...    transcript that is rows.
...
...    The test cases below are the principles, the anti-patterns, the questions to ask of a proposal and the ways the
...    bet could lose. Each is skipped until someone makes it checkable, and the Skip says how it would be checked;
...    making one into a real test is always welcome. The locked decisions that implement the bet are
...    .robot/docs/canon.robot; the data model is .robot/docs/rows.robot; how to work here is AGENTS.md.
Metadata    Owner    Shane, 2026-10-07

*** Test Cases ***
P1 Every Fact Has A Row
    [Documentation]    If something is true about a comp, a step or a run, it is stored as a row somewhere a model can
    ...    read, not only in a log line, a variable or a person's head. "The title is clipped 74 px at 22:58" is a
    ...    finding row, not a sentence in a transcript.
    [Tags]    principle
    Skip    not yet checked: every lint and check message is emitted as a finding row (no free-text warnings)

P2 Stable Ids And Plain Values
    [Documentation]    A row is identified by a stable id and holds numbers, strings, booleans, or arrays and objects
    ...    of those. No function values, pointers or handles. A node reference is the node's id.
    [Tags]    principle
    Skip    not yet checked: rows --json of every eval case holds only plain values

P3 One Meaning In Every Form
    [Documentation]    A row means the same thing in Lua, SQLite and JSON, and converting between them is lossless.
    ...    A new form (a Bevy component, an editor view) is another view of the same rows, never a second source of
    ...    truth.
    [Tags]    principle
    Skip    not yet checked: rows -o NEW.lua then rows NEW.lua gives the same digest for every eval case

P4 Edits Are Moves
    [Documentation]    State changes through typed, checked moves that are themselves rows: never a whole-file rewrite,
    ...    a hidden setter, or an imperative script that walks the scene. A person's gesture in the editor lowers to
    ...    the same moves.
    [Tags]    principle
    Skip    not yet checked: the editor writes comps only through lower.rs's moves

P5 Behaviour Is Data
    [Documentation]    When something must run, it is a small pure function stored as text in a row, run in a sandbox,
    ...    reading the frame through the engine's query and returning rows, with no I/O, clock or randomness of its
    ...    own. Prefer a declarative row (a key, a motion, a bind to a fact) over a system whenever one exists.
    [Tags]    principle
    Skip    not yet checked: a system that writes to the host's tables or to q.state is a finding (AGENTS.md, gap 4)

P6 Determinism By Construction
    [Documentation]    Seek, not playback: any frame, any order, the same bytes. Seconds, not frames: fps is a render
    ...    parameter, and a time becomes a frame through one rule. Network and asset work happen in the resolve phase,
    ...    never during render. Games fold their input log at a fixed step with seeded randomness. Output that depends on
    ...    wall time, thread scheduling or table iteration order is a bug even when nobody can see it yet.
    [Tags]    principle
    Skip    not yet checked: hash twice, and in reverse frame order, gives the same per-frame md5 for every case

P7 Outcomes Are Rows
    [Documentation]    Findings, critic scores, step outcomes (complete, neutral, no_effect, broken) and claim verdicts
    ...    are rows keyed like the steps that produced them. Prefer an outcome a learner can read over a message a
    ...    person has to interpret.
    [Tags]    principle
    Skip    not yet checked: every tablua step has an outcome row and a findings snapshot

P8 The Ask Is Rows
    [Documentation]    Turn what was asked into expect rows before the first move. A request that cannot be stated as
    ...    rows is a request we do not understand yet.
    [Tags]    principle
    Skip    not yet checked: every trial's comp has expect rows before step 1

P9 Legible Source
    [Documentation]    The code itself is legible to a model: no file over 400 lines, split by responsibility, one
    ...    module one job, names that say what a thing is. A model that cannot hold a file whole cannot reason about
    ...    it whole. This one is checked.
    [Tags]    principle
    Every File Is Within The Limit

P10 The Schema Is A Contract
    [Documentation]    core/moonsplice/rows/ owns the schema (msr/1) and .robot/docs/rows.robot describes it. A change
    ...    to a table's columns changes that doc first, then both sides, Moonsplice and tablua. Columns are never
    ...    added quietly.
    [Tags]    principle
    Skip    not yet checked: the tables and columns rows.lua emits match those rows.robot lists

P11 Believe Only What You Measured
    [Documentation]    Before saying a change works, is fixed or is better when something will be built on it, write
    ...    the claim as a Robot test with its kill number and a red proof that fails at its assertion, commit it, then
    ...    measure. Say which level was shown: consistent, correct, informative or useful.
    [Tags]    principle
    Skip    checked by the claims themselves (.robot/claims, luajit .robot/claims.lua reds)

P12 Data First, Then The Feature
    [Documentation]    A new capability starts as rows: what table, what columns, what moves, what findings. The
    ...    renderer, the editor and the agent's tools come after, as readers and writers of those rows. A feature that
    ...    can only be reached through code is not finished.
    [Tags]    principle
    Skip    not yet checked: every node kind and move in rows.robot is reachable by a patch

Anti-Patterns
    [Documentation]    Each of these quietly breaks the bet.
    ...    - The opaque blob: a prop whose value is a big serialized structure nobody can query. Split it into rows.
    ...    - The function value: a closure, callback or handle in state. Store source text, or an id.
    ...    - The hidden clock: os.time, math.random, frame counters or anything wall-clock in a comp, a system or the
    ...    render path.
    ...    - Iteration order as output: JSON, briefs or hashes in whatever order a hash table returns. Sort.
    ...    - The side channel: state in a module variable, a temp file or the editor's memory that is not in the
    ...    rows. If the agent cannot read it, the agent cannot predict it.
    ...    - Prose outcomes: "looks good" in a transcript instead of a score row; a warning printed instead of a
    ...    finding.
    ...    - The whole-file rewrite: regenerating a comp or a module to make one change. Make the move.
    ...    - The special-case engine: a second code path for games, 3D or the editor. Add rows, not engines.
    ...    - Caps instead of information: stopping an agent with step, turn or token limits instead of giving it
    ...    better information to decide when it is done.
    [Tags]    doc
    Skip    prose

How To Judge A Proposal
    [Documentation]    A good design, feature or refactor can answer all seven.
    ...    1. What rows does it add or change, in which tables, with what ids?
    ...    2. Is it reachable by a typed move, and does the editor's gesture for it lower to the same move?
    ...    3. Is it deterministic? What would its golden be?
    ...    4. What findings or expectations make it checkable?
    ...    5. Can a model read the result with rows --brief and understand it without running anything?
    ...    6. Does it work for a video, a game and a world alike, or does it fork the engine?
    ...    7. What claim would show it helps, and what number would kill that claim?
    [Tags]    doc
    Skip    prose

Where The Bet Could Lose
    [Documentation]    A bet worth making can lose. We keep the ways it could lose in view, and we measure them.
    ...    - Tabular learning may not beat simpler baselines on our step rows. Measured: the TabICL Brier claim
    ...    (.robot/claims/tabicl.robot) and tablua's learner-against-base-rate claims. If those are killed, the
    ...    learner is a logging layer and we say so.
    ...    - Some things may resist rows. Shader code, hand-drawn vector paths and physics are still code or blobs in
    ...    places ({ fn = ... } props, escape hatches in image slots). Each is a debt to keep small and named, not a
    ...    new norm.
    ...    - Legible is not the same as easy. Rows can be uniform and still too many. The brief, the digest and the
    ...    findings exist so a model reads a summary that is exact, not a dump.
    ...    - Determinism has corners. Thread counts change pixels by a few bits, fonts differ per platform, and the
    ...    runtime has known gaps (AGENTS.md, "Known gaps against the bet"). Goldens are scoped to platform and
    ...    thread count, and every nondeterminism found is a bug to fix, not a tolerance to widen.
    [Tags]    doc
    Skip    prose

Words
    [Documentation]    comp: a composition, a video or a game, written as Lua that compiles to rows.
    ...    rows: the comp in schema msr/1, tables comp, node, prop, key, motion, system, asset, fact, input, game, expect.
    ...    move: a typed patch, the only way an agent edits a comp.
    ...    finding: a row lint or check produced: tier, node, code, severity, span, measured value, threshold.
    ...    fact: a row about time (holds or happens), exact when it has no src, perceived when it has one.
    ...    todo: what the agent is asked to do, the key of every tablua log table. A task is only a Robot task.
    ...    claim: a belief about the system, as a Robot test with a kill number and a red proof.
    ...    gate: the engine's one line of truth about a comp: digest, errors, warnings, expectations held.
    [Tags]    doc
    Skip    prose
