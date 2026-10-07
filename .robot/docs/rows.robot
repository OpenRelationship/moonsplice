*** Settings ***
Documentation    Rows: one data model for Moonsplice, Bevy and tablua
...
...    2026-10-06. The contract the three systems share. Moonsplice (the engine and its Lua DSL), Bevy (the
...    3D and game renderer) and tablua (the agent harness) all read and write the same rows. Every level
...    below names its rows, who writes them, who reads them, and the one rule that keeps them aligned.
...
...    Why: the engine was already data inside (a node is `{kind, id, props}`, the timeline is
...    `{node, prop, t0, t1, from, to, ease}` rows, Bevy worlds are `{id, shape, pos, ...}` rows). Only the
...    authoring surface was object-oriented: handles in locals, imperative scripts, views that mutate
...    handles. An agent could therefore only rewrite whole files, which is slow, error-prone, and gives
...    tablua nothing to learn from but "write". With rows as the contract, an edit is a typed patch, a comp
...    is a table SQLite can hold, and a frame is rows Bevy turns into entities by id.
Metadata    Source    cadence@56ddad1:docs/ROWS.md

*** Test Cases ***
The rule at every level
    [Documentation]    **A row is identified by a stable id, holds plain values (number, string, boolean, array of numbers),
    ...    and means the same thing in Lua, SQLite and JSON.** Lua tables are the authoring form, SQLite the
    ...    harness's form, JSON the wire form (serve protocol, Bevy). Converting between them is lossless and
    ...    deterministic (sorted keys, numbers as in §1), so the same comp is the same bytes everywhere.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 1: the comp as rows (schema msr/1)
    [Documentation]    | table | key | columns | meaning |
    ...    |---|---|---|---|
    ...    | `comp` | `key` | `value` | width, height, duration, fps, background, seed, color_space |
    ...    | `node` | `id` | `kind, parent, order` | one thing on screen or in a world; `parent` is a group or world id; `order` is draw and build order (a parent comes before its children). Not `z`: that is a 3D position prop |
    ...    | `prop` | `id, name` | `value` | a node's prop at rest (x, y, w, h, text, font, color, src, shape, pos, ...) |
    ...    | `key` | `id, name, t` | `value, ease` | a keyframe: from the previous key of (id, name) to this one, eased; `t` may be a fact reference (`beat:12`, `word:tide`) resolved at compile |
    ...    | `motion` | `id, name, t0` | `t1, curve, params` | motion that is not key to key: `curve` is `path`, `wiggle`, `follow`, `spring` or `drop`, `params` its settings; what the object API's `t:path`/`t:wiggle`/... record |
    ...    | `system` | `name` | `order, source` | a pure function `(t, state, q) -> rows`, run every frame after the keys; its rows are live props for that frame only. `game.init` / `game.step` are the game's fold; `shared` runs once and what it returns is `shared` to every other system and code prop |
    ...    | `asset` | `id` | `src, derive, solid, parts` | a media source and its derive ops (core/runtime/derive.lua), or a solid: `solid` is a CSG tree built by Manifold (.robot/docs/solids.robot), `parts` the number of pieces it is meant to have when more than one |
    ...    | `fact` | `pred, args, t0` | `t1, src, conf` | FACTS.md's grammar: `holds`/`happens`, `src` empty means exact |
    ...    | `input` | `t, n` | `down, up, x, y, press, release` | a game's input log (core/moonsplice/game.lua) |
    ...    | `game` | `key` | `value` | rate, seed; `init` and `step` are systems named `game.init` / `game.step` |
    ...    | `expect` | `id` | `says, node, prop, op, value, at, t0, t1, holds` | what the ask requires, as a predicate lint checks every run (below) |
    ...
    ...    **Expectations.** An `expect` row turns the ask into something checkable, MoVer-style. With only
    ...    `node`, the node must exist. With `prop`, its value must satisfy `op value` (`==`, `~=`, `>`, `>=`,
    ...    `<`, `<=`, or `has` for a substring) at `at`, or at every frame of `t0..t1`, or, with
    ...    `holds = "ever"`, at some frame of it. Times may be fact references. A failing row is an
    ...    `expect_failed` error finding naming the row's `says`. The harness writes expectations from the ask
    ...    before the first move. No patch move adds, edits or removes them, so a move cannot satisfy an ask
    ...    by deleting what it names: removing the almanac an ask is about is an error, not a tidier comp.
    ...
    ...    **Values.** A value is a number, a string, a boolean, or an array or object of those (a position
    ...    `{0, 1.2, -6}`, a material). In SQLite a value cell holds a number or a string natively; a boolean, an
    ...    array or an object is canonical JSON text (sorted keys; numbers as below) and the row's `type` column
    ...    says which (`n` number, `s` string, `b` boolean, `j` JSON). In JSON and Lua they are themselves.
    ...    A node reference (`parent`, `clip_node`, `camera`, flex `items`) is the referenced node's id.
    ...
    ...    **Keys.** An eased curve holds its first key's value before that key and its last after. A key with
    ...    ease `step`, and every key on a structural prop (`text`, `src`, `font`), switches at its time; before
    ...    the first such key the prop is at rest.
    ...
    ...    **Numbers.** An integer below 1e15 is written `%d`; any other number as the shortest of `%.15g`,
    ...    `%.16g`, `%.17g` that reads back as the same number (so 0.1 is `0.1`). One rule in Lua, SQLite and
    ...    JSON, and for ease names (`spring(180,12)`, `cubicBezier(0.2,0,0,1)`), which parse back into the ease.
    ...
    ...    **Code.** Code is text in a sandbox (no I/O, clocks or `math.random`), never a function value: a
    ...    system's `source`, or a prop whose value is `{ fn = "<source>" }` (a vector's `draw`, a world's
    ...    `entities`), whose function takes the engine's own arguments. Code reads the frame through `q`
    ...    (`q.get(id, name)`, `q.state`, `q.facts`), a name in its sandbox; a system also gets it as its third
    ...    argument. A comp written with the object
    ...    API whose props or views close over node handles dumps them as `opaque` systems: shown, not editable.
    ...
    ...    **Order.** Every dump is in a fixed order: tables in the order of the schema table above; nodes by
    ...    `order` (draw and build order), then id; systems by `order`, then name; every other table by its key
    ...    columns. Two dumps of one comp are byte-equal.
    ...
    ...    Kinds are the engine's kinds (rect, text, video, image, kinetic, vector, particles, fx, world,
    ...    mesh, light, camera, ...). 3D entities are nodes whose `parent` is a `world` node; their props are
    ...    Bevy's (`shape, pos, rot, size, material, light`). There is no second namespace for 3D.
    ...
    ...    The authoring form in Lua:
    ...
    ...    ```lua
    ...    return e.comp { width = 1920, height = 1080, duration = 12, fps = 30,
    ...    \ \ nodes = {
    ...    \ \ \ \ { id = "sea", \ \ kind = "video", src = "Footage/05-storm-sea-waves.mp4", w = 1920, h = 1080 },
    ...    \ \ \ \ { id = "line", \ kind = "rect", \ x = 0, y = 540, w = 1920, h = 2, color = "#f4efe6" },
    ...    \ \ \ \ { id = "tide", \ kind = "text", \ text = "04:12 \ LW \ 0.6 m", font = "BarlowCondensed-SemiBold", size = 56, x = 120, y = 496 },
    ...    \ \ \ \ { id = "w", \ \ \ \ kind = "world", w = 1920, h = 1080 },
    ...    \ \ \ \ { id = "buoy", \ kind = "mesh", \ parent = "w", shape = "cylinder", pos = { 0, 0, -6 }, material = { color = "#c0392b" } },
    ...    \ \ },
    ...    \ \ keys = {
    ...    \ \ \ \ { "line", "y", 0, 540 }, { "line", "y", 6, 220, "sineInOut" }, { "line", "y", 12, 540, "sineInOut" },
    ...    \ \ \ \ { "tide", "opacity", 0, 0 }, { "tide", "opacity", "beat:1", 1, "expoOut" },
    ...    \ \ },
    ...    \ \ systems = {
    ...    \ \ \ \ { name = "tide-follows-line", source = [[
    ...    \ \ \ \ \ \ return function(t, state, q) return { { id = "tide", y = q.y("line") - 44 } } end ]] },
    ...    \ \ },
    ...    }
    ...    ```
    ...
    ...    The object API (`s:rect{}`, `s:script`, `s:view`) stays. It compiles to the same rows, so every
    ...    existing comp and golden keeps working, and `moonsplice rows comp.lua` prints any comp as rows.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 2: evaluation
    [Documentation]    `frame(t, input_log) -> rows`: props at rest, then keys at t, then the game's fold to t, then the
    ...    systems in `order`. A system reads only through `q` (`q.get(id, name)`, `q.y(id)`, `q.facts`,
    ...    `q.state`) and returns rows; it cannot hold handles or write anything else. What systems return is
    ...    cleared before the next frame (.robot/docs/design.robot rule 1, games amendment). Same rows in, same frame out.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 3: rendering
    [Documentation]    The frame's rows split by layer, by id: nodes under a `world` become that world's entity rows and
    ...    go to Bevy (`render/src/world.rs` spawns or updates an entity per id and despawns ids that left);
    ...    every other node goes to the 2D rasterizer (`scene/`). Bevy is never handed anything but rows.
    ...    A game played live (`moonsplice play`) runs the same frame function; only its input rows arrive live.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 4: facts and derive
    [Documentation]    Perception and derive write `fact` and `asset` rows (beats, words, waterlines, saliency, cutouts),
    ...    each with its `src`. Keys and systems bind to facts by reference (`t = "beat:12"`,
    ...    `q.facts("waterline", shot, t)`), so a comp states what it is computed from, as DIRECTION.md asks.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 5: validation
    [Documentation]    lint and check emit `finding` rows: `id, name, code, severity, t0, t1, measured, threshold`, keyed
    ...    by the node and prop they are about. A finding with no node is about the comp. One problem is one
    ...    row: a measured finding sampled at many times (`contrast_measured`) is a single row per (id, code)
    ...    whose `t0..t1` spans the failing samples, whose `measured` is the worst value, and whose `detail`
    ...    names the worst time and how many samples fail. So a count of error rows is a count of problems.
    ...    Solids add `solid_empty` and `solid_not_watertight` (errors) and `solid_parts` (a warning when the
    ...    pieces differ from the asset's `parts`, or number more than one with none declared). Expectations add
    ...    `expect_failed` (an error). `key_overridden` (an error): a key on a prop a system sets every frame, which can never
    ...    show, since systems run after the keys. `text_overflow` (check, an error): a text's measured box runs past the
    ...    panel it sits in, or the frame. `subject_cropped` (lint, a warning): a small mesh in a world is cut
    ...    by or leaves the camera's view for over 20% of the piece, projected through the world's camera.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 6: the agent's moves (tablua)
    [Documentation]    The agent edits a comp only through typed patches. Each is one row in tablua's action table, with
    ...    the patch as its payload, and each is checked before it lands:
    ...
    ...    | move | payload | effect |
    ...    |---|---|---|
    ...    | `add_node` | node row + props | insert |
    ...    | `set_prop` | id, name, value | upsert one prop |
    ...    | `add_key` / `move_key` / `drop_key` | id, name, t, value, ease | keyframes |
    ...    | `bind` | id, name or key, fact reference | tie a value or time to a fact |
    ...    | `add_system` / `edit_system` | name, order, source | one small pure function |
    ...    | `derive` | asset id, ops | media work in the resolve phase |
    ...    | `solid` | asset id, solid tree | a solid built by Manifold; a mesh node shows it with `src = "asset:<id>"`, an entity with `solid = "asset:<id>"` |
    ...    | `remove` | id | delete a node and its props, keys and children |
    ...    | `treat` | text | the director's treatment (not a comp edit) |
    ...
    ...    A value of the wrong type is rejected at the patch with its reason (`opacity needs a number, not
    ...    "0"`): numeric props take numbers, `text`/`src`/`font`/`anchor`/`blend`/`shape` take strings, colours
    ...    take `"#rgb[a]"`, `"#rrggbb[aa]"` or `{r,g,b,a}`, and a null value clears a prop. A string that is
    ...    exactly a number (`"500"`, `"0.9"`) given for a numeric prop or a key's `t` is stored as that number:
    ...    models writing JSON quote numbers often, and the reading is unambiguous.
    ...
    ...    A patch applies to the rows, the rows are linted and checked, and the response says what happened;
    ...    tablua judges the step from it (it owns the outcome rule): `complete` when the findings on what it
    ...    touched are gone and nothing new appeared, `neutral` when the digest changed but no finding opened or
    ...    closed (findings cannot judge it; the next look's critic score does), `no_effect` when the digest did
    ...    not change, `broken` when it added errors. Whole-file rewrite is not a move.
    ...
    ...    *The engine commands tablua calls*
    ...
    ...    All print JSON on stdout and exit 0 whenever they ran; a non-zero exit means the command itself
    ...    failed (message on stderr). A rejected patch is data, not an exit code.
    ...
    ...    | command | prints |
    ...    |---|---|
    ...    | `moonsplice rows COMP --json` | `{schema: "msr/1", tables: {comp, node, prop, key, motion, system, asset, fact, input, game, expect}, digest, derived, solids}`; `derived` lists the facts the assets' derive produced (`{pred, args, t0, t1, src, asset}`), outside the digest; `solids` maps each solid asset to what it came out as (`parts, genus, watertight, empty, volume, area, triangles, min, max, size`, Y-up metres), also outside the digest: the tree is in the digest (an asset row), its measurements are derived from it |
    ...    | `moonsplice patch COMP PATCHES.json --json` | `{applied: [patch], rejected: [{patch, why}], touched: [{id, name}], digest_before, digest_after, findings: [finding]}`; COMP is written back in rows form; `touched` includes what a `remove` cascaded to; `findings` is the full list after the patches, never a delta |
    ...    | `moonsplice expect COMP ROWS.json --json` | `{added: [row], rejected: [{row, why}], digest_before, digest_after, findings: [finding]}`; the harness writes the ask's expectations once, before the first move. A row is added unless its id exists (existing rows, a seed's invariants, are never edited); a malformed row, one whose fact reference no asset makes, or one whose time falls outside the comp is rejected with why. A row may name a node the comp does not have yet: it is an `expect_failed` until a move makes it. Idempotent |
    ...    | `moonsplice rows COMP --brief` | text, for a language model: one line per node in draw order (children indented) with its props, its keys with fact references resolved to seconds, and what systems set on it every frame; the systems by what they set and spawn (read from the evaluated comp, never declared); the expectations held or failing; the open errors and warnings of lint and check (check renders, about a second). The tables are for the sheet and the learner; a prompt is rendered from them as this |
    ...    | `moonsplice gate COMP --json` | `{state: {digest, errors, warnings, expect_held, expect_total, failing, line, passed}, findings}`: the engine's one line of truth (`state: digest 6123faea; errors 0; warnings 3; expect 14/14`), and whether a hand-in passes (no error, every expectation held). `patch` and `expect` replies carry the same `state`, and `patch` a `delta` (`closed contrast_measured t4, text_overflow t4 \\| opened none`) against the findings before it. A harness ends every result with them, so the newest message in an append-only transcript is always current |
    ...    | `moonsplice lint COMP --json`, `check COMP --json` | `{findings: [finding]}` |
    ...    | `moonsplice sheet COMP OUT.png --json` | `{picks: [t, ...], seconds}`: a contact sheet for the decider and the critic |
    ...
    ...    A finding row: `{tier: "lint" | "check", id, name, code, severity, t0, t1, measured, threshold, detail}`.
    ...    `digest` is the sha1 of the canonical rows dump.
    ...
    ...    *In tablua's sheet*
    ...
    ...    tablua's tables all start `tablua_`. The comp's rows go in as `tablua_msr_<table>` (comp, node, prop,
    ...    key, motion, system, asset, fact, finding), each with `(todo, n)` first: the comp as it stood after
    ...    step n (n = 0 for the start), so what step n changed is the difference between n-1 and n.
    ...    Otherwise the columns are §1's and §5's. Scores go to `tablua_score (todo, n, judge, dim, value)`,
    ...    judge `critic` | `oracle`.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 7: learning
    [Documentation]    tablua's step rows (state, candidate, decision, outcome) gain the comp's features at decision time:
    ...    counts by kind, open findings by code and severity, the target's kind and prop for each candidate
    ...    move, the critic's lowest item. TabICL ranks candidate moves from these rows, locally: TabICLv2 in Candle inside the Moonsplice
    ...    binary (`tabicl/`, at parity with tablua's server: .robot/claims/tabicl.robot), handed to tablua as
    ...    `host.tabicl` (`MOONSPLICE_ENGINE.tabicl` in the engine, `moonsplice tabicl` outside it); the decider,
    ...    `openai/gpt-6-luna-decisions` on OpenRouter's decisions API, picks the move and is shown the latest
    ...    contact sheet as an image beside the rows; MiniMax M3 writes the payloads and is the critic. The comp's own rows live in the same SQLite file as the steps, so a step can
    ...    be joined to exactly what it changed.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 8: claims
    [Documentation]    `.robot` claims read these tables directly: findings per move, outcome by move type, the gate,
    ...    the critic, the per-frame hashes. A claim about the harness is a query over the same rows the
    ...    harness wrote.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Level 9: process
    [Documentation]    One LuaJIT state holds the comp's rows, the engine's evaluator and, in the Studio, tablua: the
    ...    engine's `Session` (engine/src/session.rs) gains serve ops `rows` (the comp as rows), `patch`
    ...    (apply patches, recompile, return findings) and `frame`. Outside the Studio, tablua drives
    ...    `moonsplice` with the same ops. The .lua file is the rows written out in a fixed order, so a
    ...    person reads and diffs the same thing the agent edits.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

Ownership
    [Documentation]    - Moonsplice owns the schema (`core/moonsplice/rows.lua`), compile, evaluation, rendering, findings
    ...    \ \ and the serve ops.
    ...    - tablua owns the harness: the Moonsplice world (moves above), the features, the learner's heads,
    ...    \ \ the ports to the engine and to the models, and the claims runner.
    ...    - A change to a table's columns is a change to this file first, then to both sides.
    [Tags]    doc    source:cadence@56ddad1:docs/ROWS.md
    Skip    prose

