*** Settings ***
Documentation    Friction log
...
...    Things that were burdensome, surprising or actively misleading while *using* Moonsplice to
...    build something real, rather than while building Moonsplice. Kept so the cost is visible
...    when deciding what to fix. Each entry says what happened, what it cost, and the smallest
...    fix that would have prevented it.
...
...    Source of the first batch: building `comps/lesson/how-moonsplice-works.lua` (2026-09-18), a
...    160 s narrated explainer — the first comp to use `s:tts`, and the largest comp by node
...    count (~270) written so far.
...
...    ---
Metadata    Source    cadence@56ddad1:docs/FRICTION.md

*** Test Cases ***
Silent failures
    [Documentation]    *1. A second `s:script` silently starts where the first one ended \ — CORRECTED, OPEN*
    ...    **My first diagnosis was wrong** and is recorded here because the wrong version is the more
    ...    tempting one. I wrote that only the first script is evaluated. In fact `init.lua:801` runs
    ...    every script — `for _, fn in ipairs(s.scripts) do fn(rec) end` — but they all share one
    ...    recorder, so the cursor carries over. A second script that opens with `t:wait(2.0)` starts at
    ...    2.0 s *after the first script's last beat*, not at 2.0 s.
    ...
    ...    The probe that misled me: two scripts, two rects, and the second rect was absent at t=2.6 s.
    ...    It was absent because it appeared at 2.9 s. Sampling one more frame would have shown it.
    ...
    ...    **Cost:** the lesson comp was restructured around a single timeline for a reason that turned
    ...    out not to exist. The structure is still right — one owner of absolute time is simpler — but
    ...    it was chosen from a false premise, and the comment explaining it was wrong in the source
    ...    until it was corrected.
    ...    **Fix:** nothing silent is happening, so this is documentation, not a bug. `s:script` should
    ...    say in its docstring that scripts concatenate, and lint should note it when a comp has more
    ...    than one, because "starts at the previous script's end" is not what the syntax suggests.
    ...
    ...    *2. A `captions` node displayed its final cue forever — FIXED*
    ...    Cues are intervals, so the natural reading is that the node shows nothing outside them. In
    ...    fact the last cue persists to the end of the comp. A `t = 5.81` readout from chapter 01 was
    ...    still on screen in chapter 05, fifty seconds later, overlapping unrelated content.
    ...
    ...    **Cost:** a full re-render, plus the frame-by-frame check that caught it.
    ...    **Cause:** `init.lua` recorded a timeline step at `cue.t0` and none at `cue.t1`, so `t1` had
    ...    no effect on rendering at all -- a cue held until the next step overwrote it. `C.apply_tail`
    ...    existed as a manual workaround, which is how the behaviour survived.
    ...    **Fixed:** a clearing step is recorded at `cue.t1` when a real gap follows (and after the last
    ...    cue). Contiguous cues are untouched, so all 42 golden cases are byte-identical. The hand-written
    ...    terminators are gone from both generators, and the edit that needed one now reports its true
    ...    blast radius -- 100 frames in two windows instead of 333 in one.
    ...
    ...    *3. A duplicate node name silently rebinds*
    ...    `header()` creates `<tag>_n`; the lift chapter also wanted `lf_n` for a note. The second
    ...    assignment won, so the same node landed in one animation list twice and got two overlapping
    ...    opacity tweens. The recorder caught the *overlap* — correctly — but reported it as
    ...    `overlapping tweens on text239.opacity (85.462-85.962 vs 85.762-86.262)`.
    ...
    ...    **Cost:** moderate. The error is real but points at the symptom, four indirections from the
    ...    duplicate name. A second collision (`lf_t`) was hiding behind the first.
    ...    **Fix:** in authoring code this is the author's problem, but see #6 — the message would have
    ...    been almost free to diagnose if node ids were traceable.
    ...
    ...    ---
    [Tags]    doc    source:cadence@56ddad1:docs/FRICTION.md
    Skip    prose

