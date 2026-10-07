//! The stack end to end, against real compositions (the suite's description is in tests/common/mod.rs):
//! a whole sitting of gestures, and a thing from the project going into a composition.

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::lower::Edit;
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::words;
use moonsplice_studio_lib::Gesture;

mod common;
use common::*;

/// One sitting with the app: every gesture the UI can make, in the order a person would make
/// them, each one going through the same translation the window uses -- and then all the way back
/// to the original bytes with undo, and forward again with redo.
///
/// The gestures are covered one at a time elsewhere. What this adds is the sequence: six edits
/// compounding on one composition, the engine re-reading after each, and history that lands
/// exactly where it started. That is the thing a person actually does, and the thing that a test
/// per verb cannot show.
#[test]
fn a_whole_sitting_of_gestures_lands_and_undoes_to_the_byte() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(work.path().join("comps")).unwrap();
    let comp = work.path().join("comps/captions.lua");
    std::fs::copy(root.join("comps/cases/captions.lua"), &comp).unwrap();
    let original = std::fs::read_to_string(&comp).unwrap();

    // The case reads its fonts from the checkout, so that is the renderer's working directory.
    let engine = match Engine::start(&comp, &root, &serve_dir("sitting")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let mut outline = engine.outline(doc.hash()).unwrap();

    // What the composition holds, found by what it is rather than by an id spelled into a test.
    let label = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["label"].as_str() == Some("35 CAPTIONS"))
        .map(|n| n["id"].as_str().unwrap().to_string())
        .expect("the corner label");
    let track_on = |outline: &serde_json::Value, prop: &str| -> String {
        outline["tracks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["prop"] == prop)
            .map(|t| t["node"].as_str().unwrap().to_string())
            .unwrap_or_else(|| panic!("nothing moves its {prop}"))
    };
    let bar = track_on(&outline, "w");
    let speaker = track_on(&outline, "opacity");
    let spoken = outline["cues"][0]["node"].as_str().unwrap().to_string();

    // Six gestures, each the one a particular handle in the window makes.
    let sitting: Vec<(&str, Gesture)> = vec![
        ("dragging it in the preview", Gesture::Move { node: label.clone(), x: 100.0, y: 60.0 }),
        (
            "typing a size in the inspector",
            Gesture::SetValue {
                node: label.clone(),
                key: "size".into(),
                value: serde_json::json!(26),
            },
        ),
        (
            "picking a different curve",
            Gesture::Curve { node: bar.clone(), ease: "linear".into(), occurrence: 0 },
        ),
        (
            // Shorter, not longer: this composition's script already runs to its own end, and its
            // length is fixed. Dragging the other way is the refusal checked below.
            "dragging a movement's right edge",
            Gesture::Lengthen { node: bar.clone(), seconds: 0.25, occurrence: 0 },
        ),
        (
            "retyping a spoken line",
            Gesture::Line {
                node: spoken.clone(),
                index: 1,
                t0: None,
                t1: None,
                text: Some("Let it land.".into()),
            },
        ),
        (
            "pinning a value by hand",
            Gesture::Pin {
                node: speaker.clone(),
                t: 2.0,
                key: "opacity".into(),
                value: serde_json::json!(0.4),
            },
        ),
    ];

    let ids: Vec<String> = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|n| n["id"].as_str().map(str::to_string))
        .collect();

    for (handle, gesture) in sitting {
        let names = words::names(&outline);
        let nodes = node_refs(&outline);
        let edits = moonsplice_studio_lib::gesture_to_edits(gesture, &outline)
            .unwrap_or_else(|r| panic!("{handle} was refused: {}", r.say(&names)));
        // The same call the window makes: write it, and have the engine read it back.
        let (applied, next) =
            moonsplice_studio_lib::write_and_reload(&mut doc, &engine, &edits, &nodes, &names)
                .unwrap_or_else(|r| panic!("{handle}: {}", r.say(&names)));
        // What the corner of the window says about it is words, not machinery.
        for said in &applied.what {
            for id in &ids {
                assert!(!said.contains(id.as_str()), "`{id}` in: {said}");
            }
            for code in [".lua", "opacity", "expoOut", "{", "="] {
                assert!(!said.contains(code), "`{code}` in: {said}");
            }
        }
        eprintln!("  {handle} -> {}", applied.what.join("; "));
        // An edit is a write, and the engine re-reads rather than being told a delta.
        assert_eq!(std::fs::read_to_string(&comp).unwrap(), doc.text());
        outline = next;
    }

    // Each gesture is there in what the engine now reports.
    let label_props = |outline: &serde_json::Value, id: &str, key: &str| -> f64 {
        outline["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["id"].as_str() == Some(id))
            .and_then(|n| n["props"][key].as_f64())
            .unwrap_or_else(|| panic!("no {key} on that thing"))
    };
    assert_eq!(label_props(&outline, &label, "x"), 100.0);
    assert_eq!(label_props(&outline, &label, "y"), 60.0);
    assert_eq!(label_props(&outline, &label, "size"), 26.0);

    let moved = outline["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["node"].as_str() == Some(&bar) && t["prop"] == "w")
        .expect("the bar still moves");
    assert_eq!(moved["segments"][0]["ease"].as_str(), Some("linear"));
    let (t0, t1) = (
        moved["segments"][0]["t0"].as_f64().unwrap(),
        moved["segments"][0]["t1"].as_f64().unwrap(),
    );
    assert!((t1 - t0 - 0.25).abs() < 1e-6, "the movement is {}s long", t1 - t0);

    assert_eq!(outline["cues"][1]["text"].as_str(), Some("Let it land."));
    assert_eq!(
        outline["cues"][1]["t0"].as_f64(),
        Some(1.45),
        "retyping a line must not retime it"
    );

    let pinned = outline["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|t| t["node"].as_str() == Some(&speaker))
        .flat_map(|t| t["segments"].as_array().unwrap())
        .filter(|s| s["manual"] == true)
        .count();
    assert_eq!(pinned, 1, "the hand-set value is marked as one");

    let after = doc.text().to_string();

    // All the way back. Six edits, six steps -- nothing compounded into a step that cannot be
    // undone on its own.
    for i in 0..6 {
        doc.undo().unwrap_or_else(|e| panic!("undo {i}: {e}"));
    }
    assert_eq!(
        std::fs::read_to_string(&comp).unwrap(),
        original,
        "undo returns the composition byte for byte, which is what keeps its frame hashes valid"
    );
    engine.reload().unwrap();
    let back = engine.outline(doc.hash()).unwrap();
    assert_eq!(back["cues"][1]["text"].as_str(), Some("Let the type land."));
    assert_eq!(
        back["tracks"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|t| t["segments"].as_array().unwrap())
            .filter(|s| s["manual"] == true)
            .count(),
        0,
        "the pin is gone with the undo that removed it"
    );

    // And forward again.
    for i in 0..6 {
        doc.redo().unwrap_or_else(|e| panic!("redo {i}: {e}"));
    }
    assert_eq!(std::fs::read_to_string(&comp).unwrap(), after);
    engine.stop();
}

/// Putting footage in a composition — the gesture an editor exists for.
///
/// It was the hole in the vocabulary: an asset could be dragged out of the left pane and nothing
/// anywhere could take it. This is the whole path, against the real engine: a real clip, a real
/// picture and a real sound land in a real composition, the engine re-reads it, and what comes
/// back has three more things in it than it started with.
#[test]
fn a_thing_from_the_project_goes_into_a_composition() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("empty.lua");
    std::fs::write(
        &comp,
        "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 1280, height = 720, duration = 3, fps = 30,\n  background = \"#0b0d12\",\n\n  scene = function(s)\n  end,\n}\n",
    )
    .unwrap();

    // The project is the checkout here, so the eval suite's own media is what gets placed.
    let engine = match Engine::start(&comp, &root, &serve_dir("place")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let empty = doc.text().to_string();
    let mut outline = engine.outline(doc.hash()).unwrap();
    assert!(
        outline["nodes"].as_array().is_some_and(|n| n.is_empty()),
        "it starts with nothing in it"
    );

    let placings: Vec<(&str, Vec<(String, String)>, &str)> = vec![
        (
            "video",
            vec![
                ("src".into(), "\"comps/assets/earth_night.webm\"".into()),
                ("from".into(), "0".into()),
            ],
            "Earth night",
        ),
        (
            "image",
            vec![("src".into(), "\"comps/assets/apollo17.jpg\"".into())],
            "Apollo 17",
        ),
        (
            "audio",
            vec![
                ("src".into(), "\"comps/assets/piano.ogg\"".into()),
                ("at".into(), "0.5".into()),
            ],
            "Piano",
        ),
    ];

    for (kind, fields, what) in placings {
        let names = words::names(&outline);
        let nodes = node_refs(&outline);
        let (applied, next) = moonsplice_studio_lib::write_and_reload(
            &mut doc,
            &engine,
            &[Edit::Place {
                kind: kind.into(),
                fields,
                what: what.into(),
            }],
            &nodes,
            &names,
        )
        .unwrap_or_else(|r| panic!("putting {what} in: {}", r.say(&names)));
        // What it says is the name from the left pane, not a path and not a kind.
        assert_eq!(applied.what, vec![format!("put {what} in")]);
        outline = next;
    }

    let kinds: Vec<&str> = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|n| n["kind"].as_str())
        .collect();
    assert_eq!(kinds, vec!["video", "image", "audio"], "in the order they were put in");

    // The sound is audible from where it was dropped, and the engine measured that rather than
    // the app assuming it.
    let sound = outline["audio"]
        .as_array()
        .and_then(|a| a.first().cloned())
        .expect("the sound is in the mix");
    assert_eq!(sound["at"].as_f64(), Some(0.5));

    // And the composition is still a composition: it renders.
    let (rgba, w, h) = engine.frame(1.0).expect("a frame of what was placed");
    assert_eq!((w, h), (1280, 720));
    assert!(rgba.iter().any(|b| *b != 0), "the frame is not empty");

    // Nothing in what the app says about any of this is a file name.
    let said = serde_json::to_string(&outline).unwrap();
    assert!(!said.contains(".webm"), "a file name reached the app: {said}");
    assert!(!said.contains(".ogg"));

    // And what goes in comes out. The Delete key is `remove`, and taking the three back out
    // leaves the composition the way it was written -- byte for byte, which is the property the
    // whole app rests on.
    let ids: Vec<String> = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["id"].as_str().unwrap().to_string())
        .collect();
    for id in ids.iter().rev() {
        let names = words::names(&outline);
        let nodes = node_refs(&outline);
        let (applied, next) = moonsplice_studio_lib::write_and_reload(
            &mut doc,
            &engine,
            &[Edit::Remove { node: id.clone() }],
            &nodes,
            &names,
        )
        .unwrap_or_else(|r| panic!("taking one out: {}", r.say(&names)));
        eprintln!("  {}", applied.what.join("; "));
        outline = next;
    }
    assert!(
        outline["nodes"].as_array().is_some_and(|n| n.is_empty()),
        "everything came out"
    );
    assert_eq!(
        doc.text(),
        empty,
        "what is left is byte for byte what was there before anything went in"
    );

    // Undo takes each one back out, in order.
    for _ in 0..6 {
        doc.undo().unwrap();
    }
    assert!(doc.text().contains("scene = function(s)\n  end,"), "back to empty:\n{}", doc.text());
    engine.stop();
}
