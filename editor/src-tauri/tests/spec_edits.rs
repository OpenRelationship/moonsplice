//! The desktop epic's editing scenarios: manual edits, refusals in words, edits as writes (see
//! spec.rs for how the names are used).

use std::collections::HashMap;
use std::path::PathBuf;

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::lower::{self, Edit, EditRefusal};
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::{gesture_to_edits, words, Gesture};

mod spec_common;
use spec_common::*;

/// Scenario: a manual edit reads differently from a relational one
#[test]
fn a_manual_edit_reads_differently_from_a_relational_one() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let work = Work::with(&root, &[("hero", "captions")]);
    let comp = work.path().join("comps/hero.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("manual")) {
        Ok(e) => e,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let before = engine.outline(doc.hash()).unwrap();
    let nodes = node_refs(&before);

    // Given a parameter driven by a tween: the bar's width.
    let driven = before["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["prop"] == "w")
        .expect("the bar's width is tweened");
    assert_eq!(driven["segments"][0]["manual"], false);
    assert_eq!(driven["segments"][0]["kind"], "tween");
    let node = driven["node"].as_str().unwrap().to_string();

    // When a value is pinned by hand at a time.
    doc.apply(
        &[Edit::PinProp {
            node: node.clone(),
            key: "opacity".into(),
            t: 1.2,
            value: serde_json::json!(0.4),
            covered: false,
        }],
        Some(&nodes),
        &words::names(&before),
    )
    .expect("a pin is a verb");
    engine.reload().unwrap();
    let after = engine.outline(doc.hash()).unwrap();
    engine.stop();

    // Then the timeline marks that value as manual -- and the tween is still not.
    let pinned = after["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|t| {
            t["segments"]
                .as_array()
                .unwrap()
                .iter()
                .map(move |s| (t["prop"].as_str().unwrap_or(""), s))
        })
        .find(|(prop, s)| *prop == "opacity" && s["manual"] == true)
        .map(|(_, s)| s.clone())
        .expect("the pinned value is marked manual");
    assert_eq!(pinned["kind"], "pin", "and it is a pin, not a tween");
    assert!((pinned["t0"].as_f64().unwrap() - 1.2).abs() < 1e-6);

    let still_relational = after["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["prop"] == "w")
        .unwrap();
    assert_eq!(still_relational["segments"][0]["manual"], false);
    eprintln!("  a pin is manual; the tween beside it is not");
}

/// Scenario: no code is shown
#[test]
fn no_code_is_shown() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let comp = root.join("comps/cases/captions.lua");
    let source = std::fs::read_to_string(&comp).unwrap();
    let engine = match Engine::start(&comp, &root, &serve_dir("nocode")) {
        Ok(e) => e,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let outline = engine.outline("h").unwrap();
    let at = engine.at(1.0).unwrap();
    engine.stop();

    // Nothing the app is handed carries the source, a path, or an extension.
    let sent = serde_json::to_string(&outline).unwrap();
    for line in source.lines().map(str::trim).filter(|l| l.len() > 12) {
        assert!(
            !sent.contains(line),
            "the outline carried a line of the source: {line}"
        );
    }
    for code in [".lua", "s:rect", "s:text", "e.comp", "require(", "function"] {
        assert!(!sent.contains(code), "the outline carried `{code}`");
    }

    // And what the app says out loud carries no ids or keys either.
    let said = moonsplice_studio_lib::describe(&outline);
    let now = moonsplice_studio_lib::describe_instant(&at);
    for text in [&said, &now] {
        for code in [".lua", "rect", "expoOut", "opacity", "{", "}"] {
            assert!(!text.contains(code), "`{code}` in:\n{text}");
        }
    }
    eprintln!("  what the app shows of a Lua composition:\n{said}");
}

/// Scenario: a refusal is said in words, not in ids
///
/// The corner of the window is where a refusal is read, and every other sentence that reaches it
/// has already been through `words`. These had not: `Display` quotes the node id and the property
/// key, which is code on screen in the one app that is not allowed to show any.
#[test]
fn a_refusal_is_said_in_words_not_in_ids() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let comp = root.join("comps/cases/motion.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("refusal")) {
        Ok(e) => e,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let outline = engine.outline("h").unwrap();
    engine.stop();
    let names = words::names(&outline);
    let ids: Vec<String> = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|n| n["id"].as_str().map(str::to_string))
        .collect();
    assert!(!ids.is_empty(), "the composition has things in it");

    // A thing whose position a movement already decides: dragging it is refused, and that is the
    // refusal a person is most likely to meet.
    let moved = outline["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["prop"] == "x" || t["prop"] == "y")
        .map(|t| t["node"].as_str().unwrap().to_string())
        .expect("motion.lua moves something");

    let source = std::fs::read_to_string(&comp).unwrap();
    let nodes = node_refs(&outline);
    let first = ids[0].clone();

    // Each of these is a refusal the UI can actually provoke, collected as the app would get it.
    let mut refusals: Vec<EditRefusal> = Vec::new();
    for g in [
        Gesture::Move { node: moved.clone(), x: 10.0, y: 10.0 },
        Gesture::MoveStart { node: first.clone(), t: 0.0, occurrence: 99 },
        // A lane dropped back on itself: the drag the timeline makes easiest to do by accident.
        Gesture::Restack {
            node: first.clone(),
            over: Some(first.clone()),
        },
    ] {
        let what = format!("{g:?}");
        refusals.push(gesture_to_edits(g, &outline).expect_err(&what));
    }
    // And the two the lowering itself refuses: a property nothing has, and a movement that is
    // not there.
    refusals.push(
        lower::set_prop(&source, &first, "z", "-1", Some(&nodes))
            .expect_err("nothing has a z"),
    );
    refusals.push(
        lower::set_ease(&source, &first, "linear", 99, Some(&nodes))
            .expect_err("there is no hundredth movement"),
    );
    refusals.push(
        lower::set_ease(&source, &moved, "zoomy", 0, Some(&nodes))
            .expect_err("there is no curve called that"),
    );
    refusals.push(
        lower::set_cue(&source, &first, 9, None, None, Some("x"), Some(&nodes))
            .expect_err("there is no tenth line"),
    );
    refusals.push(
        lower::lower(&source, &[Edit::SetProp {
            node: "nothing-like-this".into(),
            key: "x".into(),
            value: serde_json::json!(1),
        }], Some(&nodes))
        .expect_err("there is no such thing"),
    );

    for r in &refusals {
        let said = r.say(&names);
        for id in &ids {
            assert!(
                !said.contains(id.as_str()),
                "a refusal named a node id ({id}): {said}"
            );
        }
        for code in ["\"", "_", "opacity", "expoOut", "()", "#"] {
            assert!(!said.contains(code), "`{code}` reads like code in: {said}");
        }
        eprintln!("  {said}");
    }

    // The thing whose drag was refused is named the way the timeline names it, so the person can
    // tell which thing the app is talking about.
    let dragged = refusals[0].say(&names);
    let its_name = words::name_of(&names, &moved);
    assert!(
        dragged.contains(&its_name),
        "the refusal did not say which thing it was about ({its_name}): {dragged}"
    );
}

// -------------------------------------------------- Feature: project sync

/// Scenario: an edit is a write
#[test]
fn an_edit_is_a_write() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let work = Work::with(&root, &[("hero", "captions")]);
    let comp = work.path().join("comps/hero.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("write")) {
        Ok(e) => e,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let outline = engine.outline(doc.hash()).unwrap();
    let nodes = node_refs(&outline);
    let node = nodes
        .iter()
        .find(|n| n.kind == "rect" && n.props.iter().any(|p| p == "w"))
        .expect("a block with a width")
        .id
        .clone();

    // When a parameter is changed in the timeline. There is no save step to call.
    doc.apply(
        &[Edit::SetProp {
            node,
            key: "w".into(),
            value: serde_json::json!(321),
        }],
        Some(&nodes),
        &words::names(&outline),
    )
    .unwrap();
    engine.stop();

    // Then the change is on disk. Read the file back from scratch, not the doc's own copy.
    let on_disk = std::fs::read_to_string(&comp).unwrap();
    assert!(on_disk.contains("w = 321"), "the edit is not on disk");
    assert_eq!(on_disk, doc.text(), "the doc and the disk disagree");
    eprintln!("  changed in the timeline, on disk, with nothing saved");
}

/// Scenario: an unedited comp is unchanged byte for byte
#[test]
fn an_unedited_comp_is_unchanged_byte_for_byte() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let cases: Vec<PathBuf> = std::fs::read_dir(root.join("evals/cases"))
        .unwrap()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("lua"))
        .collect();
    assert!(cases.len() > 20, "expected the eval suite");

    for comp in &cases {
        let original = std::fs::read_to_string(comp).unwrap();
        // Opened and closed with no edit: the source doc is the only thing that writes.
        let mut doc = SourceDoc::open(comp).unwrap();
        doc.apply(&[], None, &HashMap::new()).unwrap();
        assert_eq!(
            std::fs::read_to_string(comp).unwrap(),
            original,
            "{} changed with no edits",
            comp.display()
        );
        // And the lowering itself is the identity with an empty edit list.
        assert_eq!(lower::lower(&original, &[], None).unwrap(), original);
    }

    // "And its frame hashes still match the recorded goldens" -- that is `moonsplice golden compare`,
    // which is a separate tool because it takes minutes. What is checkable here is the property
    // it rests on: the bytes did not move, so no recorded hash can have.
    eprintln!(
        "  {} compositions opened and closed, all byte-identical",
        cases.len()
    );
}
