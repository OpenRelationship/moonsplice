//! The stack end to end, against real compositions (the suite's description is in tests/common/mod.rs):
//! when a movement starts, a composition that will not open, and a gap in the timeline closed.

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::words;
use moonsplice_studio_lib::Gesture;

mod common;
use common::*;

/// Scenario: when a movement starts is dragged
///
/// The last gesture with no verb. A movement is a statement in a script and a script is a cursor
/// that walks forward, so when a movement begins is not a number written beside it — it is
/// everything before it added up. Dragging its left edge therefore changes the one thing in
/// front of it that holds time, and what follows moves with it, exactly as it does when a
/// movement is made longer.
#[test]
fn when_a_movement_starts_is_dragged() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("move.lua");
    std::fs::write(
        &comp,
        "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 320, height = 180, duration = 4, fps = 30,\n  background = \"#000000\",\n\n  scene = function(s)\n    local bar = s:rect { x = 0, y = 80, w = 10, h = 20, color = \"#3ee0c6\" }\n    local dot = s:circle { x = 20, y = 20, r = 6, color = \"#ffffff\" }\n\n    s:script(function(t)\n      t:wait(0.2)\n      t:tween(bar, 0.4, { w = 200 }, \"sineOut\")\n      t:tween(dot, 0.3, { x = 200 }, \"sineOut\")\n    end)\n  end,\n}\n",
    )
    .unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("moves")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let mut outline = engine.outline(doc.hash()).unwrap();

    // Every movement in the composition, as the timeline draws them: who, from when, to when.
    let moves = |o: &serde_json::Value| -> Vec<(String, f64, f64)> {
        let mut out: Vec<(String, f64, f64)> = o["tracks"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|tr| {
                let node = tr["node"].as_str().unwrap().to_string();
                tr["segments"].as_array().unwrap().iter().map(move |s| {
                    (
                        node.clone(),
                        (s["t0"].as_f64().unwrap() * 1000.0).round() / 1000.0,
                        (s["t1"].as_f64().unwrap() * 1000.0).round() / 1000.0,
                    )
                })
            })
            .collect();
        out.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap());
        out
    };
    assert_eq!(
        moves(&outline),
        vec![
            ("rect1".into(), 0.2, 0.6),
            ("circle2".into(), 0.6, 0.9)
        ]
    );

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

    // The bar's movement dragged half a second later. It starts there, it is the same length,
    // and the movement that follows it in the script moved with it -- which is what a script
    // means, and what the handle's own label says it will do.
    outline = apply(
        &outline,
        &mut doc,
        Gesture::MoveStart {
            node: "rect1".into(),
            t: 0.7,
            occurrence: 0,
        },
    );
    assert_eq!(
        moves(&outline),
        vec![
            ("rect1".into(), 0.7, 1.1),
            ("circle2".into(), 1.1, 1.4)
        ]
    );

    // Dragged back to the start: the wait in front of it goes to nothing.
    outline = apply(
        &outline,
        &mut doc,
        Gesture::MoveStart {
            node: "rect1".into(),
            t: 0.0,
            occurrence: 0,
        },
    );
    assert_eq!(moves(&outline)[0], ("rect1".into(), 0.0, 0.4));
    assert!(doc.text().contains("t:wait(0)"), "{}", doc.text());

    // The dot's movement follows the bar's with nothing written between them, so moving it later
    // puts a wait in -- and the composition still renders, which is the only proof that what was
    // written is a composition and not a draft.
    outline = apply(
        &outline,
        &mut doc,
        Gesture::MoveStart {
            node: "circle2".into(),
            t: 0.9,
            occurrence: 0,
        },
    );
    assert_eq!(moves(&outline)[1], ("circle2".into(), 0.9, 1.2));
    let (rgba, w, h) = engine.frame(1.0).expect("a frame after the move");
    assert_eq!((w, h), (320, 180));
    assert!(rgba.iter().any(|b| *b != 0));

    // Undo takes the whole thing back in one step.
    doc.undo().unwrap();
    engine.reload().unwrap();
    let back = engine.outline(doc.hash()).unwrap();
    assert_eq!(moves(&back)[1], ("circle2".into(), 0.4, 0.7));

    // And a movement that is not there is said in words, with no id in them.
    let names = words::names(&outline);
    let said = moonsplice_studio_lib::gesture_to_edits(
        Gesture::MoveStart {
            node: "rect1".into(),
            t: 1.0,
            occurrence: 9,
        },
        &outline,
    )
    .unwrap_err()
    .say(&names);
    assert!(said.contains("no movement there"), "{said}");
    assert!(!said.contains("rect1"), "an id reached a person: {said}");
    engine.stop();
}

