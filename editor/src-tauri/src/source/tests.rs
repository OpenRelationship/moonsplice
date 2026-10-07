/// These tests are about the bytes, not the wording, so they name nothing.
fn no_names() -> std::collections::HashMap<String, String> {
    std::collections::HashMap::new()
}

use super::*;
use tempfile::tempdir;

const SRC: &str = "local e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 1280, height = 720, duration = 2, fps = 30,\n  scene = function(s)\n    local bar = s:rect { x = 10, y = 20, w = 4, h = 4 }\n    s:script(function(t)\n      t:tween(bar, 0.4, { w = 64 }, \"expoOut\")\n    end)\n  end,\n}\n";

fn doc() -> (tempfile::TempDir, SourceDoc) {
    let dir = tempdir().unwrap();
    let p = dir.path().join("hero.lua");
    std::fs::write(&p, SRC).unwrap();
    let d = SourceDoc::open(&p).unwrap();
    (dir, d)
}

#[test]
fn opening_and_closing_with_no_edit_leaves_the_bytes_alone() {
    let (dir, d) = doc();
    drop(d);
    assert_eq!(std::fs::read_to_string(dir.path().join("hero.lua")).unwrap(), SRC);
}

#[test]
fn an_edit_is_a_write_with_no_save_step() {
    let (dir, mut d) = doc();
    d.apply(
        &[Edit::SetProp {
            node: "rect1".into(),
            key: "x".into(),
            value: serde_json::json!(40),
        }],
        None,
        &no_names(),
    )
    .unwrap();
    let on_disk = std::fs::read_to_string(dir.path().join("hero.lua")).unwrap();
    assert!(on_disk.contains("x = 40,"));
    assert_eq!(on_disk, d.text());
}

#[test]
fn twelve_changes_in_one_turn_undo_as_one_step() {
    let (_dir, mut d) = doc();
    let edits: Vec<Edit> = (0..12)
        .map(|i| Edit::SetProp {
            node: "rect1".into(),
            key: "x".into(),
            value: serde_json::json!(i),
        })
        .collect();
    let applied = d.apply(&edits, None, &no_names()).unwrap();
    assert_eq!(applied.undo_depth, 1);
    assert_eq!(applied.what.len(), 12);
    d.undo().unwrap();
    assert_eq!(d.text(), SRC);
}

#[test]
fn a_refusal_leaves_the_file_untouched() {
    let (dir, mut d) = doc();
    let err = d
        .apply(
            &[
                Edit::SetProp {
                    node: "rect1".into(),
                    key: "x".into(),
                    value: serde_json::json!(99),
                },
                Edit::SetProp {
                    node: "ghost".into(),
                    key: "x".into(),
                    value: serde_json::json!(1),
                },
            ],
            None,
            &no_names(),
        )
        .unwrap_err();
    assert!(matches!(err, SourceError::Refused(_)));
    assert_eq!(std::fs::read_to_string(dir.path().join("hero.lua")).unwrap(), SRC);
    assert_eq!(d.undo_depth(), 0);
}

#[test]
fn undo_then_redo_returns_the_same_bytes() {
    let (_dir, mut d) = doc();
    d.apply(
        &[Edit::SetEase {
            node: "rect1".into(),
            ease: "sineOut".into(),
            occurrence: 0,
        }],
        None,
        &no_names(),
    )
    .unwrap();
    let after = d.text().to_string();
    d.undo().unwrap();
    assert_eq!(d.text(), SRC);
    d.redo().unwrap();
    assert_eq!(d.text(), after);
}

#[test]
fn the_hash_changes_with_the_bytes_and_nothing_else() {
    let (_dir, mut d) = doc();
    let before = d.hash().to_string();
    d.apply(&[], None, &no_names()).unwrap();
    assert_eq!(d.hash(), before, "an empty edit is not a change");
    d.apply(
        &[Edit::SetProp {
            node: "rect1".into(),
            key: "y".into(),
            value: serde_json::json!(21),
        }],
        None,
        &no_names(),
    )
    .unwrap();
    assert_ne!(d.hash(), before);
}

