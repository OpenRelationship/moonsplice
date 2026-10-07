*** Settings ***
Documentation    The fact log — one grammar for what a comp is and what a clip shows (continued)

*** Test Cases ***
Confidence is derived, never self-reported
    [Documentation]    X1, and the reason `facts.agreed_runs` exists. Every model in the stack returns a score, and every
    ...    one of those scores is about the model, not about the clip: a confident misread of a blurred word
    ...    scores as high as a clean read. What reaches the log instead is *how much the interval's samples
    ...    agreed with each other*. A caption re-read differently every other frame, a head flickering between
    ...    facing left and facing the camera — both are states that were not read, and the number says so.
    ...
    ...    Two details in that function were found by getting them wrong. A single deviating sample between
    ...    two that agree is a misread, not a change, so it is smoothed into the run it interrupts. And a
    ...    group too short to claim as an interval is folded into its neighbour, not dropped — dropping it
    ...    reports a word misread once as read perfectly.
    ...
    ...    The seeder takes the same idea further: two vision models are asked to ground the same object
    ...    independently, and the IoU between their answers *is* the confidence. That number found an
    ...    out-of-focus camera that every detector missed.
    ...
    ...    Tracking used to be the hole in this. A track carried its *seed's* detector score, which is an
    ...    opinion about one frame — a lucky 0.95 on the frame the object was clearest travelled with a mask
    ...    that had slid off it two seconds later. It now carries how often an independent detection of the
    ...    same class agrees with the propagated mask, at times the tracker was never told about, with the
    ...    seed's own frame excluded because it agrees by construction. Where there are too few independent
    ...    looks to measure — the usual case for a VLM-grounded seed, since no detector found that class at
    ...    all — the cross-model agreement stands rather than being overwritten by a fabricated number.
    ...
    ...    The hand facts were the other hole, and a quieter one, because they sat directly beside compliant
    ...    code: `gripping`, `grasp` and `release` carried a flat 0.7 and 0.6 while the pose states three
    ...    lines above them were already scored by agreement. They now go through the same `agreed_runs`, and
    ...    a grasp inherits the confidence of the run it opens — a grip is only as well timed as the samples
    ...    that agreed the hand was closed.
    ...
    ...    Where the number is still a constant, it is on a deterministic measurement rather than a model's
    ...    self-assessment: ffprobe reading a container, RMS finding silence, ffmpeg's scene threshold, the
    ...    Laplacian focus check, the camera classifier's per-label reliability. Those constants say how much
    ...    the *method* is worth, which is a different claim from a model scoring itself. One genuine
    ...    exception remains: forced alignment passes through the aligner's own per-word score. Its evidence
    ...    is the measurement in the table above — 15 ms mean error — not that number.
    ...
    ...    *The one-frame criterion sits on top of the aligner's own resolution*
    ...
    ...    *G2: the zoom half, and two bugs it exposed*
    ...
    ...    The dolly half had been validated on the man clip; the zoom half had never been tested at all —
    ...    `grep zoom vision/tests/*.py` returned nothing, and no clip in the set contains one.
    ...
    ...    The first attempt was a comp: a true dolly (`cam_z` 4.0→2.4) against a true zoom (`fov` 0.90→0.564,
    ...    matched so the 2D magnification is the same), both through `s:world`. It does not work, and the
    ...    reason is worth keeping. DA3 gave focal spread 0.067 against 0.069 — no separation — with depth
    ...    *rising* in both, when a dolly-in must make it fall, and its focal *fell* on both (688→590, 661→541).
    ...    Its intrinsics do not read flat-shaded synthetic renders. For this one producer X4's "comps first"
    ...    is closed.
    ...
    ...    What does work is a zoom made of real pixels: crop progressively into a clip whose camera is static
    ...    and scale back to full frame. That is optically a true zoom — the field of view narrows, the camera
    ...    does not move, scene geometry is untouched — while every pixel remains photographic.
    ...
    ...    \ \ \ \ ffmpeg -t 6.4 -i woman_9032610.mp4 -vf \\
    ...    \ \ \ \ \ \ "zoompan=z='1+0.85*on/160':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1280x720:fps=25"
    ...
    ...    | case | DA3 focal ratio | `focal_rise` | verdict |
    ...    |---|---|---|---|
    ...    | zoom, crop 1.00 → 1.85 | 1.22 | +0.14 | `camera(zoom(in))` |
    ...    | still, same source unzoomed | 1.00 | +0.01 | `camera(still)` |
    ...    | dolly, man clip | 0.92 | −0.06 | `camera(dolly(in))` |
    ...    | still, cat clip | — | −0.01 | `camera(still)` |
    ...
    ...    Two bugs fell out. The rule tested `focal_spread`, a std/mean that **cannot tell a rise from a
    ...    fall**; the true zoom scored 0.053 against its own 0.08 bar and never fired, while `focal_slope` sat
    ...    computed and unused. It also required near-flat median depth, which is wrong in principle: zooming
    ...    in crops the frame to nearer content, so median depth falls (−0.028 here) even though nothing moved.
    ...    Depth cannot arbitrate a zoom. The decision is now the signed focal rise alone, and note DA3 reads
    ...    1.22 for a zoom that is 1.85 by construction — the magnitude is badly underestimated and only the
    ...    sign is trusted.
    ...
    ...    The second bug is G2's other clause. With `focal` unavailable, `zoom = bool(None and …)` is False and
    ...    control fell straight through to `dolly`, so the 2D estimator *was* emitting dolly on its own
    ...    whenever depth was off. A 2D scale change is now `unknown`. `camerafacts` had no test file at all,
    ...    which is how both survived; it has one now.
    ...
    ...    *X5 re-measured, and a hole in the harness*
    ...
    ...    Re-running it found a bug in the seeder, by way of a bug in the scorer.
    ...
    ...    The first re-run scored inset localization at mean IoU 0.214 with `frames IoU > 0.5` of **0.0** —
    ...    and temporal IoU **0.963**. That combination is the tell. The scorer takes the best-matching track,
    ...    and when the panel track was missing it fell back to a `person` that happened to span the same
    ...    seconds while sitting somewhere else in the frame. A high `tiou` beside a spatial IoU of 0.2 is not
    ...    a localization; it is a coincidence of interval. So `score_inset` now marks `matched: False` when
    ...    the best track never once reaches half-overlap, and `report` withholds the temporal figure and says
    ...    the inset was not matched. X2's rule — silence when the thing was not found — applies to the thing
    ...    doing the scoring, not only to the producers.
    ...
    ...    That refusal is what made the real fault visible instead of a plausible-looking 0.963. `ground()`
    ...    cached each model reply under `ground-{clip}-{i}-{model}`, where `i` is the target's **index in the
    ...    list**. The reply depends on the target and the timestamp, neither of which was in the key. So
    ...    grounding `["video panel inset"]` cached under index 0, and a later `ground(["cat", "video panel
    ...    inset"])` asked for `cat` at index 0 and was handed the inset's answer. Reproduced directly: asking
    ...    for both targets returned `cat` carrying the inset's box `[0.427, 0.197, 0.756, 0.567]`, while
    ...    asking for either alone was correct. The key now carries clip, time, target and model.
    ...
    ...    With the 30 stale entries cleared, the same call returns the inset at `[0.381, 0.589, 0.683, 0.889]`
    ...    — a different region entirely, so the old answer had been another object's box — and the eval reads:
    ...
    ...    | | before the fix | after |
    ...    |---|---|---|
    ...    | inset seed | `detector_agreement` "man with backpack" | `vlm_agreement` "video panel inset" at **0.98** |
    ...    | mean IoU | 0.292 | **0.947** |
    ...    | frames IoU > 0.5 | 0.0 | **0.981** |
    ...    | temporal IoU | 0.963, wrong object | **0.981** |
    ...    | cut localization | 2/2 inside 0 frames | 2/2 inside 0 frames |
    ...
    ...    Two things worth keeping. The seed confidence is now 0.98 where the run behind the originally
    ...    recorded 0.94 showed 0.60 — that run was being served a contaminated entry too, one that happened to
    ...    be close enough to work, which is why the number looked fine. And the first explanation offered for
    ...    the drop, that five clips and default prompts were not comparable with three and tailored ones, was
    ...    wrong: the matched three-clip re-run still scored 0.292. The cache was the cause both times.
    ...
    ...    Three tests cover this: a coincidental interval match is refused, a real match still prints every
    ...    metric, and two targets asked in different orders never share a cached reply.
    ...
    ...    *A renderer bug found while measuring G1 (fixed)*
    ...
    ...    Measuring G1 "on comps" as the criterion words it means rendering audio at a non-zero `at`. Doing
    ...    that for the first time turned up a real bug in `core/runtime/main.lua`: `s:audio { at = 0 }` mixed
    ...    correctly, while `at = 0.5` and `at = 1.2` produced a file with **no usable audio** — and the
    ...    renderer still printed `AUDIO mixed 1 clip(s)`. `comps/cases/audio.lua` uses `at = 0`, which is why
    ...    nothing caught it.
    ...
    ...    Bisecting the filter chain, the stream is correct until `amix` and collapses there:
    ...
    ...    | chain | duration |
    ...    |---|---|
    ...    | trim + setpts + volume | (blank) |
    ...    | + `adelay=1200` | 4.900 s |
    ...    | + `aformat` | 4.900 s |
    ...    | + `amix` | **0.005 s** |
    ...    | + `atrim` | 0.023 s |
    ...    | + `apad` (full chain) | 0.025 s |
    ...
    ...    No `amix` option helps — `duration=first`, `dropout_transition=0`, reordering `aformat` before
    ...    `adelay`, and `aresample=async=1:first_pts=0` on each input all still collapse. `amix` passes on the
    ...    timestamps of its delayed inputs and the encoder cannot use them. Appending **`asetpts=N/SR/TB`
    ...    after `amix`**, which regenerates the pts from the sample count, fixes it: two clips at 1.2 s and
    ...    3.0 s mix to exactly 5.000 s with sound starting at 1.206 and the second clip's pattern from 3.006.
    ...
    ...    The voice/duck bus has its own `amix` and needs no such fix — checked by removing it there, which
    ...    changes nothing, because `apad` follows that bus and its output feeds the main `amix`. Only the
    ...    mix that reaches the encoder is patched.
    ...
    ...    Three changes landed. The `asetpts`; a guard, since `apad=whole_dur` pads every mix to the comp
    ...    duration and so a short mix file can only mean the chain dropped audio — the renderer now probes the
    ...    mix and raises instead of muxing a silent track, this bug having only been able to hide because the
    ...    success line printed either way; and a second, delayed clip in `comps/cases/audio.lua`, which adds
    ...    no pixels (goldens compare identical) but means the suite now covers `at > 0` at all.
    ...
    ...    Adding that delayed clip immediately turned up a second, smaller thing. The props sampler reports
    ...    an audio node at *every* sampled time, not only while it sounds, so the lifter was emitting
    ...    `holds(volume(audio3, 0.35), 0.000, 3.000)` for a clip whose `holds(playing(audio3), 1.000, 2.500)`
    ...    covered half of that — two exact facts contradicting each other. Every audio clip in the suite
    ...    had previously started at 0 and run the full duration, which is the only reason the envelope and the
    ...    clip window had always coincided. The envelope is now clamped to the clip's own window. Lowering
    ...    does not read `volume`, so the byte-exact round trip is unaffected.
    ...
    ...    Unrelated, but found by the same golden run: `comps/cases/drop.lua` does not render at all —
    ...    `physics_bake.lua:59: Incorrect number of parameters` — and has no golden captured. It predates this
    ...    work and is untouched by it.
    ...
    ...    G1 asks for word times inside one frame, and what that costs is worth stating, because it is what
    ...    sent this in the right direction in the end. Forced alignment places a boundary on the emission
    ...    grid, and MMS_FA's stride is 20.1 ms at its 16 kHz input, so a frame at 30 fps is **1.66 emission
    ...    steps**. The criterion is asking for better than two steps of the model's native resolution.
    ...
    ...    Six words of seven delivered it and the seventh — "land" — sat 2.09 steps out, at +50 ms. Six
    ...    explanations were tested and all six failed: trim bias (the errors' signs are mixed), end of
    ...    utterance (+42 as the last word, +45 with a word after it), a slow onset ramp ("land" has the
    ...    *sharpest* onset of the seven, −45→−25 dB in 4 ms), sample-rate mismatch, grid quantisation, and
    ...    context (in isolation every other word sits at 21.0 ms and "land" at 43.0 ms).
    ...
    ...    What finally identified it was running four more acoustic models. wav2vec2 base, wav2vec2 large,
    ...    wav2vec2-lv60k and HuBERT-large put "land" at +50 ms too, three of them to the millisecond, and the
    ...    largest model was the *worst* overall. A bias that survives five independent models is not a bug in
    ...    any of them. It is the one thing they share: they are all CTC, and CTC emits late, with the peak for
    ...    a word-initial sonorant landing near the following vowel rather than at the consonant.
    ...
    ...    The ground truth was checked before the models were blamed, since five models agreeing is also what
    ...    a wrong truth looks like. Measuring the leading silence in each word's own wav put "land" at 2.2 ms,
    ...    in line with the rest — the truth was right.
    ...
    ...    So the fix is a second estimator that shares nothing with the first: short-time energy. Walk back
    ...    from the CTC boundary to where energy rises out of the preceding valley. Worst error over both
    ...    comps falls from 50.0 ms to 16.0 ms, 15/17 words inside a frame to **17/17**. The correction is
    ...    one-directional by construction, which is the useful check that it is modelling the real effect
    ...    rather than fitting noise: it only ever moves a word earlier, and it moves stop and fricative
    ...    onsets by 0–10 ms while moving sonorants by 20–50 ms.
    ...
    ...    Two things about the confidence, both X1. The old one was the mean CTC posterior — self-reported,
    ...    and worse than useless here, since it was above 0.9 on the words that were 50 ms late. The first
    ...    replacement graded the onset by how tightly varying the rise threshold pinned it down; that was
    ...    derived, but measurement showed it *anti*-correlated with error (mean 2.4 ms for the words it
    ...    scored low against 7.8 ms for the ones it scored high), so it was dropped rather than shipped.
    ...    What ships reports the two regimes the measurements actually support: an onset was found and is
    ...    unambiguous (17/17 inside a frame, Laplace-smoothed to 0.95), or none was, in which case the time
    ...    is the raw CTC boundary known to run up to 50 ms late and says so at 0.4. On the constructed comps
    ...    every word is refined; on real continuous speech 17 of 103 words fall back, which is the producer
    ...    declining to claim frame accuracy it does not have.
    ...
    ...    Four explanations were tested and discarded before calling it a model limit: the `say` fixture's
    ...    −45 dB trim biasing the truth (errors would share a sign, and they do not), an end-of-utterance
    ...    effect (the word scores +42 ms final and +45 ms with a word after it), a slow onset ramp (that word
    ...    has the *sharpest* onset of the seven, 4 ms to −25 dB, while the slowest at 25.9 ms errs by +1 ms),
    ...    and a sample-rate mismatch between the 22.05 kHz fixture and the 16 kHz model (`align` resamples
    ...    through ffmpeg, so there is none).
    ...
    ...    A finer grid was the obvious next move and it does not work. The emission stride is fixed in
    ...    samples, but it can be *offset* by padding the audio, so aligning on 2, 4 and 8 interleaved grids
    ...    and combining gives sub-step resolution from the same model. The mean improves a little — 15.3 ms
    ...    to 13.4 — and the word that fails does not move at all: +41.7, +41.3, +41.5, +41.4 ms across one,
    ...    two, four and eight grids. The model stably believes that boundary is there. **The error is not
    ...    quantisation.**
    ...
    ...    Aligning each word against its own file says the rest. Every word lands at exactly 21.0 ms, one
    ...    emission step, which is the lead-in the model takes when a file opens on speech with no silence
    ...    before it. Every word except one: "land" lands at 43.0 ms, two steps. It costs one step more than
    ...    its peers in isolation and in context alike, and the reason is in the word — a low-energy /l/ onset
    ...    the acoustic model does not commit to until the vowel arrives.
    ...
    ...    So closing it means a different acoustic model, not a finer grid and not a better-tuned version of
    ...    this one. That is a choice about dependencies, so it is written down here rather than made quietly.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

Silence is a valid output
    [Documentation]    X2. Where a producer cannot separate two explanations, it emits nothing, because a reader can act
    ...    on a missing fact and a confident wrong one propagates. Three places where this is load-bearing:
    ...
    ...    - **Defocus.** Monocular depth reads blur as distance. On the woman clip it put an out-of-focus
    ...    \ \ camera in the near foreground at 0.29 relief against a sharp subject at 0.81 — backwards, and
    ...    \ \ confidently. Sharpness vetoes the pair, and no ordering is claimed.
    ...    - **Camera motion.** Where the background is too sparse or too clustered to separate camera from
    ...    \ \ subject, `camera(unknown)` is the answer. A wrong camera fact is inherited by everything that
    ...    \ \ reads the log.
    ...    - **Caption boundaries.** A cross-fade reads as neither line, so the bisection returns the coarse
    ...    \ \ sample time rather than a precise wrong one.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

