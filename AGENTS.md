# Moonsplice

An engine for games and videos where the representation is uniform enough that a model can treat creation itself
as a prediction problem.

This file is for agents (and people) working in this repository: the design bet in brief, then how to work here.
The design itself, argued in full, is `.robot/docs/design.robot` (run it: `luajit .robot/run.lua docs/design`).
The locked decisions that implement it are `.robot/docs/canon.robot`, and the data model is `.robot/docs/rows.robot`.
When a decision could go either way, the answer is usually in the design doc.

This is the one markdown file in the repository, and the one file allowed past 400 lines (`.robot/rules.robot`
says so). Everything else that documents Moonsplice is a Robot suite in `.robot/docs/`. `CLAUDE.md` links here.

---

# Part I: The bet, in brief

**Authoring becomes next-row prediction.** You are not writing code against an opaque system. You are extending a
table you can read whole.

Everything in Moonsplice is rows with stable ids and plain values: the comp's state, its behaviour, every edit,
every check's result, and every step an agent takes. That is the shape tabular models (TabICL, inside our binary)
and language models read and predict well, so the engine is legible to models by construction. A game and a video
are the same kind of object, just different rows, so one model and one set of moves serve both.

"Predictable" means three things, and every change must keep all three:

1. **Deterministic.** A comp is a pure function of time (and, for a game, of its input log). Same frame, same bytes.
2. **Legible.** The whole state can be read as rows (`./moonsplice rows COMP --brief`) without running anything.
3. **Forecastable.** Each step is rows (state, move, outcome), so a learner can rank the next move.

## The principles you work by

Each is a test case in `.robot/docs/design.robot`, with the reasoning.

- **P1 Every fact has a row.** If it is true about a comp, step or run, a model can read it as a row.
- **P2 Stable ids, plain values.** No functions, pointers or handles in state; references are ids.
- **P3 One meaning in every form.** Lua, SQLite and JSON are lossless views of the same rows.
- **P4 Edits are moves.** Typed, checked patches. Never a whole-file rewrite or an imperative scene walk.
- **P5 Behaviour is data.** A small pure function as source text in a row, sandboxed; prefer a declarative row.
- **P6 Determinism by construction.** No wall clock, no unseeded randomness, no iteration order in output.
- **P7 Outcomes are rows.** Findings, scores, step outcomes and verdicts, keyed to the steps that caused them.
- **P8 The ask is rows.** Expectations before the first move.
- **P9 Legible source.** No file over 400 lines, split by responsibility.
- **P10 The schema is a contract.** Change `.robot/docs/rows.robot` first, then both sides.
- **P11 Believe only what you measured.** A claim with a kill number and a red proof before "works".
- **P12 Data first, then the feature.** Rows, moves and findings first; renderer, editor and tools after.

## Before you build anything, answer these

1. What rows does it add or change, in which tables, with what ids?
2. Is it reachable by a typed move, and does the editor's gesture lower to the same move?
3. Is it deterministic? What would its golden be?
4. What findings or expectations make it checkable?
5. Can a model read the result with `rows --brief` without running anything?
6. Does it work for a video, a game and a world alike, or does it fork the engine?
7. What claim would show it helps, and what number would kill that claim?

## What breaks the bet

The opaque blob, the function value, the hidden clock, iteration order as output, the side channel, prose
outcomes, the whole-file rewrite, the special-case engine, and caps instead of information. The design doc says
why each one breaks it.

---

# Part II: Working here

## Layout

```
moonsplice   the launcher: luajit core/cli (every command)
core/        Lua, one folder per area
  moonsplice/  the authoring API comps call: scene graph, timeline, rows (the schema), lint, game
  runtime/     the engine's Lua: painter, resolve, render, serve, rows mode
  host/        Moonsplice as tablua's world: tools, asks, trials
  cli/         the command line
native/      Rust, one cargo workspace: engine (LuaJIT host), scene (rasterizer), render and play (Bevy),
             tabicl (TabICLv2 in Candle), solid (Manifold), decode, track, layout, embed, cli, scene3d;
             native/apple is Swift for VideoToolbox and Vision
editor/      the desktop app: Tauri (src-tauri, its own cargo project) and React (src)
comps/       compositions with their media: cases (the eval suite), examples, lessons, film, projects
assets/      fonts, brand and shared media
test/        run.lua: every core/**/*_test.lua
tablua/      the agent harness, a submodule (its own repository and its own AGENTS.md)
.robot/      all Robot: rules.robot, docs/, claims/, golden/, fixtures/, eval/, suites/, port/
```

Nothing else goes at the root. A new top-level folder is a decision for the owner, not a convenience.

## Laws

`luajit .robot/run.lua` runs `.robot/rules.robot`. These must pass:

- No code, config or Robot file over 400 lines. Split by responsibility, never by line count. Data (fixtures,
  goldens, JSON, lockfiles) and media are exempt, and so is this file.
- No markdown except this file. Documentation is Robot: a page is a suite whose sections are test cases tagged
  `doc`, each with `Skip    prose` until someone makes it checkable. Making a doc section into a real test is
  always welcome.
- All Robot lives in `.robot/`.
- The root holds only what the layout above lists.
- `core/` and `.robot/` are at most three folders deep.
- Lua is at least 60% of the lines of code outside `editor/`.

## Commands

```
./moonsplice rows COMP --json | --brief      the comp as rows, or as a model reads it
./moonsplice patch COMP PATCHES.json --json  typed moves; COMP is written back in rows form
./moonsplice expect COMP ROWS.json --json    the ask's expectations, added once before the first move
./moonsplice gate COMP --json                state line: digest, errors, warnings, expectations held
./moonsplice lint|check COMP --json          findings
./moonsplice render COMP -o OUT.mp4          hash COMP     sheet COMP OUT.png --json [--n 6]
./moonsplice tabicl                          JSON bodies on stdin, probabilities out
./moonsplice play COMP                       a game in a Bevy window
luajit test/run.lua [word ...]               unit tests (core/**/*_test.lua, tablua's test/spec.lua)
luajit .robot/run.lua [SUITE] [--tasks]      Robot suites: rules (default), docs/<page>, port, port/done
luajit .robot/claims.lua                     the claims and their ledger
cargo build --release   (in native/)         the engine; the launcher builds it once if it is missing
```

Every engine command prints JSON on stdout and exits 0 when it ran. A non-zero exit means the command itself
failed. A rejected patch is data in the JSON, not an exit code.

## Determinism and goldens

- `.robot/golden/<case>.scene.md5` holds per-frame hashes of every eval case, scoped to platform and
  `MOONSPLICE_SCENE_THREADS`. A change that alters a golden alters pixels: either it is the point of the change
  (recapture, and say why in the commit) or it is a bug.
- Refactors, including splitting files, must leave every golden byte-identical.
- Known nondeterminism to fix: `rows --brief` line order and `--json` key order can vary between runs on the same
  comp. Do not compare raw brief text or raw JSON across runs; compare tables or digests.
- One time rule: a time becomes a frame through one helper, `floor(t * fps + 1e-6)`, everywhere a time is
  floored or compared. Never floor a raw double. Fps may be rational (`30000/1001`) and stays rational all the
  way to ffmpeg.

## Known gaps against the bet

An audit of the runtime at the port (2026-10-07, against Cadence 56ddad1) found places where the code does not yet
keep the promises in Part I. They are the first engine work after the splits, in this order. Until each is fixed,
do not build on the behaviour it describes.

1. **Systems are not protected per frame.** A system that fails only at some times collapses lint and check to
   one compile error and kills `rows --brief`, and render leaves a partial mp4. Fix: run each system under
   `xpcall` every frame. A failing system adds no rows that frame (nodes fall back to their keyed or rest values),
   and each failure becomes a `system_error` finding with system, line, first and last time, and count.
2. **Checks sample too little.** `patch` evaluates three times and lint assumes 30 fps, so a comp can pass the
   gate and still fail to render. Lint and patch evaluate every frame at the render fps; render writes to a temp
   file and renames it on success.