Messages that don't point at the cause
    [Documentation]    *4. Node ids in diagnostics can't be traced back to source*
    ...    Lint and the recorder report `[text44]`, `text239`, `[text104]`. These are auto-assigned
    ...    `kind .. count` ids. There is no map from them back to a constructor call, so locating the
    ...    offending node means counting constructors by hand — and the count is over *nodes*, not
    ...    constructors, which are not one-to-one (`s:captions{}` builds a `text`).
    ...
    ...    **Cost:** paid on every lint error, ~10 times in this build.
    ...    **Fix:** carry the source line into the node at construction (`debug.getinfo(2, "l")`) and
    ...    print `text239 (how-moonsplice-works.lua:412)`. `lower.py` already had to solve the reverse
    ...    mapping problem and documents how fragile it is.
    ...
    ...    *5. Resolve-phase subprocess errors are truncated to nothing*
    ...    A failing TTS call surfaced as `moonsplice resolve: TTS failed: (no output)` followed by a Python
    ...    traceback with the frames but not the exception message. The actual cause — a 400 with a
    ...    precise explanation — was only visible by re-running the subprocess by hand.
    ...
    ...    **Cost:** one wasted debugging cycle per resolve failure.
    ...    **Fix:** `verify_audio` already reads the artifact; also surface the subprocess's captured
    ...    stderr tail. The information existed and was discarded.
    ...
    ...    ---
    [Tags]    doc    source:cadence@56ddad1:docs/FRICTION.md
    Skip    prose

Limits you meet without warning
    [Documentation]    *6. Lua's 200-local ceiling is reachable by an ordinary comp*
    ...    ~250 nodes held in locals fails at load with
    ...    `function at line 24 has more than 200 local variables`. Nothing in the docs or the API
    ...    suggests a node budget, and the error names a Lua implementation limit rather than the thing
    ...    the author did.
    ...
    ...    **Cost:** a mechanical rewrite of every node reference to table fields.
    ...    **Fix:** document the pattern (`local N = {}`), or have `e.comp` catch this specific load
    ...    error and re-raise it with the remedy. A comp with 250 nodes is not exotic.
    ...
    ...    *7. There is no way to animate a text node's string*
    ...    Any value that changes over time — a counter, a readout, a label that updates — cannot be a
    ...    `text` node, because `text` is fixed at construction. The workarounds are N nodes with
    ...    staggered opacity, or a `captions` node abused as a scheduler. The second is much better and
    ...    is not written down anywhere.
    ...
    ...    **Cost:** low once known, but it was not discoverable; found by reading `captions.lua`.
    ...    **Fix:** document `captions` as the general "text that changes on a schedule" primitive, or
    ...    let `text.text` accept a signal.
    ...
    ...    ---
    [Tags]    doc    source:cadence@56ddad1:docs/FRICTION.md
    Skip    prose