#[test]
fn an_outside_edit_is_adopted_without_a_merge() {
    let (dir, mut d) = doc();
    let p = dir.path().join("hero.lua");
    std::fs::write(&p, SRC.replace("y = 20", "y = 200")).unwrap();
    let applied = d.adopt_from_disk().unwrap().expect("a change");
    assert!(d.text().contains("y = 200"));
    assert_eq!(applied.undo_depth, 1);
    // and firing again on the same bytes is a no-op, so our own writes are safe
    assert!(d.adopt_from_disk().unwrap().is_none());
}

#[test]
fn the_undo_label_reads_like_a_person_wrote_it() {
    let (_dir, mut d) = doc();
    d.apply(
        &[Edit::SetTweenDuration {
            node: "rect1".into(),
            seconds: 1.5,
            occurrence: 0,
        }],
        None,
        &no_names(),
    )
    .unwrap();
    // With nothing named it still says something sayable rather than an id.
    assert_eq!(d.undo_label(), Some("made that thing's move 1.5s long"));

    // And given the outline, it uses what the timeline calls the thing.
    let (_dir2, mut e) = doc();
    let named = crate::words::names(&serde_json::json!({
        "nodes": [{ "id": "rect1", "kind": "rect", "label": null }]
    }));
    e.apply(
        &[Edit::SetTweenDuration {
            node: "rect1".into(),
            seconds: 1.5,
            occurrence: 0,
        }],
        None,
        &named,
    )
    .unwrap();
    let label = e.undo_label().unwrap().to_string();
    assert_eq!(label, "made Block's move 1.5s long");
    assert!(!label.contains("rect1"), "the label leaked a node id: {label}");
}

/// A name is as good as an id, whoever is asking. The agent only ever sees names; if the
/// resolution lives in the caller instead of here, one caller forgets and the agent is told
/// the thing it can plainly see does not exist.
#[test]
fn a_thing_can_be_named_the_way_the_app_names_it() {
    let (_dir, mut d) = doc();
    let named = crate::words::names(&serde_json::json!({
        "nodes": [{ "id": "rect1", "kind": "rect", "label": null }]
    }));
    let by_name = d.apply(
        &[Edit::SetTweenDuration {
            node: "Block".into(),
            seconds: 0.8,
            occurrence: 0,
        }],
        None,
        &named,
    );
    assert!(by_name.is_ok(), "a name was refused: {by_name:?}");

    // And a name for nothing is still refused, quoting what was asked rather than a guess.
    let nonsense = d.apply(
        &[Edit::SetTweenDuration {
            node: "The Widget".into(),
            seconds: 0.8,
            occurrence: 0,
        }],
        None,
        &named,
    );
    let why = format!("{:?}", nonsense.unwrap_err());
    assert!(why.contains("The Widget"), "{why}");
}

/// The rule, over every verb: nothing the app says about a change contains a node id, a
/// property key or an easing name. This is the brief -- the person using this app does not
/// want to see code -- and the undo label is where code leaks first.
#[test]
fn no_verb_says_anything_that_looks_like_code() {
    let named = crate::words::names(&serde_json::json!({
        "nodes": [
            { "id": "rect1", "kind": "rect", "label": null },
            { "id": "text2", "kind": "text", "label": "EDITOR" },
            { "id": "cap3", "kind": "captions", "label": "Hold the cut." }
        ]
    }));
    let edits = vec![
        Edit::SetProp {
            node: "rect1".into(),
            key: "opacity".into(),
            value: serde_json::json!(0.5),
        },
        Edit::SetEase {
            node: "text2".into(),
            ease: "expoOut".into(),
            occurrence: 0,
        },
        Edit::SetTweenDuration {
            node: "rect1".into(),
            seconds: 0.8,
            occurrence: 0,
        },
        Edit::SetCue {
            node: "cap3".into(),
            index: 1,
            t0: None,
            t1: None,
            text: Some("Let it land.".into()),
        },
        Edit::PinProp {
            node: "text2".into(),
            key: "x".into(),
            t: 1.0,
            value: serde_json::json!(96),
            covered: false,
        },
    ];
    for edit in &edits {
        let said = edit.describe(&named);
        for code in ["rect1", "text2", "cap3", "opacity", "expoOut", " x "] {
            assert!(
                !said.contains(code),
                "`{said}` contains `{code}`, which is code"
            );
        }
        eprintln!("  {said}");
    }
}