/// Scenario: a composition that will not open says why
///
/// Not every composition loads. It may use something this machine's renderer does not have, or
/// it may simply be wrong. What the app must never do is say "the renderer exited", which is a
/// sentence about a process and gives a person nothing to act on — the renderer said why on its
/// way down, and that is the only useful thing anybody has.
#[test]
fn a_composition_that_will_not_open_says_why() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();

    // Two ways a composition fails, both of them real: it does not parse, and it stops itself.
    // Footage that is not there is not one of them any more: the app asks for one missing file to
    // take itself off the air rather than the composition with it (checked below).
    let cases: [(&str, &str, &str); 2] = [
        (
            "unparseable.lua",
            "local e = require(\"moonsplice\")\nreturn e.comp {\n  width = 320,\n",
            "it does not parse",
        ),
        (
            "nonsense.lua",
            "local e = require(\"moonsplice\")\nreturn e.comp {\n  width = 320, height = 180, duration = 1, fps = 30,\n  scene = function(s)\n    s:rect { x = 0, y = 0, w = 10, h = 10 }\n    error(\"this composition refuses to load\")\n  end,\n}\n",
            "it stops itself",
        ),
    ];

    let missing = work.path().join("missing.lua");
    std::fs::write(
        &missing,
        "local e = require(\"moonsplice\")\nreturn e.comp {\n  width = 320, height = 180, duration = 1, fps = 30,\n  scene = function(s)\n    s:video { src = \"no/such/clip.mp4\", from = 0, duration = 1 }\n  end,\n}\n",
    )
    .unwrap();
    match Engine::start(&missing, &root, &serve_dir("broken-missing")) {
        Ok(engine) => engine.stop(),
        Err(e) => panic!("one missing clip took the composition with it: {e}"),
    }

    let mut any = false;
    for (name, text, why) in cases {
        let comp = work.path().join(name);
        std::fs::write(&comp, text).unwrap();
        let dir = serve_dir(&format!("broken-{}", name.replace('.', "-")));
        match Engine::start(&comp, &root, &dir) {
            Ok(engine) => {
                engine.stop();
                panic!("{name} opened, and it should not have");
            }
            Err(e) => {
                let said = e.to_string();
                eprintln!("  {why:<28} -> {said}");
                any = true;

                // It says a composition would not open, which is the thing the person did.
                assert!(
                    said.contains("composition would not open"),
                    "{name}: {said}"
                );
                // It is not a sentence about a process.
                assert!(!said.contains("exited"), "{name}: {said}");
                assert!(!said.contains("unexpected greeting"), "{name}: {said}");
                // And it carries no path into the engine's own Lua, which is code about code.
                for leak in ["core/runtime/", "core/moonsplice", ".lua:", "stack traceback"] {
                    assert!(!said.contains(leak), "{name} said something about code: {said}");
                }
                assert!(said.len() < 240, "{name} said too much: {said}");
            }
        }
    }
    assert!(any);

    // And the one in the repo the engine cannot open yet: `drop` bakes a Box2D simulation, and
    // physics is not ported (.robot/docs/engine.robot). It fails with a sentence, like everything else.
    let drop = root.join("comps/cases/drop.lua");
    if drop.is_file() {
        match Engine::start(&drop, &root, &serve_dir("broken-drop")) {
            Ok(engine) => {
                eprintln!("  drop                         -> opens here (the fork is built)");
                engine.stop();
            }
            Err(e) => {
                let said = e.to_string();
                eprintln!("  drop                         -> {said}");
                assert!(said.contains("composition would not open"), "{said}");
            }
        }
    }
}

