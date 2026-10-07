//! The desktop epic's project-sync scenarios: one representation, whoever edits it (see spec.rs
//! for how the names are used).

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::lower::{self, Edit, EditRefusal, NodeRef};
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::{gesture_to_edits, words, Gesture};

mod spec_common;
use spec_common::*;

/// Scenario: a change from the agent reaches the timeline
#[test]
fn a_change_from_the_agent_reaches_the_timeline() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let work = Work::with(&root, &[("hero", "captions")]);
    let comp = work.path().join("comps/hero.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("agent-tl")) {
        Ok(e) => e,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let before = engine.outline(doc.hash()).unwrap();
    let nodes = node_refs(&before);
    let names = words::names(&before);

    let track_of = |o: &serde_json::Value| -> f64 {
        o["tracks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["prop"] == "w")
            .map(|t| t["segments"][0]["t1"].as_f64().unwrap_or(0.0))
            .unwrap_or(0.0)
    };
    let was = track_of(&before);

    // The agent's change goes down the same path a drag does, and names the thing in words.
    let node = before["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["prop"] == "w")
        .unwrap()["node"]
        .as_str()
        .unwrap()
        .to_string();
    doc.apply(
        // Shorter, not longer. `duration` is static and this composition's script already
        // fills it exactly, so lengthening a movement is refused -- a good refusal, and not
        // what this scenario is about.
        &[Edit::SetTweenDuration {
            node: words::name_of(&names, &node),
            seconds: 0.25,
            occurrence: 0,
        }],
        Some(&nodes),
        &names,
    )
    .expect("the agent asked by name");

    // Then the timeline shows it without a reload: the outline is re-read from the engine, and
    // the UI holds nothing to patch.
    engine.reload().unwrap();
    let after = engine.outline(doc.hash()).unwrap();
    engine.stop();
    let now = track_of(&after);
    assert_ne!(was, now, "the movement did not change length");
    assert!((now - (0.15 + 0.25)).abs() < 1e-6, "ends at {now}");
    assert_ne!(
        before["nodes"], serde_json::Value::Null,
        "the outline is what the timeline draws from"
    );
    eprintln!("  the movement now ends at {now}s, straight from the engine");
}

/// Scenario: an external edit is picked up
#[test]
fn an_external_edit_is_picked_up() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let work = Work::with(&root, &[("hero", "captions")]);
    let comp = work.path().join("comps/hero.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("external")) {
        Ok(e) => e,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let was = doc.hash().to_string();

    // A text editor outside the app, writing the file behind us.
    let edited = doc.text().replace("duration = 3.6", "duration = 5.0");
    assert_ne!(edited, doc.text(), "the fixture changed shape");
    std::fs::write(&comp, &edited).unwrap();

    // Then the app reparses it, and no merge is required: it has no competing copy to merge.
    let adopted = doc
        .adopt_from_disk()
        .expect("the file reads")
        .expect("the bytes differ, so there is something to adopt");
    assert_eq!(adopted.what, vec!["changed outside the app".to_string()]);
    assert_ne!(doc.hash(), was, "the hash moved, so every frame url does too");
    assert!(doc.text().contains("duration = 5.0"));

    engine.reload().unwrap();
    let outline = engine.outline(doc.hash()).unwrap();
    engine.stop();
    assert!(
        (outline["comp"]["duration"].as_f64().unwrap() - 5.0).abs() < 1e-6,
        "the engine did not see the outside edit"
    );

    // And adopting our own bytes is not an event, which is what makes the watcher safe.
    assert!(
        doc.adopt_from_disk().unwrap().is_none(),
        "the app would loop on its own writes"
    );
    eprintln!("  an outside edit adopted, and our own writes ignored");
}

/// Scenario: an agent edit undoes as one step
#[test]
fn an_agent_edit_undoes_as_one_step() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    // Twelve things, each written out, because the scenario says twelve nodes and a composition
    // that builds them in a loop would be refused by name rather than changed -- which is a
    // different rule, tested elsewhere.
    let dir = tempfile::tempdir().unwrap();
    let comp = dir.path().join("twelve.lua");
    let mut src = String::from(
        "local e = require(\"moonsplice\")\n\nreturn e.comp {\n  \
         width = 640, height = 360, duration = 2, fps = 30,\n  background = \"#101010\",\n\n  \
         scene = function(s)\n",
    );
    for i in 0..12 {
        src.push_str(&format!(
            "    s:rect {{ x = {}, y = {}, w = 40, h = 40, opacity = 1 }}\n",
            20 + i * 48,
            40 + (i % 3) * 90
        ));
    }
    src.push_str("  end,\n}\n");
    std::fs::write(&comp, &src).unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("undo12")) {
        Ok(e) => e,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let original = doc.text().to_string();
    let outline = engine.outline(doc.hash()).unwrap();
    let nodes = node_refs(&outline);
    assert_eq!(nodes.len(), 12, "the fixture should have twelve things");

    // The agent changes all twelve in one turn: one `change` call, one list of edits.
    let edits: Vec<Edit> = nodes
        .iter()
        .map(|n| Edit::SetProp {
            node: n.id.clone(),
            key: "opacity".into(),
            value: serde_json::json!(0.5),
        })
        .collect();
    let applied = doc
        .apply(&edits, Some(&nodes), &words::names(&outline))
        .expect("twelve edits, one call");
    assert_eq!(applied.what.len(), 12, "twelve things changed");
    assert_eq!(doc.undo_depth(), 1, "and it is one step, not twelve");
    assert_eq!(
        doc.text().matches("opacity = 0.5").count(),
        12,
        "not every one landed"
    );

    // When undo is invoked once, all twelve are reverted.
    doc.undo().expect("one undo");
    assert_eq!(doc.text(), original, "undo did not revert all twelve");
    assert_eq!(
        std::fs::read_to_string(&comp).unwrap(),
        original,
        "the file still holds the changes"
    );
    assert_eq!(doc.undo_depth(), 0);
    assert_eq!(doc.redo_depth(), 1, "and it can be put back");

    // The engine agrees, which is what makes it an undo and not a text trick.
    engine.reload().unwrap();
    let after = engine.outline(doc.hash()).unwrap();
    engine.stop();
    let faded = after["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|n| n["props"]["opacity"].as_f64() == Some(0.5))
        .count();
    assert_eq!(faded, 0, "the engine still sees {faded} faded things");
    eprintln!("  twelve changes, one undo step, byte-identical afterwards");
}

/// Scenario: a gesture with no lowering verb is refused
#[test]
fn a_gesture_with_no_lowering_verb_is_refused() {
    // Every gesture the UI can make has a verb now -- reordering the stack and the left edge of
    // a movement were the last two without one, and they are `Edit::Restack` and
    // `Edit::MoveTweenStart`. The rule this scenario is about did not go away with them: it is
    // that a gesture is either lowered into the source or refused in a sentence, and there is
    // never a third path where the app keeps the change somewhere of its own.
    //
    // So what is demonstrated is the refusals that remain, and they are the interesting ones:
    // they come from the composition rather than from a missing word.
    let outline = serde_json::json!({
        "nodes": [
            { "id": "rect2", "kind": "rect", "line": 3, "props": { "x": 80 } },
            { "id": "tts3", "kind": "tts", "line": 4, "label": "Narration" }
        ],
        "tracks": [{
            "node": "rect2", "prop": "x",
            "segments": [{ "kind": "tween", "t0": 0.2, "t1": 0.8, "from": 0, "to": 80,
                           "ease": "sineOut", "manual": false }]
        }]
    });
    for g in [
        // Dragged in the preview, but a movement already decides where it is.
        Gesture::Move { node: "rect2".into(), x: 10.0, y: 10.0 },
        // Dragged along the track, but it has no length of its own to take hold of.
        Gesture::Slide { node: "rect2".into(), t: 1.0 },
        // Cut in two, same reason.
        Gesture::Split { node: "rect2".into(), t: 1.0 },
        // Dragged up the stack, but sound has no front or back.
        Gesture::Restack { node: "tts3".into(), over: Some("rect2".into()) },
        // The left edge of a movement that is not there.
        Gesture::MoveStart { node: "rect2".into(), t: 1.0, occurrence: 4 },
    ] {
        let name = format!("{g:?}");
        let refused = gesture_to_edits(g, &outline).expect_err("it must not be translated");
        let said = refused.say(&words::names(&outline));
        assert!(!said.is_empty());
        assert!(!said.contains('_'), "the refusal reads like code: {said}");
        assert!(!said.contains("rect2") && !said.contains("tts3"), "an id reached a person: {said}");
        eprintln!("  {name} -> {said}");
    }

    // And a gesture that does have a verb still goes through, so the refusal is about what this
    // composition can say and not about everything being refused.
    let ok = gesture_to_edits(
        Gesture::SetValue {
            node: "rect2".into(),
            key: "x".into(),
            value: serde_json::json!(96),
        },
        &outline,
    )
    .expect("setting a value is a verb");
    assert_eq!(ok.len(), 1);

    // And a property nothing has is refused rather than written into the source, which is the
    // same rule one level down: no second edit path, not even an inert one.
    let src = std::fs::read_to_string(
        root().map(|r| r.join("comps/cases/captions.lua")).unwrap_or_default(),
    )
    .unwrap_or_default();
    if src.is_empty() {
        return;
    }
    let nodes = vec![NodeRef {
        id: "rect4".into(),
        kind: "rect".into(),
        line: None,
        props: vec!["x".into(), "y".into(), "w".into(), "h".into()],
    }];
    assert!(matches!(
        lower::set_prop(&src, "rect4", "z", "-1", Some(&nodes)),
        Err(EditRefusal::NoProp { .. })
    ));
}
