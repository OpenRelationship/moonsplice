//! The stack end to end, against real compositions (the suite's description is in tests/common/mod.rs):
//! clips dragged, trimmed and cut on the timeline, and what paints over what.

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::words;
use moonsplice_studio_lib::{Edge, Gesture};

mod common;
use common::*;

/// Scenario: a clip is dragged and trimmed on the timeline
///
/// The verb an editor is mostly made of. A clip has a length of its own -- when it starts, how
/// long it runs, how far into its own footage it begins -- and all three are written in the
/// composition, so dragging it is an edit like any other rather than a new kind of state.
#[test]
fn a_clip_is_dragged_and_trimmed_on_the_timeline() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("clip.lua");
    std::fs::write(
        &comp,
        "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 1280, height = 720, duration = 6, fps = 30,\n  background = \"#0b0d12\",\n\n  scene = function(s)\n    s:video { src = \"comps/assets/earth_night.webm\", from = 1, duration = 2, media_start = 3 }\n  end,\n}\n",
    )
    .unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("trim")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let mut outline = engine.outline(doc.hash()).unwrap();
    let clip = outline["nodes"][0]["id"].as_str().unwrap().to_string();

    // What the engine says a clip is on screen for, which is the bar a person drags.
    let onscreen = |o: &serde_json::Value| -> (f64, f64) {
        let c = &o["nodes"][0]["onscreen"][0];
        (c["t0"].as_f64().unwrap(), c["t1"].as_f64().unwrap())
    };
    let prop = |o: &serde_json::Value, k: &str| o["nodes"][0]["props"][k].as_f64().unwrap();
    // On screen is measured in frames, so a clip asked to end between two of them ends on the
    // next one. Comparisons here are to the frame, which is the resolution the answer has.
    let frame = 1.0 / 30.0;
    let shows = |o: &serde_json::Value, a: f64, b: f64| {
        let (t0, t1) = onscreen(o);
        assert!(
            (t0 - a).abs() <= frame + 1e-6 && (t1 - b).abs() <= frame + 1e-6,
            "on screen {t0:.3}..{t1:.3}, expected about {a:.3}..{b:.3}"
        );
    };
    shows(&outline, 1.0, 3.0);

    let apply = |outline: &serde_json::Value, doc: &mut SourceDoc, g: Gesture| {
        let names = words::names(outline);
        let edits = moonsplice_studio_lib::gesture_to_edits(g, outline)
            .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        let nodes = node_refs(outline);
        let (_, next) =
            moonsplice_studio_lib::write_and_reload(doc, &engine, &edits, &nodes, &names)
                .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        next
    };

    // Dragged down the timeline: it starts later, and it is the same two seconds of footage.
    outline = apply(&outline, &mut doc, Gesture::Slide { node: clip.clone(), t: 2.5 });
    shows(&outline, 2.5, 4.5);
    assert_eq!(prop(&outline, "media_start"), 3.0, "the same footage, later");

    // Dragged past the end of the composition: it stops at the end, because a composition's
    // length is fixed and a clip that ran past it would be a clip nobody could see.
    outline = apply(&outline, &mut doc, Gesture::Slide { node: clip.clone(), t: 99.0 });
    shows(&outline, 4.0, 6.0);

    // The head trimmed off: it starts later, it is shorter, and it starts later in the footage
    // by exactly what was taken -- which is the difference between trimming a shot and moving it.
    outline = apply(&outline, &mut doc, Gesture::Slide { node: clip.clone(), t: 1.0 });
    let before = prop(&outline, "media_start");
    outline = apply(
        &outline,
        &mut doc,
        Gesture::Trim { node: clip.clone(), edge: Edge::In, t: 1.5 },
    );
    shows(&outline, 1.5, 3.0);
    assert_eq!(prop(&outline, "media_start"), before + 0.5);

    // The tail trimmed: only its length changes.
    outline = apply(
        &outline,
        &mut doc,
        Gesture::Trim { node: clip.clone(), edge: Edge::Out, t: 2.25 },
    );
    shows(&outline, 1.5, 2.25);
    assert_eq!(prop(&outline, "media_start"), before + 0.5, "trimming the tail left the head");

    // Dragged back past the beginning of the composition: it stops at zero, and gives back
    // exactly as much footage as it moved -- the two numbers stay in step, which is the whole
    // point of trimming rather than moving.
    let (was_start, was_media) = (onscreen(&outline).0, prop(&outline, "media_start"));
    outline = apply(
        &outline,
        &mut doc,
        Gesture::Trim { node: clip.clone(), edge: Edge::In, t: -99.0 },
    );
    assert_eq!(prop(&outline, "from"), 0.0, "it stops at the start of the composition");
    assert!((prop(&outline, "media_start") - (was_media - was_start)).abs() < 0.02);

    // And dragged back past its own first frame: it stops there instead of asking for footage
    // that is not in the clip.
    outline = apply(&outline, &mut doc, Gesture::Slide { node: clip.clone(), t: 4.0 });
    outline = apply(
        &outline,
        &mut doc,
        Gesture::Trim { node: clip.clone(), edge: Edge::In, t: 0.0 },
    );
    assert_eq!(prop(&outline, "media_start"), 0.0, "the first frame of the footage");
    assert!(prop(&outline, "from") > 0.0, "so it cannot reach the start of the composition");

    // Trimmed shorter than a frame: it keeps a frame, because a clip of no length is a clip
    // nobody can find again.
    outline = apply(
        &outline,
        &mut doc,
        Gesture::Trim { node: clip.clone(), edge: Edge::Out, t: -5.0 },
    );
    let (t0, t1) = onscreen(&outline);
    assert!(t1 - t0 <= 2.0 * frame + 1e-6 && t1 > t0, "a frame long, not nothing: {t0}..{t1}");

    // And it still renders: the file the engine reloaded is a composition, not a draft.
    let (rgba, w, h) = engine.frame(t0 + 0.01).expect("a frame of the trimmed clip");
    assert_eq!((w, h), (1280, 720));
    assert!(rgba.iter().any(|b| *b != 0));

    // Nothing that has no length of its own can be dragged this way, and the refusal says why
    // in words -- no id, no key.
    let names = words::names(&outline);
    let block = Gesture::Slide { node: "nothing-like-this".into(), t: 1.0 };
    let refusal = moonsplice_studio_lib::gesture_to_edits(block, &outline).unwrap_err();
    let said = refusal.say(&names);
    assert!(said.contains("no length of its own"), "{said}");
    engine.stop();
}