/// Scenario: a gap in the timeline is closed
///
/// The ripple, which is the one edit in a cutting room that is about the things you did *not*
/// touch. Taking a line out of a voiceover and leaving a two second hole where it was is not an
/// edit anybody wants; closing the hole means moving everything after it, which is many changes
/// that have to be one undo.
///
/// It is not a new verb. It is the same "set this to that" the inspector writes, said of several
/// things at once -- so it lowers through the road everything else lowers through, and the proof
/// that nothing was smuggled in is that one undo puts the file back byte for byte.
#[test]
fn a_gap_in_the_timeline_is_closed() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("gaps.lua");
    let clip = "comps/assets/earth_night.webm";
    std::fs::write(
        &comp,
        format!(
            "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {{\n  \
             width = 640, height = 360, duration = 10, fps = 30,\n  background = \"#0b0d12\",\n\n  \
             scene = function(s)\n    \
             s:video {{ src = \"{clip}\", from = 0, duration = 2, media_start = 0 }}\n    \
             s:video {{ src = \"{clip}\", from = 3, duration = 2, media_start = 0 }}\n    \
             s:video {{ src = \"{clip}\", from = 6, duration = 2, media_start = 0 }}\n  \
             end,\n}}\n"
        ),
    )
    .unwrap();
    let was = std::fs::read_to_string(&comp).unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("gaps")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let mut outline = engine.outline(doc.hash()).unwrap();

    let starts = |o: &serde_json::Value| -> Vec<f64> {
        o["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|n| n["kind"] == "video")
            .map(|n| n["props"]["from"].as_f64().unwrap())
            .collect()
    };
    let ids = |o: &serde_json::Value| -> Vec<String> {
        o["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|n| n["kind"] == "video")
            .map(|n| n["id"].as_str().unwrap().to_string())
            .collect()
    };
    let apply = |outline: &serde_json::Value, doc: &mut SourceDoc, g: Gesture| {
        let names = words::names(outline);
        let edits = moonsplice_studio_lib::gesture_to_edits(g, outline)
            .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        let nodes = node_refs(outline);
        let (applied, next) =
            moonsplice_studio_lib::write_and_reload(doc, &engine, &edits, &nodes, &names)
                .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        (applied, next)
    };

    assert_eq!(starts(&outline), vec![0.0, 3.0, 6.0]);
    let three = ids(&outline);

    // The second gap first, so the assertion is about *that* hole and not about everything
    // sliding: closing the one after the middle clip moves only the last.
    let (_, next) = apply(
        &outline,
        &mut doc,
        Gesture::CloseGap {
            after: three[1].clone(),
        },
    );
    outline = next;
    assert_eq!(
        starts(&outline),
        vec![0.0, 3.0, 5.0],
        "only what was after the hole moved, and by exactly the hole"
    );

    // And the first, which moves both of the others by one second.
    let (_, next) = apply(
        &outline,
        &mut doc,
        Gesture::CloseGap {
            after: three[0].clone(),
        },
    );
    outline = next;
    assert_eq!(starts(&outline), vec![0.0, 2.0, 4.0]);

    // Now take the middle one out and close the hole it leaves. Three edits -- the last clip
    // moves, and the middle statement goes -- and the composition has two clips running back
    // to back.
    let (applied, next) = apply(
        &outline,
        &mut doc,
        Gesture::TakeOutAndClose {
            node: three[1].clone(),
        },
    );
    outline = next;
    assert_eq!(starts(&outline), vec![0.0, 2.0], "{:?}", applied.what);
    assert_eq!(ids(&outline).len(), 2);

    // A gap where there is nothing after is not a gap.
    let names = words::names(&outline);
    let last = ids(&outline)[1].clone();
    let refused = moonsplice_studio_lib::gesture_to_edits(
        Gesture::CloseGap { after: last },
        &outline,
    )
    .expect_err("there is nothing after the last clip");
    let said = refused.say(&names);
    assert!(said.contains("nothing after"), "{said}");

    // Three gestures, three undos, and the file is what it was. Every one of them was several
    // changes at once; if any of them had been two steps this would not come back.
    for _ in 0..3 {
        doc.undo().unwrap();
    }
    assert_eq!(
        std::fs::read_to_string(&comp).unwrap(),
        was,
        "three ripples, three undos, byte for byte"
    );
    engine.stop();
}
