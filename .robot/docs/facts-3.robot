*** Settings ***
Documentation    The fact log — one grammar for what a comp is and what a clip shows (continued)

*** Test Cases ***
Known gaps
    [Documentation]    - **Gait.** The man clip is a man walking while the camera dollies after him. He sits near the
    ...    \ \ centre of the dolly's expansion, so he is still in the frame and still in the compensated world,
    ...    \ \ and the walk leaves no trace in either. A `followed_by_camera` fluent was tried and fired on the
    ...    \ \ three parked cars rather than on him — a static object at that spot is genuinely indistinguishable
    ...    \ \ from a followed one by box centroid alone. The signal is in the body, not the box.
    ...    - **Hands.** The `mediapipe` package aborts the process on this macOS build
    ...    \ \ (`DrishtiMetalHelper … Service is unavailable`, from a Metal-backed calculator inside the detector
    ...    \ \ subgraph, unavoidable via the CPU delegate or `MEDIAPIPE_DISABLE_GPU`). That is a property of the
    ...    \ \ runtime, not of the models: the same palm detector and 21-point landmarker exported to ONNX run
    ...    \ \ under OpenCV's DNN backend with no Metal involved, and they work here. `vendor/` carries the two
    ...    \ \ OpenCV Zoo wrappers, pinned, with the palm detector's 2000-line anchor table replaced by the six
    ...    \ \ lines that generate it (identical to 7.5e-09 — 24x24 cells with 2 anchors each, then 12x12 with
    ...    \ \ 6, every anchor at its cell's centre).
    ...
    ...    \ \ RTMPose was tried first, since the goal names it as the alternative, and it is the wrong shape of
    ...    \ \ model for this. RTMW is top-down: a person detector proposes a box and the pose head fills in 133
    ...    \ \ keypoints. The handoff clip has no person in it — two gloved forearms reach into a lit rectangle
    ...    \ \ and nothing else is in frame — so YOLOX has nothing to find, and the keypoints land on the *bottle*
    ...    \ \ and its shadow rather than on either hand. A body model needs a body.
    ...
    ...    \ \ The gesture half of G5 is `palm(e, camera)` beside the existing `hand_state(e, open)`, kept as two
    ...    \ \ fluents rather than one fused "open palm toward lens". Orientation and finger curl are independent
    ...    \ \ things a shot can show, and an editor looking for a presented palm and one looking for a relaxed
    ...    \ \ open hand are asking different questions. The reading is the winding of the two knuckle vectors
    ...    \ \ leaving the wrist, which reverses between a palm and the back of the same hand and reverses again
    ...    \ \ with handedness, so it is measured on constructed hands — no clip here presents a palm to the
    ...    \ \ lens, and saying so is better than scoring it on footage that cannot answer.
    ...
    ...    \ \ What remains unsolved is the handoff clip itself, and now for a stated reason rather than a
    ...    \ \ missing library. The palm detector is confident on a bare hand (0.91 and 0.99 on the woman clip,
    ...    \ \ landmarks correctly on the hand) and returns **nothing at all** on the handoff clip down to a
    ...    \ \ score threshold of 0.3 — two rubber gloves, backlit, against a blown-out white rectangle, which
    ...    \ \ is not what a detector trained on skin knows. So handoff timing still comes from mask contact.
    ...
    ...    The truth side of that comparison now exists. Stepping the clip a frame at a time at 25 fps: the
    ...    \ \ white glove's fingertip is against the bottle through 8.24 s, marginal at 8.28, and a clear gap
    ...    \ \ has opened by 8.32. **Hand-eye truth for the release is 8.30 s ± 0.02.**
    ...
    ...    \ \ The other side does not. An earlier run of this clip produced `happens(handoff(e1, from(e2),
    ...    \ \ to(e3)), 8.000)`, and re-running it does not: the seeder returns *one* gloved hand, and the
    ...    \ \ handoff rule needs two, since it fires on one hand's touch interval ending as another's begins.
    ...    \ \ Three separate things block the second hand, and it is worth naming all three, because fixing any
    ...    \ \ one of them alone changes nothing:
    ...
    ...    \ \ 1. **The detector never sees the second hand at all.** 41 `gloved hand` detections over 37 sampled
    ...    \ \ \ \ \ frames, top confidence 0.32. Eight frames carry two boxes at once, which looks promising until
    ...    \ \ \ \ \ you read them: their centres sit at x ≈ 0.67–0.83 with IoU up to 0.62 and confidences of
    ...    \ \ \ \ \ 0.10–0.23. Those are duplicate boxes on the *white* glove. The green glove, over at x ≈ 0.3,
    ...    \ \ \ \ \ is never detected once. So this is not a `_covered` threshold merging two hands — there is no
    ...    \ \ \ \ \ second hand to merge. Rubber gloves in silhouette are not what it was trained on, the same
    ...    \ \ \ \ \ thing that blinds the palm detector.
    ...    \ \ 2. **The seeding loop** only asked the vision models for classes it had *none* of, so a class that
    ...    \ \ \ \ \ wanted two and had one was never topped up. That one is now fixed: grounding is asked for the
    ...    \ \ \ \ \ shortfall. It made the run say `{'gloved hand': 1} still wanted` where before it said nothing.
    ...    \ \ 3. **`ground` returns at most one box per target string**, and deliberately — asking a model for a
    ...    \ \ \ \ \ list makes the reply *order* model-dependent, and pairing by index silently swaps two objects'
    ...    \ \ \ \ \ boxes. So no amount of asking yields a *second* instance of one class. A second would need a
    ...    \ \ \ \ \ distinct target string, "the green glove" against "the white glove", and then its class is no
    ...    \ \ \ \ \ longer `gloved hand` and the handoff rule stops recognising it as a hand at all.
    ...
    ...    \ \ And underneath all three, the confidence mechanism itself declines: asked to ground `gloved hand`
    ...    \ \ on the midpoint frame, qwen returns a box and gemini returns nothing usable, so the cross-model
    ...    \ \ agreement that *is* the seed's confidence cannot form. That is X1 behaving correctly, not failing.
    ...
    ...    \ \ With the landmark routes closed, three model-free estimators were tried, on the reasoning that the
    ...    \ \ release is visible even if the hand is not: the white glove lets go and withdraws right while the
    ...    \ \ green glove keeps the bottle. Hand-eye truth is 8.30 s and two frames at this clip's 25 fps is
    ...    \ \ 0.08 s, so the target is [8.22, 8.38].
    ...
    ...    \ \ | estimator | what it gives | error |
    ...    \ \ |---|---|---|
    ...    \ \ | box separation (glove x0 − bottle x1) | largest jump at 8.52–8.62 | 0.22–0.32 s |
    ...    \ \ | mask contact area, 10 fps | 422 → 380 px, smooth, no break at all | no event |
    ...    \ \ | ROI frame-change at 25 fps, contact region | peak 8.48, rise onset ≈ 8.17 | 0.18 s / 0.13 s |
    ...
    ...    \ \ None is inside two frames, and the reasons are instructive rather than incidental. The boxes are
    ...    \ \ dominated by the forearm, which keeps moving through the release. The masks are 84×160 against a
    ...    \ \ 960×506 frame, so the fingers are a handful of cells. And frame-change peaks where motion is
    ...    \ \ *fastest*, which is after the hand has let go, not at the moment it does — the release is the
    ...    \ \ onset of a divergence, and onset estimation on a broad hump is worth about 0.13 s here.
    ...
    ...    \ \ **The reference itself was wrong.** Three estimators clustering near 8.5 against a stated truth of
    ...    \ \ 8.30 is the same shape as G1's "land", and there the right response was to re-check the truth. At
    ...    \ \ 6× zoom on the fingertip/bottle junction, stepping 0.04 s at a time: the bottle's base rests on the
    ...    \ \ glove through **8.40**, and at **8.44** a bright wedge of the background panel appears between
    ...    \ \ them. That is an objective marker rather than a judgement, so the reference is 8.42 ± 0.02 and the
    ...    \ \ recorded 8.30 was three frames early. The revision was made after the estimators had been run,
    ...    \ \ which is the direction that should make anyone suspicious — so note that it does not rescue the
    ...    \ \ goal. The best estimator lands at 8.56; had the truth been fitted to it, it would have been put
    ...    \ \ there, not at 8.42.
    ...
    ...    \ \ **The estimator question is now settled, on exact truth.** G5's producer had never had the X4
    ...    \ \ treatment — measured on a comp before being trusted on footage — so `scratchpad/g5/release.lua`
    ...    \ \ builds one: a carrier tracks a drifting object's underside exactly until T = 2.40 and then falls
    ...    \ \ away, making the contact break exact by construction.
    ...
    ...    \ \ | estimator | on the comp (truth 2.400) | error |
    ...    \ \ |---|---|---|
    ...    \ \ | contact-gap onset | 2.44 | **1.0 frame** |
    ...    \ \ | ROI frame-change peak | 2.88 | 12.0 frames |
    ...
    ...    \ \ So the definition that matters is the gap opening, not the change peaking — frame-change peaks
    ...    \ \ where motion is *fastest*, which is well after the release, and its 0.18 s error on footage was
    ...    \ \ not bad luck but the wrong question. Carried to the clip, the comp-validated estimator gives 8.56
    ...    \ \ against the corrected 8.42: **3.5 frames, still outside the criterion**. The reason is resolution
    ...    \ \ at the junction, not the rule — the real gap at 8.44 is one or two pixels across a soft,
    ...    \ \ motion-blurred, low-contrast boundary, and colour segmentation does not register it until it is
    ...    \ \ about four pixels wide at 8.56. On the comp the same rule sees 60 px rectangles and is exact.
    ...
    ...    \ \ **And it is triggered by what the log already carries.** `sweep` takes a pair's `touching`
    ...    \ \ interval and walks it in 1.4 s windows, taking each window's boxes from the tracks so the crop
    ...    \ \ stays tight while following the pair. Handed the handoff clip's own
    ...    \ \ `holds(touching(e1, e2), 2.100, 10.700)` — the full span, nothing pre-selected — it returns
    ...    \ \ **8.50 at confidence 1.00, 2.0 frames** from the reference, in 887 s. The eight windows before the
    ...    \ \ real one all returned None, so the onset guard produced no false positives along the way.
    ...
    ...    \ \ Four cheaper triggers were tried first and none of them contains the event:
    ...
    ...    \ \ | coarse signal | on the comp (truth 2.400) | on the handoff (ref 8.42) |
    ...    \ \ |---|---|---|
    ...    \ \ | frame-change peak, fixed ROI | 2.88 over a tight interval; **0.48** over the whole clip | 8.48 tight; **9.70** over the whole interval |
    ...    \ \ | box separation | — | gradual, largest jump 8.52–8.62 |
    ...    \ \ | centroid distance | — | smooth 130 → 316, **no break at all** |
    ...    \ \ | mask contact area at 10 fps | — | 422 → 380 px, no event |
    ...
    ...    \ \ The last two fail for the same reason and it is worth stating: the bottle and the glove were
    ...    \ \ *already drifting apart* before the grip opened, so any measure of how far apart they are rises
    ...    \ \ straight through the release without a step in it. Only the gap between their surfaces has a step,
    ...    \ \ and only at native resolution. A fixed-ROI frame-change peak fails differently — over a long
    ...    \ \ interval its region no longer contains the objects at all, which is how it lands on 9.70.
    ...
    ...    \ \ `perceive` now takes `want_contact`, off by default because one pair over eight seconds is about
    ...    \ \ fifteen minutes. The fact is `happens(release(a, b), t)` with `contact_gap` as its producer.
    ...
    ...    \ \ **This is now a producer, `contact.py`, not a prototype.** The window is derived from the two
    ...    \ \ entities' boxes at the contact moment, prompts are clamped into it, and the pure parts — window,
    ...    \ \ clamp, gap, onset — are unit-tested. End to end through `break_time`:
    ...
    ...    \ \ | material | truth | measured | error |
    ...    \ \ |---|---|---|---|
    ...    \ \ | release comp, exact by construction | 2.400 | 2.44, conf 0.67 | **1.0 frame** |
    ...    \ \ | handoff clip | 8.42 | 8.50, conf 1.00 | **2.0 frames** |
    ...
    ...    \ \ Three bugs surfaced in the wiring, all of which had been masked by the hand-picked window. Scaling
    ...    \ \ the crop can land on an odd pixel height, which h264 refuses — the encode aborts, the segment is
    ...    \ \ unreadable, and that arrives as silence, a plain bug wearing the costume of an honest "cannot
    ...    \ \ tell". Widening the window to cover where the entities *travel* is worse than sizing it at the
    ...    \ \ contact, because SAM runs at a fixed `imgsz` and a bigger crop spends fewer of those pixels on the
    ...    \ \ junction: the handoff moved from 2 frames out to 4. And requiring the gap thresholds to agree
    ...    \ \ *exactly* is wrong when a separation opens at a few pixels a frame — a 1 px and a 4 px threshold
    ...    \ \ are legitimately a frame or two apart, so they are required to agree closely, the earliest wins,
    ...    \ \ and the spread becomes the confidence.
    ...
    ...    \ \ **Masks at native resolution close the gap.** The tracker downsamples to `MASK_W = 160` purely for
    ...    \ \ storage, while `_propagate` has SAM's masks at full size first. Re-running SAM2 on a 2×-upscaled
    ...    \ \ crop around the contact at 25 fps, keeping the masks un-downsampled (660×1120 instead of 84×160),
    ...    \ \ and applying the same gap-onset rule: the minimum gap is **1.0 px on every frame from 7.90 to
    ...    \ \ 8.46**, then 41 → 58 → 79 → 100 px. The break is at **8.50**, and the threshold is irrelevant
    ...    \ \ because the jump is 1 px to 41 px — anything between 2 and 40 gives the same answer.
    ...
    ...    \ \ The first attempt gave nonsense (4, 7, 8, 9, 11 px, then frames with no glove under the bottle at
    ...    \ \ all) because both box prompts fell outside the crop: the glove's box reached x=1395 in a 1110-wide
    ...    \ \ window and both had negative y. SAM2 was being handed malformed prompts. Sizing the window to hold
    ...    \ \ both boxes across the whole interval, and clamping, fixed it.
    ...
    ...    \ \ **What that does and does not settle.** Against the re-derived reference of 8.42 the error is
    ...    \ \ 0.08 s — 2.0 frames, meeting the criterion at exactly its boundary. Against the originally recorded
    ...    \ \ 8.30 it is 5 frames and fails. The pass therefore depends entirely on the revision, and the revision
    ...    \ \ was made after estimators had been run. Three things weigh against that being motivated reasoning:
    ...
    ...    \ \ * it rests on a frame-by-frame observation anyone can repeat — contact at 8.40, a bright wedge of
    ...    \ \ \ \ background between bottle and glove at 8.44 — not on any estimator's output;
    ...    \ \ * when it was made it did *not* rescue the goal, the best estimator then standing at 8.56;
    ...    \ \ * the estimator is independently validated at 1.0 frame against exact comp truth, so 8.50 implies a
    ...    \ \ \ \ true break in 8.46–8.54, which agrees with the 8.44 read off the pixels.
    ...
    ...    \ \ The honest reading is that the recorded 8.30 was about four frames early and the real break is near
    ...    \ \ 8.45. But a criterion measured against a reference revised in the same session is not cleanly met,
    ...    \ \ and it wants confirming on a second clip whose truth is fixed before any estimator runs. The
    ...    \ \ producer is prototyped and validated but **not wired into `perceive`**: the window is still chosen
    ...    \ \ by hand, and generalising it means deriving it from the two tracks' union.
    ...
    ...    \ \ **The gesture clause, actually in a log.** It had been claimed on the strength of `palm_facing()`
    ...    \ \ returning the right value for constructed landmark geometry — a function's return, not a fact. No
    ...    \ \ log anywhere carried a gesture fact, because `landmarks.emit` gates hand processing on an entity
    ...    \ \ whose class contains "hand" and none of the clips had ever been prompted for one. Prompting the
    ...    \ \ woman clip with `hand` gives:
    ...
    ...    \ \ \ \ \ \ entity(e2, "hand", seed(0.720)).
    ...    \ \ \ \ \ \ holds(hand_state(e2, open), 0.500, 3.700). \ \ src ... mediapipe_hands, 0.70
    ...    \ \ \ \ \ \ holds(hand_state(e2, open), 3.700, 6.480). \ \ src ... mediapipe_hands, 0.86
    ...    \ \ \ \ \ \ holds(palm(e2, away), \ \ \ \ \ \ 0.500, 1.300). \ \ src ... mediapipe_hands, 0.67
    ...    \ \ \ \ \ \ holds(palm(e2, camera), \ \ \ \ 1.500, 6.480). \ \ src ... mediapipe_hands, 0.86
    ...
    ...    \ \ `palm(e2, camera)` holding over `hand_state(e2, open)` is the criterion's "open palm toward lens".
    ...    \ \ The hand is found on 12 of 16 sampled frames; the landmarks were drawn and checked against the
    ...    \ \ picture before any of this was believed, because a confident detection has already been wrong once
    ...    \ \ here. Worth recording that the check itself was wrong first: converting the frame RGB→BGR before
    ...    \ \ calling `hands()` makes the detector find nothing, and the first annotated image showed no
    ...    \ \ detections at all. `frame_at` returns RGB and that is what `emit` passes, so the pipeline was right
    ...    \ \ and the verification was not.
    ...
    ...    \ \ And a provenance bug it exposed: `_emit_runs` stamped every fluent `yolo_pose`, including `palm`
    ...    \ \ and `hand_state`, which come from the hand landmarker — a different model that fails in different
    ...    \ \ places, declining gloves outright where the pose model copes. Half the facts named the wrong
    ...    \ \ producer. Provenance a reader cannot trust is worse than none, so the producer is now per-fluent. Note too that `rule_handoff` in `perceive.py` cannot fire here
    ...    \ \ whatever the timing — it needs two hand entities and only one glove is ever detected, which is a
    ...    \ \ grammar question about naming two instances of one class, not a perception one. Naming two instances of one class is a grammar question, and
    ...    \ \ it is the next thing to decide rather than something to patch around.
    ...
    ...    \ \ One thing to revisit when it can be measured. The rule reads
    ...
    ...    \ \ \ \ \ \ happens(handoff(obj, from(ha), to(hb)), max(b0, a1 - 0.5))
    ...
    ...    \ \ and that `- 0.5` back-dates the event half a second on no evidence at all. It is the first thing
    ...    \ \ to suspect against an 8.30 truth — but suspecting is not measuring, and it stays a suspicion here
    ...    \ \ rather than becoming a finding. Note where it lives, though: in a rule, not a model, which is what
    ...    \ \ X3 predicts of fixes.
    ...    - **Costume change, and what it actually measures.** G7 asks that identity survive a costume or
    ...    \ \ angle change. The angle half is measured on the three-shot assembly. For the costume half there
    ...    \ \ is no footage here in which anyone changes clothes, so it was constructed: the man's second shot
    ...    \ \ was hue-rotated by 60°, 120° and 180° before assembly, which moves his jacket navy → purple →
    ...    \ \ maroon → olive. That is a *harder* perturbation than a costume change, because it moves the
    ...    \ \ street, the leaves and the parked cars with him rather than only what he is wearing.
    ...
    ...    \ \ The appearance signal barely notices. Cosine between his shot-1 and shot-3 crops:
    ...
    ...    \ \ | hue rotation | 0° | 60° | 120° | 180° |
    ...    \ \ |---|---|---|---|---|
    ...    \ \ | cos(shot 1, shot 3) | 0.915 | 0.881 | 0.873 | 0.882 |
    ...
    ...    \ \ against 0.764 for a known-different pair in the same clip — percentile 1.00 at every rotation, and
    ...    \ \ a worst case 0.109 above the baseline. CLIP appearance is reading shape and structure far more
    ...    \ \ than colour, which is the property this goal was asking after.
    ...
    ...    \ \ The *fact*, though, did not fire in that first assembly, and for a reason worth keeping: with the
    ...    \ \ man, the cat and one spurious man track there was exactly **one** known-different pair, and
    ...    \ \ `MIN_NULL = 6` refuses to calibrate a percentile against a single number. Identity was abstaining
    ...    \ \ for want of a null, not for want of evidence — X2 doing its job, and a reminder that a sparse
    ...    \ \ scene silences this producer no matter how obvious the match looks.
    ...
    ...    \ \ Given a scene with enough in it to calibrate against — the man, a tree and three parked cars, so
    ...    \ \ 7 known-different pairs — it fires:
    ...
    ...    \ \ \ \ \ \ holds(same_as(e3, e1), 6.100, 8.900).
    ...    \ \ \ \ \ \ src(holds(same_as(e3, e1), 6.100, 8.900), clip_appearance, 0.86).
    ...
    ...    \ \ where `e1` is the man in shot 1 and `e3` is the same man in shot 3 under the 120° rotation. A
    ...    \ \ parked car rejoins across the same cut at 0.71. So both halves of G7 are measured: the angle
    ...    \ \ change on the unaltered three-shot assembly at 1.00, and the colour change here at 0.86.
    ...    - **A teardown flake that can fail the build.** About one full-suite run in five ends, *after* all
    ...    \ \ 294 tests have passed and reported, with `libc++abi: terminating due to uncaught exception of type
    ...    \ \ std::__1::system_error: recursive_mutex lock failed`, and that aborts the interpreter with exit
    ...    \ \ 134. No single test module reproduces it in three runs each — it needs the whole set of native
    ...    \ \ libraries resident together (torch, cv2, onnxruntime, av, ultralytics), and OpenCV already warns
    ...    \ \ on import that `av` and `cv2` ship duplicate `libavdevice` builds. So a red CI run here is worth
    ...    \ \ reading before believing: "294 passed" followed by exit 134 is this, not a failure. It is left
    ...    \ \ diagnosed rather than fixed, because guessing at C++ static-destructor ordering across five
    ...    \ \ vendored native libraries is how you get a flake that moves instead of one that goes away.
    ...    - **Hallucinated bodies.** A frame holding only a gloved hand and its shadow produced a confident
    ...    \ \ seated person with 13 of 17 keypoints above 0.5, where the real man walking away had 4. Keypoint
    ...    \ \ counts measure plausibility, not presence. What keeps it out of the log is that pose facts attach
    ...    \ \ only to entities the tracker already found.
    ...    - **Cuts and propagation.** SAM 2 does not know what a cut is. Given a whole clip it drags a mask
    ...    \ \ straight through one and reports a three-shot assembly as a single track of nonsense. Propagation
    ...    \ \ is therefore bounded by the shot, and each boundary is then re-examined: the track is carried one
    ...    \ \ shot further only if the content inside its box ignored the cut.
    ...
    ...    \ \ The first version of that re-examination asked whether the *mask* survived the crossing unchanged
    ...    \ \ in place and size, on the premise that an overlay sits still while the plate changes under it.
    ...    \ \ That premise is wrong for the thing the clip eval actually contains — a picture-in-picture tweened
    ...    \ \ across the frame while it plays — and the measurement said so plainly. Replaying the inset's two
    ...    \ \ crossings and four in-shot ones through every test available, none separated the accepts from the
    ...    \ \ rejects:
    ...
    ...    \ \ | test | accepts (inset, both directions) | rejects (content in a shot, n=4) |
    ...    \ \ |---|---|---|
    ...    \ \ | mask IoU | 0.41, 0.59 | 0.24 – 0.63 |
    ...    \ \ | box IoU | 0.91, 0.92 | 0.74 – 0.92 |
    ...    \ \ | mask area ratio | x0.48, x0.65 | x0.29 – x1.05 |
    ...    \ \ | crop histogram | one pass, one fail | two pass, two fail |
    ...
    ...    \ \ Every column overlaps, so any threshold over them would have been fitted noise, and the histogram
    ...    \ \ test was deleted rather than tuned. What separates the cases is what a picture-in-picture
    ...    \ \ physically is: a rectangle of foreign footage. At a cut the plate changes completely and the panel
    ...    \ \ does not, so the pixels inside the box change far less than the pixels outside it — **0.59x for
    ...    \ \ both directions of the inset against 0.98x–1.18x for content belonging to the shot**. It is a
    ...    \ \ ratio against the same frame's own change, not an absolute, because how much a cut changes depends
    ...    \ \ on the two shots. It declines to answer in two situations rather than guess: a box covering most
    ...    \ \ of the frame leaves only a border to compare against, and a boundary where the frame barely
    ...    \ \ changes is not a cut this can measure.
    ...
    ...    \ \ The one crossing that scored like an overlay without being labelled one is worth keeping in view:
    ...    \ \ a box at `[0.307, 0.694, 0.460, 0.889]`, lying wholly inside the panel's `[0.208, 0.588, 0.509,
    ...    \ \ 0.887]` — a man detected *in* the picture-in-picture, because the panel is playing the man clip.
    ...    \ \ That region does ignore the cut, and carrying it across is right. The test was correct there too;
    ...    \ \ only the name `man with backpack` is ambiguous about which layer it means.
    ...
    ...    \ \ Content that stops at its cut is what makes cross-shot identity a question worth asking — the
    ...    \ \ pieces have to exist separately before anything can rejoin them with a calibrated score.
    ...    - **Diarization.** pyannote's models are gated: `pyannote/segmentation-3.0` and
    ...    \ \ `pyannote/speaker-diarization-3.1` both return 403 until someone accepts their conditions in a
    ...    \ \ browser, which an agent cannot do. `diarize.py` uses `speechbrain/spkrec-ecapa-voxceleb`, which is
    ...    \ \ ungated, and clusters 2 s windows of speech per clip. What is lost with it is pyannote's
    ...    \ \ overlap-aware segmentation: two people talking at once come out as one turn, labelled with
    ...    \ \ whoever dominates.
    ...
    ...    \ \ It runs *after* `speaking(e)`, not instead of it, and is told what that producer named. A cluster
    ...    \ \ whose speech mostly falls inside intervals already attributed to an entity is emitted under that
    ...    \ \ entity's name; a cluster matching nobody on screen keeps an anonymous `spk<n>`, which is the case
    ...    \ \ this exists for — a voice-over, a reply from off frame, the same person still talking after the
    ...    \ \ cut that left them. `speech_turn(e2)` asserts both that one voice holds the interval and that the
    ...    \ \ voice is e2, so a named turn's confidence is the product of the two.
    ...
    ...    \ \ (`speech(a1)` is the separate, weaker claim that the audio has speech in that interval. One
    ...    \ \ predicate meaning both, told apart only by whether its argument was an audio stream, is a trap.)
    ...    - **Synthesised speech is not evaluation material for this.** The obvious way to build exact truth
    ...    \ \ for a diarizer is to write the timeline yourself with `say -v Alex` and `say -v Samantha`. It does
    ...    \ \ not work, and it fails quietly. ECAPA places those two voices **0.170** apart — closer than two
    ...    \ \ utterances of one real speaker (0.176 mean, 0.227 for the specific pair measured), so a clip built
    ...    \ \ that way is one voice as far as any speaker embedding is concerned, and a correct diarizer scores
    ...    \ \ zero on it. The model is not at fault: the same model puts speech against a tone or noise at
    ...    \ \ ~1.0, one real speaker at 0.176, and two different real speakers at 0.89-1.13. The measurement
    ...    \ \ above uses real speakers from LibriSpeech and VoiceBank for that reason.
    ...    - **The VLM seeder is on a clock.** One clip spent 1189 s here when a provider accepted the request
    ...    \ \ and hung up mid-response: the socket sat in `CLOSE_WAIT` and the eval harness default of three
    ...    \ \ 180-second attempts applied per model, per target. Grounding now runs with its own short budget,
    ...    \ \ because losing a seed costs one entity's facts while hanging costs every producer behind it.
    ...    - **Not built yet:** a predictive (V-JEPA-class) event-boundary model in place of the
    ...    \ \ self-similarity one, and a dedicated gaze model — `facing` reads where the head points, which is
    ...    \ \ what "she turns away" means in an edit, but not where the eyes go.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

Measuring it on real pixels
    [Documentation]    `bin/moonsplice-vision eval --clips DIR` (X5) assembles real clips into a comp, which fixes the cut
    ...    times and a travelling inset's rectangle exactly while every pixel still comes from a camera, then
    ...    scores what perception recovers from the render.
    ...
    ...    Cuts are scored as an **off-by-N-frames histogram**, not as tIoU: at 3 s into a 9 s assembly, a cut
    ...    found one frame late overlaps 0.996 of the shot and is still wrong in an edit. The inset is scored
    ...    by per-frame IoU and by temporal IoU, and the seeder is not told where it is — a run that never
    ...    finds it scores zero recall, which is a seeder result and not a scoring artefact.
    ...
    ...    First run, 3 clips assembled to 9 s: **both cuts found, 0 frames off, no misses and no false
    ...    positives**; the inset seeded by cross-model agreement at mean IoU 0.957 and median 0.965, with
    ...    every sampled frame above 0.75.
    ...
    ...    And one finding the harness existed to produce. Temporal IoU came back at **0.519** while spatial
    ...    IoU was 0.957 — the inset is on screen 1.8–7.2 s across two cuts, and the track covered 2.9 s, one
    ...    shot's length. Spatially perfect, temporally half there, and only a measurement with exact truth
    ...    would have said which. Bounding propagation by the shot is right for content in the shot and wrong
    ...    for anything composited over the cut, so each boundary became a question rather than a wall
    ...    (`tracking.ignores_the_cut`, and see *Cuts and propagation* above for the two tests that had to be
    ...    discarded first).
    ...
    ...    | | run 1 | run 3 |
    ...    |---|---|---|
    ...    | cuts within 0 frames | 2/2 | 2/2 |
    ...    | inset samples | 29 | 54 |
    ...    | inset span recovered | 3.1–5.9 s | 1.9–7.2 s (truth 1.8–7.2) |
    ...    | mean IoU | 0.957 | 0.940 |
    ...    | frames IoU > 0.75 | 1.000 | 0.981 |
    ...    | **temporal IoU** | **0.519** | **0.981** |
    ...
    ...    Mean IoU fell slightly, and that is the honest shape of the result rather than a regression: the
    ...    frames recovered at the two extremes are the ones where the panel is partly there, so they are
    ...    scored now instead of being missing. Trading 0.017 of spatial agreement for 0.462 of temporal
    ...    coverage is the right trade for an edit, where a track that stops two shots early is unusable
    ...    however well it fits the frames it does cover.
    ...
    ...    Worth recording that the extension does not simply run to the end of the neighbouring shot: SAM 2
    ...    loses the panel where the panel is not, so the track stops at 1.90 s and 7.20 s against a truth of
    ...    1.8–7.2 s. Content that belongs to its shot still stops at its cut — all four of those crossings
    ...    were rejected — which is what lets `identity` rejoin it as a separate sighting with a calibrated
    ...    score.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