3. **Time is floored as raw doubles.** About 19% of cached frames index one frame off, accumulated waits drift
   late, `30000/1001` encodes at 29 fps, the two decoders round differently, check samples off the frame grid,
   and the brief prints times as `%.2f`, which an agent copies into patches. The brief prints frames instead, as
   `f10 (0.333s)`. Fix with the one time rule above, keys snapped to the render grid at compile, and one decoder
   rule (the frame whose interval contains `t`, the stream's start time subtracted).
4. **The sandbox leaks.** Systems get the host's real `string` and `table`, and `q.get`, `q.facts` and `q.state`
   return live tables. A system that mutates state makes frames depend on render order. Fix: a read-only view of
   the world for systems, then `q.select` over compile-time indexes.
5. **Defaults are merged into what was authored.** The rows stay as authored, but `node.initial` holds both:
   `make_node` merges kind defaults into it, compile adds `x = 0` for many kinds, and the camera, world and mesh
   constructors add `yaw = 0`, so a reader cannot tell `x = 0` authored from `x = 0` defaulted (the light-kind and
   lint-yaw bugs). Some readers also skip `Node:get`, so those props cannot be animated. Fix: a defaults layer
   (authored, then kind defaults, then state) that never writes into what was authored.
6. **Each curve kind is spelled four times** (recorder, segment value, rows, dump). Fix: one registry of curve
   kinds, each with a compile and a dump, and rows that carry names and params only, never functions.
7. **Games replay from zero.** There are no snapshots yet, so seeking a game in random order costs quadratic time.

Two docs describe things that do not exist yet: signals and a coroutine timeline. Treat them as plans. Scripts
already run once at compile and record keys; that is the storyboard, and no coroutine runs at render.

## Working on the engine

- Read `.robot/docs/design.robot` (the bet), `.robot/docs/canon.robot` (the locked canon decisions) and
  `.robot/docs/rows.robot` (the data model) before changing anything that touches comps, rendering or the schema.
  Change a canon decision only with a written reason in canon.robot.
- `core/moonsplice` is host-free: it never touches the renderer, Rust or the file system. Comps call it.
- `core/runtime` is the engine's Lua, run by `native/engine` (LuaJIT through mlua). Its modules are required by
  bare name (`require("painter")`); the engine puts `core/runtime` on the path.
- `core/runtime/boot.lua` and `love.lua` are compiled into the engine (`include_str!`): after editing either,
  rebuild it (`cargo build --release -p moonsplice-engine` in `native/`) or the old copy keeps running.
  `boot.lua` also loads `serve/init.lua` by path, so moving a runtime module it names means editing it too.
- A feature the engine has not ported exits with status 3 and a sentence naming the node and the feature.
- New node kinds, props or moves: rows first (P12), then lint and check findings, then the painter, then the
  editor and the agent's tools.

## Working on the editor

- `editor/src-tauri` finds the engine by `./moonsplice` and `core/moonsplice/init.lua` from its working directory
  or executable, or `MOONSPLICE_ROOT`.
- Every gesture lowers to typed moves (`src-tauri/src/lower.rs`); the editor never writes a comp any other way.
- Its in-app agent is being moved from malleable (dropped) to tablua's `agent.loop`.
- `editor/.tauri-plugin-mcp` is vendored by a build step, not committed.

## Working with tablua

- tablua is the harness, developed in its own repository (`~/tablua`, `OpenRelationship/tablua`). Never edit
  `tablua/` here; commit there, push, then bump the pin here with `git -C tablua fetch && git -C tablua checkout
  <sha>` and a commit.
- Moonsplice owns the schema, compile, evaluation, rendering, findings and the engine commands. tablua owns the
  moves as the agent sees them, the features, the learner, the ports and the claims runner. A schema change is a
  change to `.robot/docs/rows.robot` first, then both sides.
- tablua's harness works the way pi does: one model, a short system prompt, a few tools, a loop that ends when
  the model says it is done. No step, token or turn caps. Steering and follow-ups go between turns.
- Moonsplice runs its own Robot suites with tablua's Lua runner (`tablua/core/robot`), so a change to that parser
  changes how our docs and tests read.

## Claims

Claims are Robot tests in `.robot/claims/`. Each has `[Documentation]` naming the belief and its oracle, a kill
number written before measuring, a `level:` tag and a ` (red)` sibling that must fail at an assertion. Runs count
only when the claims file is committed and unchanged. The ledger (`.robot/ledger.sqlite`) is committed, and a
wrong run is marked invalid with a reason, never deleted. Write a claim when you are about to say "works",
"fixed" or "better" and something will be built on it; not for refactors a unit test already pins.

## Tests

- Unit tests sit beside their module as `name_test.lua`, using tablua's `test/spec.lua` (`test`, `eq`, `ok`,
  `same`, `err`, `run`). Run them with `luajit test/run.lua`.
- Rust tests: `cargo test` in `native/` and in `editor/src-tauri`. React: `npx vitest run` in `editor/`.
- Before a change is done: the unit tests, the goldens, and `luajit .robot/run.lua` pass.

## The port from Cadence

Moonsplice was Cadence (`~/cadence`, frozen at `56ddad1`). `.robot/port/` is how it came over:
`manifest.lua` places every Cadence file, `record.tsv` says where each went, `splits.lua` and
`splits_editor.lua` say how each file over 400 lines is cut, and `luajit .robot/run.lua port/done` lists what is
left. Until `port/done` passes, the 400-line law fails on the files with split plans; cut them one per commit,
goldens identical before and after. Python and the old Studio scripts stay parked in Cadence; anything needed
again is rewritten in Lua, or in Rust behind the engine.

## Conventions

- Keys and tokens are never logged, printed or written to files or rows.
- Commit messages say what changed and why in plain sentences, as the history does. Do not commit or push unless
  the owner asked.
- Other agent sessions may be working in this repository or in tablua at the same time. Check with them before
  editing a file they own, and tell them when something they depend on changes.
- Prefer measuring to arguing: a number in a row settles more than a paragraph.
