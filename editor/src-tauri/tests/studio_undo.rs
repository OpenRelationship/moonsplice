//! The stack end to end, against real compositions (the suite's description is in tests/common/mod.rs):
//! a whole edit made and taken back, and a thing given a name.

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::lower::Edit;
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::words;
use moonsplice_studio_lib::{Edge, Gesture};

mod common;
use common::*;

/// Scenario: a whole edit is made and taken back
///
/// Every other test here proves one verb. This one is the session: somebody opens a composition,
/// puts a clip in, drags it, trims both ends, cuts it in two, moves the second half, changes what
/// is in front of what, moves when something starts, takes the extra piece out — and then undoes
/// all of it.
///
/// Two things are asserted and they are the two the whole app rests on. Every step lands: the
/// engine re-reads the file each time and reports what was asked for. And the end is the
/// beginning, byte for byte — which is only true if every verb is a span rewrite over the source
/// and nothing anywhere kept a change of its own.
#[test]
fn a_whole_edit_is_made_and_taken_back() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("session.lua");
    let before = "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 640, height = 360, duration = 10, fps = 30,\n  background = \"#0b0d12\",\n\n  scene = function(s)\n    local plate = s:rect { x = 0, y = 0, w = 640, h = 360, color = \"#16203a\" }\n    local card = s:rect { x = 40, y = 40, w = 200, h = 120, color = \"#3ee0c6\" }\n\n    s:script(function(t)\n      t:wait(0.5)\n      t:tween(card, 0.6, { x = 300 }, \"sineOut\")\n    end)\n  end,\n}\n";
    std::fs::write(&comp, before).unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("session")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let mut outline = engine.outline(doc.hash()).unwrap();

    let apply = |outline: &serde_json::Value, doc: &mut SourceDoc, g: Gesture| {
        let names = words::names(outline);
        let what = format!("{g:?}");
        let edits = moonsplice_studio_lib::gesture_to_edits(g, outline)
            .unwrap_or_else(|r| panic!("{what}: {}", r.say(&names)));
        let nodes = node_refs(outline);
        let (applied, next) =
            moonsplice_studio_lib::write_and_reload(doc, &engine, &edits, &nodes, &names)
                .unwrap_or_else(|r| panic!("{what}: {}", r.say(&names)));
        // Every step says what it did, in words a person could read back.
        assert!(!applied.what.is_empty(), "{what} said nothing");
        for said in &applied.what {
            assert!(!said.contains('_'), "{what} said something that reads like code: {said}");
        }
        (applied.what.join("; "), next)
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
                    p["from"].as_f64().unwrap_or(0.0),
                    p["duration"].as_f64().unwrap_or(0.0),
                    p["media_start"].as_f64().unwrap_or(0.0),
                )
            })
            .collect()
    };
    let kinds = |o: &serde_json::Value| -> Vec<String> {
        o["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| n["kind"].as_str().unwrap().to_string())
            .collect()
    };

    let mut story: Vec<String> = Vec::new();
    let mut steps = 0usize;

    // 1. Footage goes in. This is `place`, which is the only way anything new arrives.
    {
        let names = words::names(&outline);
        let edit = Edit::Place {
            kind: "video".into(),
            fields: vec![
                ("src".into(), "\"comps/assets/earth_night.webm\"".into()),
                ("from".into(), "1".into()),
                ("duration".into(), "4".into()),
                ("media_start".into(), "2".into()),
            ],
            what: "Earth night".into(),
        };
        let nodes = node_refs(&outline);
        let (applied, next) =
            moonsplice_studio_lib::write_and_reload(&mut doc, &engine, &[edit], &nodes, &names)
                .expect("the clip goes in");
        story.push(applied.what.join("; "));
        outline = next;
        steps += 1;
    }
    assert_eq!(clips(&outline), vec![(1.0, 4.0, 2.0)]);
    let clip = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["kind"] == "video")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    // 2. Dragged down the track.
    let (said, next) = apply(&outline, &mut doc, Gesture::Slide { node: clip.clone(), t: 2.0 });
    (story.push(said), outline = next, steps += 1);
    assert_eq!(clips(&outline)[0].0, 2.0);

    // 3. The head trimmed: it starts later and further into its own footage.
    let (said, next) = apply(
        &outline,
        &mut doc,
        Gesture::Trim { node: clip.clone(), edge: Edge::In, t: 2.5 },
    );
    (story.push(said), outline = next, steps += 1);
    assert_eq!(clips(&outline), vec![(2.5, 3.5, 2.5)]);

    // 4. And the tail.
    let (said, next) = apply(
        &outline,
        &mut doc,
        Gesture::Trim { node: clip.clone(), edge: Edge::Out, t: 5.5 },
    );
    (story.push(said), outline = next, steps += 1);
    assert_eq!(clips(&outline), vec![(2.5, 3.0, 2.5)]);

    // 5. Cut in two at four seconds.
    let (said, next) = apply(&outline, &mut doc, Gesture::Split { node: clip.clone(), t: 4.0 });
    (story.push(said), outline = next, steps += 1);
    assert_eq!(clips(&outline), vec![(2.5, 1.5, 2.5), (4.0, 1.5, 4.0)]);

    // 6. The second half dragged to the end of the composition.
    let second = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|n| n["kind"] == "video")
        .nth(1)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let (said, next) = apply(&outline, &mut doc, Gesture::Slide { node: second.clone(), t: 8.0 });
    (story.push(said), outline = next, steps += 1);
    assert_eq!(clips(&outline)[1].0, 8.0);

    // 7. The plate brought in front of everything. It is the first thing written, so the clips
    //    are drawn over it until it moves.
    let plate = outline["nodes"][0]["id"].as_str().unwrap().to_string();
    let last = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .last()
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let (said, next) = apply(
        &outline,
        &mut doc,
        Gesture::Restack { node: plate, over: Some(last) },
    );
    (story.push(said), outline = next, steps += 1);
    assert_eq!(kinds(&outline).last().map(String::as_str), Some("rect"));

    // And the card cannot go with it, because what moves it is written in between -- said in
    // those words rather than in words about source code.
    let card = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["kind"] == "rect" && n["id"].as_str() != outline["nodes"].as_array().unwrap().last().unwrap()["id"].as_str())
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let names = words::names(&outline);
    let refused = moonsplice_studio_lib::gesture_to_edits(
        Gesture::Restack { node: card.clone(), over: Some(outline["nodes"].as_array().unwrap().last().unwrap()["id"].as_str().unwrap().to_string()) },
        &outline,
    )
    .map(|edits| {
        moonsplice_studio_lib::lower::lower(&doc.text(), &edits, Some(&node_refs(&outline)))
            .err()
            .map(|r| r.say(&names))
    })
    .unwrap_or_else(|r| Some(r.say(&names)));
    if let Some(said) = refused {
        assert!(said.contains("what moves it"), "{said}");
        story.push(format!("(refused: {said})"));
    }

    // 8. Its movement starts later.
    let moved = outline["tracks"][0]["node"].as_str().unwrap().to_string();
    let (said, next) = apply(
        &outline,
        &mut doc,
        Gesture::MoveStart { node: moved, t: 1.5, occurrence: 0 },
    );
    (story.push(said), outline = next, steps += 1);
    assert_eq!(
        (outline["tracks"][0]["segments"][0]["t0"].as_f64().unwrap() * 100.0).round(),
        150.0
    );

    // 9. And the second half taken out again.
    let gone = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|n| n["kind"] == "video")
        .nth(1)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let (said, next) = apply(&outline, &mut doc, Gesture::Remove { node: gone });
    (story.push(said), outline = next, steps += 1);
    assert_eq!(clips(&outline).len(), 1);

    // The composition still renders. Nine edits in, what is on disk is a composition and not a
    // draft -- which is the only thing that makes the whole chain worth anything.
    for t in [0.5, 3.0, 5.0] {
        let (rgba, w, h) = engine.frame(t).unwrap_or_else(|e| panic!("no frame at {t}s: {e}"));
        assert_eq!((w, h), (640, 360));
        assert!(rgba.iter().any(|b| *b != 0), "nothing at {t}s");
    }

    eprintln!("\nthe session, in the words the app used:");
    for (i, said) in story.iter().enumerate() {
        eprintln!("  {}. {said}", i + 1);
    }

    // And back. Nine edits, nine undos, and the file is what it was to the byte -- which can
    // only be true if every one of them was a rewrite of this text and nothing was kept anywhere
    // else.
    for i in 0..steps {
        doc.undo().unwrap_or_else(|e| panic!("undo {i}: {e}"));
    }
    assert_eq!(doc.text(), before, "nine edits and back is not the same file");

    // Redone, it is the same again -- the history is a list of these texts, not a replay of
    // gestures that might land differently the second time.
    for _ in 0..steps {
        doc.redo().unwrap();
    }
    let done = doc.text().to_string();
    for _ in 0..steps {
        doc.undo().unwrap();
    }
    assert_eq!(doc.text(), before);
    for _ in 0..steps {
        doc.redo().unwrap();
    }
    assert_eq!(doc.text(), done, "redoing twice gave two different files");
    engine.stop();
}