Rules that fight the content
    [Documentation]    *8. `frozen_span` treated a narrated explainer as broken — FIXED*
    ...    Thresholds are 2 s (warn) and 3 s (error) of "visible but static", where static means summed
    ...    normalized motion below 0.002 per frame step. A diagram that is held still while a voice
    ...    explains it — the defining shape of an educational video — is an error at every chapter.
    ...    The measured bar is roughly 115 px/s of continuous movement somewhere on screen.
    ...
    ...    A 160 s progress rail crossing 1680 px (≈10 px/s) does **not** clear it. Satisfying the rule
    ...    required adding a decorative accent that scans back and forth under each chapter title for
    ...    the entire chapter, purely so the frame is never still.
    ...
    ...    It is worse than a style disagreement on footage. The sampler reads node *properties*, so a
    ...    `video` node playing real film is indistinguishable from a still image to it: a comp that was
    ...    nothing but a clip playing lint-errored with `visible but static (14.29 vs 2.00)`.
    ...
    ...    **Cost:** ~40 minutes, and a scanning accent added to every chapter purely to satisfy a rule.
    ...    **Fixed:** `frozen_span` now asks whether any content is moving on its own before calling a
    ...    frame static -- a `video`/`lottie`/`spritesheet`/`rive`/`particles` node inside its play window,
    ...    or any audio node inside its clip window. When it is, the span is reported as `info` ("no tweens
    ...    here, but a clip or narration is running") instead of an error. The real-footage comp went from
    ...    1 error to 0; the scanning accent is now kept because it reads well, not because it is required.
    ...
    ...    *9. `text_min_size` was an absolute pixel floor, unscaled by comp size — FIXED*
    ...    `text_min = 30` compares directly against `size`, with no reference to comp height. At
    ...    1920×1080 a 25 px monospace fact line is comfortably legible and still trips the rule — 42
    ...    findings in this comp. The shipped eval cases use `size = 22` labels at 1280×720 and would
    ...    trip it too.
    ...
    ...    **Fixed:** the floor is now `text_min * (comp.height / 1080)`, so it means the same thing at
    ...    any output size. It does not help a 1080p comp, where 30 px remains the bar -- that is a
    ...    threshold judgement, and the lesson comp acknowledges it explicitly via `lint_allow`.
    ...
    ...    *10. Suppressed lint findings vanished without a trace — FIXED*
    ...    The first version of this entry claimed there was no way to silence a rule. That was wrong:
    ...    `comp.lint_allow` and per-node `node.lint_allow` have both existed all along, and `allowed()`
    ...    in `lint.lua` honours them. I missed them and started building a duplicate mechanism.
    ...
    ...    The real defect was narrower and worth fixing: `allowed()` dropped findings **silently**, so a
    ...    comp with an allow list and a comp with no findings looked identical. An escape hatch that
    ...    leaves no trace is one nobody can audit.
    ...
    ...    **Fixed:** allowed findings are now counted and reported as one `suppressed` line per rule —
    ...    `43 x motion_density allowed by this comp`. On the lesson comp that took the output from 173
    ...    findings and 130 warnings to 5 findings and 1 warning, with every omission on the record.
    [Tags]    doc    source:cadence@56ddad1:docs/FRICTION.md
    Skip    prose

Integration gaps
    [Documentation]    *11. `tts_model()` returns an ElevenLabs id whatever the provider is*
    ...    `s:tts { provider = "openrouter" }` sent `eleven_multilingual_v2` to OpenRouter, which
    ...    answered `400: eleven_multilingual_v2 is not a valid model ID`. The default is
    ...    provider-specific but applied provider-agnostically.
    ...
    ...    **Cost:** the first end-to-end `s:tts` render failed; ~20 minutes to trace through
    ...    `verify_audio` (see #5, which hid the message).
    ...    **Fix:** move the default into each provider, as `tts_openrouter` now does defensively by
    ...    ignoring any model id without a `/`.
    ...
    ...    *12. `s:tts` had no users, no example and no test*
    ...    Nothing in `comps/` or `evals/` exercised it. The first real use hit #11 immediately. A node
    ...    kind that is wired through `resolve.lua`, cached, alignment-aware and documented in .robot/docs/canon.robot
    ...    §6 but never once called is indistinguishable from a broken one until someone tries.
    ...
    ...    **Fix:** one eval case with a local/offline provider.
    ...
    ...    *13. Narration-driven timing has no supported pattern*
    ...    TTS duration is not deterministic — the same text synthesised twice differs in length — while
    ...    comp duration is static by canon (.robot/docs/canon.robot §1.3). So a comp whose visuals follow its own
    ...    narration cannot resolve its own timing: the render needs a duration the synthesis hasn't
    ...    produced yet, and re-synthesising later silently desyncs the visuals.
    ...
    ...    The working pattern is to pre-synthesise, measure with `ffprobe`, and bake — which is what
    ...    `tools/make-lesson.py` does, and which makes `after = { ref, gap }` chaining and `at_word`
    ...    unusable for anything whose visuals must line up.
    ...
    ...    **Fix:** let the resolve phase write measured durations to a sibling `<comp>.timing.json`
    ...    that the comp may read, closing the loop without giving up static duration.
    ...
    ...    ---
    [Tags]    doc    source:cadence@56ddad1:docs/FRICTION.md
    Skip    prose

Found while building the agent surface (2026-09-18)
    [Documentation]    *14. Node ids must be discovered; they cannot be guessed — FIXED*
    ...    Editing needs the node id, and the obvious guess is wrong often enough to matter. A comp whose
    ...    first constructor is `s:audio` and whose second is `s:captions` has nodes `audio1` and
    ...    `text2` — the captions node is a *text* node, and the index counts nodes, not constructors of
    ...    that kind. Guessing `text1` fails with `no node 'text1'`.
    ...
    ...    **Cost:** one failed edit per unfamiliar comp; the recovery (`fact_log` and read `entity(...)`)
    ...    is cheap once you know to do it.
    ...    **Fixed:** every `no node` refusal in `lower.py` now lists what exists —
    ...    `no node 'text2' (have rect2, text3, video1)`. I guessed wrong twice in one session before
    ...    fixing it and have not guessed wrong since, because the error answers the question it raises.
    ...
    ...    *15. `props.lua` runs without the resolve phase, so resolve-derived fields are absent*
    ...    Every consumer of `props()` sees a comp in a state the renderer never renders: `duration` on an
    ...    audio node is filled in by resolve from the media, so at props time it is nil. The lifter's
    ...    fallback was the comp's duration, which made all eleven narration clips of a 160 s comp lift as
    ...    playing simultaneously for its entire length — eleven facts, all wrong, none of them flagged.
    ...
    ...    **Cost:** silently wrong facts, found only by reading a lifted log line by line.
    ...    **Fix (applied):** probe the media for its real length. **Fix not applied:** props should say
    ...    which fields are pre-resolve, or offer a resolved mode, because any future consumer will hit
    ...    the same gap with `at`, `after` and `align_at` chains.
    ...
    ...    *16. `lift()` does not scale to a long comp*
    ...    Lifting samples the comp at its frame rate, so a 160 s comp at 30 fps is 4 814 evaluations in
    ...    one `luajit` call behind a 120 s subprocess timeout. It completed in about five minutes and
    ...    produced 8 816 facts, which is not a log any agent will read.
    ...
    ...    **Fix:** `sample_fps` already exists as the mitigation but nothing suggests it; `lift` should
    ...    pick a sane default for long comps, and the log wants a summary mode.
    ...
    ...    *17. There is no speech asset in the repo*
    ...    `comps/assets/` has exactly one audio file, `piano.ogg`, at 176 s — longer than any test comp,
    ...    so it can only ever exercise the clamp-to-comp-duration branch and never the media-length one.
    ...    Nothing could test the transcript path without either stubbing the aligner or generating a tone
    ...    in the test.
    ...
    ...    **Fix:** commit two or three seconds of speech and a two-second tone as fixtures. Worked
    ...    around for now: the tests stub the aligner, and generate a tone with ffmpeg in a fixture.
    ...
    ...    *18. A three-digit hex colour was rejected — FIXED*
    ...    `background = "#000"` failed in `color.parse` with a traceback from `init.lua`, naming neither
    ...    the colour nor the node. Every other tool in the ecosystem accepts the short form; it cost a
    ...    round of confused test debugging.
    ...
    ...    **Fixed:** `#rgb` and `#rgba` now expand by doubling each digit, the same rule CSS uses. No
    ...    shipped case used the short form, so all 42 goldens are unchanged.
    ...
    ...    *19. `moonsplice golden capture` never captured — FIXED*
    ...    The documented workflow for any renderer change is "capture goldens before, compare after,
    ...    recapture deliberately" (.robot/docs/agents.robot). The first step did not work. `moonsplice golden` assigns
    ...    `mode="\${1:-compare}"` for the subcommand and then, eleven lines later, reuses the same name for
    ...    the scene flag: `mode="\${MOONSPLICE_SCENE:-1}"`. After that `[ "$mode" = capture ]` can never be
    ...    true, so `moonsplice golden capture` silently ran a *comparison* and reported `identical` — which reads
    ...    exactly like success.
    ...
    ...    **Cost:** nearly invisible. Capture appears to work, prints per-case lines, and exits 0. Any
    ...    "recapture deliberately" step in this repo's history was a no-op, and a deliberate golden update
    ...    would have had to be made by hand without anyone noticing why.
    ...    **Fixed:** the scene flag is now its own variable. `moonsplice golden capture` writes files again.
    ...
    ...    *20. The fact parser split on commas inside quoted strings — FIXED*
    ...    `facts.parse_term` walked the argument list tracking bracket depth but **not quotes**, so any
    ...    fact carrying prose came apart:
    ...
    ...    ```
    ...    says(a1, "one, two and three") \ \ -> \ ('says', 'a1', '"one', 'two and three"') \ \ \ \ # arity 4, not 3
    ...    ```
    ...
    ...    A fact with the wrong arity matches no pattern, so it silently vanished from every query. On the
    ...    lesson comp this hid 10 of 11 `says()` facts and 35 of 414 word facts. It is the most dangerous
    ...    shape of bug in this layer: the log on disk was correct and complete the whole time, and only
    ...    the reading of it was wrong — so the log looked right when inspected by eye, and wrong only when
    ...    queried.
    ...
    ...    **What made it expensive:** the missing words were not missing at random. Words ending in a
    ...    comma were exactly the ones dropped, which reads as a plausible acoustic failure. I measured
    ...    "the aligner drops 8.5% of words", wrote it down as an accuracy limit of the transcript feature,
    ...    and was about to report it. The aligner was in fact perfect — 414 of 414. A measurement that
    ...    confirms a plausible story is the hardest kind to doubt.
    ...
    ...    **Fixed:** both `parse_term` and the pattern parser it was copied into are quote-aware, with
    ...    escaped quotes handled. After the fix: 11 of 11 `says()`, 414 of 414 words, nothing dropped.
    ...    Regression tests cover prose, trailing commas, colons and escaped quotes.
    ...
    ...    *21. `fact_when(event=…)` missed every two-party event — FIXED*
    ...
    ...    `Log.when(event=)` matched `happens(E(_), T)` and `happens(E, T)`, so it saw one-argument and
    ...    bare events and nothing else. `happens(release(e1, e2), 8.5)` — the contact events, which are
    ...    most of the interesting ones — returned `[]`. Found because video 2 showed the call on screen
    ...    and the call it showed would have come back empty. **Fixed:** `when` matches on the event's
    ...    head, any arity. Regression test in `test_query.py`.
    ...
    ...    *22. A clip query with no prompts re-perceived the clip and crashed — FIXED*
    ...
    ...    `fact_when`/`fact_at`/`fact_query` on a video call `fact_log(source)` with no prompts. The cache
    ...    key included prompts and the words/beats flags, so it never matched the run that had prompts,
    ...    and SAM 2 then ran with zero prompts and died with `cannot reshape tensor of 0 elements`.
    ...    **Fixed:** words/beats no longer change a video's key (perception always runs its audio
    ...    producers); a prompt-less call reads the clip's latest perceived log; with none it returns
    ...    `"not perceived yet; call fact_log with prompts"` instead of perceiving nothing.
    ...
    ...    *23. `anchor` accepts any string and honours one — FIXED (lint)*
    ...
    ...    Only `"topleft"` (the default) and `"center"` exist. `"topright"` and friends are silently top-left, which reads as
    ...    a layout bug somewhere else (video 2's `10s` row label ran under the grid). **Fixed in lint:**
    ...    `unknown_anchor` warning naming the value. Right/bottom alignment still means offsetting x/y
    ...    by hand, using a width estimate for text.
    [Tags]    doc    source:cadence@56ddad1:docs/FRICTION.md
    Skip    prose

Small
    [Documentation]    - `moonsplice golden` and friends assume GNU `timeout`, absent on stock macOS.
    ...    - `grep --include=*.lua` unquoted is a zsh glob error; the repo's own docs use it unquoted.
    ...    - `moonsplice` has no `frame`/`still` subcommand, so single-frame extraction means rendering
    ...    \ \ an mp4 and seeking with ffmpeg, or going through the vision MCP.
    [Tags]    doc    source:cadence@56ddad1:docs/FRICTION.md
    Skip    prose