/// Scenario: a clip is cut in two at the playhead
///
/// The razor. It is one gesture with two halves on the other side of it, and the thing that makes
/// it a razor rather than a delete and two drops is that the picture does not jump across the
/// join: the second half starts exactly as far into its own footage as the first half ended.
#[test]
fn a_clip_is_cut_in_two_at_the_playhead() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("razor.lua");
    std::fs::write(
        &comp,
        "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 1280, height = 720, duration = 8, fps = 30,\n  background = \"#0b0d12\",\n\n  scene = function(s)\n    s:video { src = \"comps/assets/earth_night.webm\", from = 1, duration = 4, media_start = 2 }\n    s:rect { x = 0, y = 600, w = 1280, h = 120, color = \"#000000aa\" }\n  end,\n}\n",
    )
    .unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("razor")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let mut outline = engine.outline(doc.hash()).unwrap();
    let clip = outline["nodes"][0]["id"].as_str().unwrap().to_string();

    let apply = |outline: &serde_json::Value, doc: &mut SourceDoc, g: Gesture| {
        let names = words::names(outline);
        let edits = moonsplice_studio_lib::gesture_to_edits(g, outline)
            .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        let nodes = node_refs(outline);
        let (_, next) =
            moonsplice_studio_lib::write_and_reload(doc, &engine, &edits, &nodes, &names)
                .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        next
    };

    let clips = |o: &serde_json::Value| -> Vec<(f64, f64, f64)> {
        o["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|n| n["kind"] == "video")
            .map(|n| {
                let p = &n["props"];
                (
                    p["from"].as_f64().unwrap(),
                    p["duration"].as_f64().unwrap(),
                    p["media_start"].as_f64().unwrap(),
                )
            })
            .collect()
    };
    assert_eq!(clips(&outline), vec![(1.0, 4.0, 2.0)]);

    // Cut at three seconds in.
    outline = apply(&outline, &mut doc, Gesture::Split { node: clip.clone(), t: 3.0 });
    assert_eq!(
        clips(&outline),
        vec![(1.0, 2.0, 2.0), (3.0, 2.0, 4.0)],
        "the same four seconds, in two pieces, and the footage runs on across the join"
    );

    // The picture at the join is the picture that was there before the cut. Rendered either
    // side of it, a frame comes back and it is not black -- which is what "the cut did not
    // break the clip" means in pixels.
    for t in [2.9, 3.1] {
        let (rgba, w, h) = engine.frame(t).expect("a frame across the join");
        assert_eq!((w, h), (1280, 720));
        assert!(rgba.iter().any(|b| *b != 0), "nothing at {t}s");
    }

    // The half that was made is under the half it came from, not on top of the plate that was
    // drawn after it: the stack is unchanged.
    let order: Vec<&str> = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["kind"].as_str().unwrap())
        .collect();
    assert_eq!(order, vec!["video", "video", "rect"], "{order:?}");

    // Cutting the second half again makes three, and they still join up.
    let second = outline["nodes"][1]["id"].as_str().unwrap().to_string();
    outline = apply(&outline, &mut doc, Gesture::Split { node: second, t: 4.0 });
    assert_eq!(clips(&outline), vec![(1.0, 2.0, 2.0), (3.0, 1.0, 4.0), (4.0, 1.0, 5.0)]);

    // Undo takes the whole cut back in one step -- it is one edit, not three.
    doc.undo().unwrap();
    engine.reload().unwrap();
    let back = engine.outline(doc.hash()).unwrap();
    assert_eq!(clips(&back), vec![(1.0, 2.0, 2.0), (3.0, 2.0, 4.0)]);

    // A cut that falls outside the clip is refused, in words, with where the clip actually is.
    let names = words::names(&outline);
    let refusal = moonsplice_studio_lib::gesture_to_edits(
        Gesture::Split { node: clip.clone(), t: 7.5 },
        &outline,
    );
    let said = match refusal {
        Ok(edits) => moonsplice_studio_lib::lower::lower(&doc.text(), &edits, None)
            .unwrap_err()
            .say(&names),
        Err(r) => r.say(&names),
    };
    assert!(said.contains("inside the clip"), "{said}");
    assert!(!said.contains("video1"), "an id reached a person: {said}");

    // And a thing with no length of its own says so rather than being cut somehow.
    let plate = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["kind"] == "rect")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let said = moonsplice_studio_lib::gesture_to_edits(Gesture::Split { node: plate, t: 2.0 }, &outline)
        .unwrap_err()
        .say(&names);
    assert!(said.contains("no length of its own"), "{said}");
    engine.stop();
}