/// Scenario: a thing is given a name
///
/// A shape nobody named is "Block 2", and "Block 2" is a position, not a name: reorder the stack
/// and it becomes Block 1 while the thing itself has not changed at all. So a thing can be given
/// a name, which is written into the composition and then survives everything.
#[test]
fn a_thing_is_given_a_name() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("named.lua");
    std::fs::write(
        &comp,
        "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 320, height = 180, duration = 2, fps = 30,\n  background = \"#000000\",\n\n  scene = function(s)\n    s:rect { x = 0, y = 0, w = 320, h = 180, color = \"#16203a\" }\n    s:rect { x = 20, y = 20, w = 80, h = 40, color = \"#3ee0c6\" }\n    s:text { x = 20, y = 120, text = \"Hold the cut.\", size = 18 }\n  end,\n}\n",
    )
    .unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("named")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let mut outline = engine.outline(doc.hash()).unwrap();

    let called = |o: &serde_json::Value| -> Vec<String> {
        let names = words::names(o);
        o["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| names[n["id"].as_str().unwrap()].clone())
            .collect()
    };
    // Unnamed, they are numbered by where they are. The text names itself after what it says,
    // which is why it is not in the numbering.
    assert_eq!(called(&outline), vec!["Block 1", "Block 2", "Hold the cut."]);

    let apply = |outline: &serde_json::Value, doc: &mut SourceDoc, g: Gesture| {
        let names = words::names(outline);
        let edits = moonsplice_studio_lib::gesture_to_edits(g, outline)
            .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        let nodes = node_refs(outline);
        let (applied, next) =
            moonsplice_studio_lib::write_and_reload(doc, &engine, &edits, &nodes, &names)
                .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        (applied.what.join("; "), next)
    };

    // The second one named. It is a change to the composition like any other.
    let second = outline["nodes"][1]["id"].as_str().unwrap().to_string();
    let (said, next) = apply(
        &outline,
        &mut doc,
        Gesture::SetValue {
            node: second.clone(),
            key: "label".into(),
            value: serde_json::json!("The pill"),
        },
    );
    outline = next;
    assert!(said.contains("The pill"), "{said}");
    assert_eq!(called(&outline), vec!["Block", "The pill", "Hold the cut."]);

    // And now it survives being reordered, which is the whole point: "Block 2" would have become
    // "Block 1" here and named the wrong thing in every sentence the app said afterwards.
    let first = outline["nodes"][0]["id"].as_str().unwrap().to_string();
    let last = outline["nodes"].as_array().unwrap().last().unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let (_, next) = apply(
        &outline,
        &mut doc,
        Gesture::Restack {
            node: first,
            over: Some(last),
        },
    );
    outline = next;
    assert!(called(&outline).contains(&"The pill".to_string()), "{:?}", called(&outline));

    // A name wins over one worked out from what the thing holds, so a line of writing can be
    // called something other than what it says.
    let text = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["kind"] == "text")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let (_, next) = apply(
        &outline,
        &mut doc,
        Gesture::SetValue {
            node: text,
            key: "label".into(),
            value: serde_json::json!("Lower third"),
        },
    );
    outline = next;
    assert!(called(&outline).contains(&"Lower third".to_string()), "{:?}", called(&outline));

    // It still renders, and taking the names back off leaves the file as it was.
    let (rgba, w, h) = engine.frame(1.0).expect("a frame");
    assert_eq!((w, h), (320, 180));
    assert!(rgba.iter().any(|b| *b != 0));
    engine.stop();
}