/// Scenario: what paints over what is changed from the timeline
///
/// A layer list exists to answer one question, and until now the app could show the answer and
/// not change it. The order of the statements is the order of the picture, so this moves a whole
/// statement — and the proof is not the text, it is the pixel: the thing that was hidden is the
/// thing on screen afterwards.
#[test]
fn what_paints_over_what_is_changed_from_the_timeline() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("stack.lua");
    // Two plates, one over the other, each filling the frame. Whichever is written last is the
    // one you see, so the colour at the middle of the picture says which that is.
    std::fs::write(
        &comp,
        "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 320, height = 180, duration = 1, fps = 30,\n  background = \"#000000\",\n\n  scene = function(s)\n    s:rect { x = 0, y = 0, w = 320, h = 180, color = \"#ff0000\" }\n    s:rect { x = 0, y = 0, w = 320, h = 180, color = \"#00ff00\" }\n    s:audio { src = \"comps/assets/piano.ogg\", at = 0, duration = 1 }\n  end,\n}\n",
    )
    .unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("stack")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let mut outline = engine.outline(doc.hash()).unwrap();

    // The colour in the middle of the frame, which is the whole answer here.
    let middle = |engine: &Engine| -> (u8, u8, u8) {
        let (rgba, w, h) = engine.frame(0.5).expect("a frame");
        let at = ((h as usize / 2) * w as usize + w as usize / 2) * 4;
        (rgba[at], rgba[at + 1], rgba[at + 2])
    };
    let (r, g, _) = middle(&engine);
    assert!(g > 200 && r < 60, "the green plate is written last, so it is the one you see");

    let red = outline["nodes"][0]["id"].as_str().unwrap().to_string();
    let green = outline["nodes"][1]["id"].as_str().unwrap().to_string();

    let apply = |outline: &serde_json::Value, doc: &mut SourceDoc, g: Gesture| {
        let names = words::names(outline);
        let edits = moonsplice_studio_lib::gesture_to_edits(g, outline)
            .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        let nodes = node_refs(outline);
        let (_, next) =
            moonsplice_studio_lib::write_and_reload(doc, &engine, &edits, &nodes, &names)
                .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        next
    };

    // The red plate brought in front of the green one.
    outline = apply(
        &outline,
        &mut doc,
        Gesture::Restack {
            node: red.clone(),
            over: Some(green.clone()),
        },
    );
    let (r, g, _) = middle(&engine);
    assert!(r > 200 && g < 60, "red is in front now: {r},{g}");

    // And the front one sent to the very back again, which puts green back on top. A thing's id
    // is where it is in the composition, so after a move the front plate is the second node --
    // which is the red one, and this is the only way to say so: colour never reaches the outline.
    let front = outline["nodes"][1]["id"].as_str().unwrap().to_string();
    outline = apply(
        &outline,
        &mut doc,
        Gesture::Restack {
            node: front,
            over: None,
        },
    );
    let (r, g, _) = middle(&engine);
    assert!(g > 200 && r < 60, "green is back on top: {r},{g}");

    // Undo puts it where it was, and the text is what it was byte for byte.
    let before = doc.text().to_string();
    doc.undo().unwrap();
    doc.redo().unwrap();
    assert_eq!(doc.text(), before, "a move there and back is the same file");

    // Sound is not in the stack at all, and the refusal says so the way a person would: a mix
    // has no front and no back, and what makes one thing louder than another is its loudness.
    let names = words::names(&outline);
    let sound = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["kind"] == "audio")
        .expect("the piano is in there")["id"]
        .as_str()
        .unwrap()
        .to_string();
    let said = moonsplice_studio_lib::gesture_to_edits(
        Gesture::Restack {
            node: sound,
            over: None,
        },
        &outline,
    )
    .expect_err("sound has no stack")
    .say(&names);
    assert!(said.contains("no front or back"), "{said}");
    assert!(!said.contains("audio3"), "an id reached a person: {said}");
    engine.stop();
}
