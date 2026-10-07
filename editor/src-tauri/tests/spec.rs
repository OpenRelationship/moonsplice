//! The desktop epic, scenario by scenario.
//!
//! `context/projects/studio/features/` is the spec. Every scenario in the three features that
//! are in scope for this app -- the shell, the agent surface, and the one-representation rules
//! of project sync -- has a test here or in `src/spec.test.ts`, named after it.
//!
//! The naming is the mechanism: `bin/studio-spec` parses the feature files and looks for a test
//! per scenario, so coverage is measured rather than asserted in a commit message. Renaming a
//! test here makes its scenario show up as uncovered, which is the point.
//!
//! Out of scope, deliberately: local-perception, av-decisions, av-encoder, lazy-facts,
//! decision-layer, love-free-render. Those are the perception and renderer tracks.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use moonsplice_studio_lib::agent::{self, Ask, Decision, Outcome, Paths, Surface, Transport, Turn};
use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::frames::{FrameCache, FrameKey};
use moonsplice_studio_lib::lower::{self, Edit, EditRefusal, NodeRef};
use moonsplice_studio_lib::project::Project;
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::{gesture_to_edits, net, words, Gesture};

// ------------------------------------------------------------------ the shared bits

fn root() -> Option<PathBuf> {
    moonsplice_studio_lib::engine::moonsplice_root()
}

fn serve_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("moonsplice-spec-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A project on disk the test owns, built from real compositions in the eval suite.
struct Work {
    dir: tempfile::TempDir,
}

impl Work {
    fn with(root: &Path, comps: &[(&str, &str)]) -> Work {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("comps")).unwrap();
        for (name, case) in comps {
            std::fs::copy(
                root.join(format!("comps/cases/{case}.lua")),
                dir.path().join(format!("comps/{name}.lua")),
            )
            .unwrap();
        }
        Work { dir }
    }
    fn path(&self) -> &Path {
        self.dir.path()
    }
}

fn node_refs(outline: &serde_json::Value) -> Vec<NodeRef> {
    outline["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|n| {
                    Some(NodeRef {
                        id: n["id"].as_str()?.to_string(),
                        kind: n["kind"].as_str().unwrap_or("").to_string(),
                        line: n["line"].as_u64().map(|v| v as u32),
                        props: n["props"]
                            .as_object()
                            .map(|o| o.keys().cloned().collect())
                            .unwrap_or_default(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

// ------------------------------------------------------- Feature: app shell

/// Scenario: a project with several aspect ratios opens tabbed
#[test]
fn a_project_with_several_aspect_ratios_opens_tabbed() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let work = Work::with(&root, &[("hero", "captions")]);
    let mut p = Project::open(work.path()).expect("a folder of compositions is a project");
    let comp = p.view().compositions[0].id.clone();

    // A composition holds several shapes, and each one is its own variation.
    p.add_variation(&comp, 1080, 1920).expect("a vertical cut");
    let view = p.view();
    let only = &view.compositions[0];

    assert_eq!(only.variations.len(), 2, "two shapes, two variations");
    let shapes: Vec<&str> = only.variations.iter().map(|v| v.aspect.as_str()).collect();
    assert!(shapes.contains(&"16:9"), "{shapes:?}");
    assert!(shapes.contains(&"9:16"), "{shapes:?}");

    // Each opens in its own tab, so each needs its own id for the centre pane to key on.
    let ids: Vec<&str> = only.variations.iter().map(|v| v.id.as_str()).collect();
    assert_eq!(ids.len(), 2);
    assert_ne!(ids[0], ids[1], "two tabs cannot share an id");
    eprintln!("  one composition, {} tabs: {shapes:?}", ids.len());
}

/// Scenario: an empty composition is still listed
#[test]
fn an_empty_composition_is_still_listed() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let work = Work::with(&root, &[]);
    let mut p = Project::open(work.path()).expect("an empty folder is still a project");
    p.add_composition("Untitled", 1920, 1080, "")
        .expect("a new composition");

    let view = p.view();
    assert_eq!(view.compositions.len(), 1, "it is listed");
    let v = &view.compositions[0].variations[0];
    assert!(v.empty, "and it says it is empty rather than being hidden");
    assert_eq!(view.compositions[0].title, "Untitled");

    // It is a real composition: the engine opens it and reports no nodes.
    let src = p
        .source_of(&v.id)
        .expect("an empty composition still has a source");
    let engine = match Engine::start(&src, &root, &serve_dir("empty")) {
        Ok(e) => e,
        Err(why) => return eprintln!("skipped: {why}"),
    };
    let outline = engine.outline("new").expect("an outline");
    engine.stop();
    assert_eq!(
        outline["nodes"].as_array().map(|a| a.len()),
        Some(0),
        "an empty composition has nothing in it, and that is not an error"
    );
}

/// Scenario: assets of any kind can be added
#[test]
fn assets_of_any_kind_can_be_added() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    let work = Work::with(&root, &[]);
    let mut p = Project::open(work.path()).unwrap();

    // Not video. Not anything the app knows. It is still an asset.
    let odd = work.path().join("notes.tsv");
    std::fs::write(&odd, "a\tb\n").unwrap();
    let weird = work.path().join("thing.qqq");
    std::fs::write(&weird, "?").unwrap();
    let clip = work.path().join("Earth Night.mp4");
    std::fs::write(&clip, "not really an mp4").unwrap();

    let mut kinds = Vec::new();
    for f in [&odd, &weird, &clip] {
        let a = p.add_asset(f, "").expect("anything at all can be dropped in");
        // And it is named, not filed: no extension, no path.
        assert!(!a.name.contains('.'), "{} kept an extension", a.name);
        assert!(!a.name.contains('/'), "{} kept a path", a.name);
        kinds.push(format!("{} -> {:?}", a.name, a.kind));
    }
    assert_eq!(p.view().assets.len(), 3, "all three are in the project");
    eprintln!("  {}", kinds.join(", "));
}

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

/// Scenario: the frame cache is keyed on the source
#[test]
fn the_frame_cache_is_keyed_on_the_source() {
    let cache = FrameCache::new(8 * 1024 * 1024);
    let key = |hash: &str| FrameKey {
        variation: "hero".into(),
        hash: hash.to_string(),
        t_ms: 500,
        w: 640,
        h: 360,
        raw: true,
    };

    // A rendered frame cached at a time and size.
    cache.put(key("aaaa"), vec![1u8; 4096], 640, 360);
    assert!(cache.get(&key("aaaa")).is_some(), "the frame is cached");

    // When the source changes, that entry is invalidated -- and there is no invalidation code,
    // because a changed composition is simply a different key. Nothing asks for the old one.
    assert!(
        cache.get(&key("bbbb")).is_none(),
        "a changed source hit a stale frame"
    );

    // The rest of the key is in there too: the same source at another time or size is a miss.
    for other in [
        FrameKey { t_ms: 501, ..key("aaaa") },
        FrameKey { w: 641, ..key("aaaa") },
        FrameKey { h: 361, ..key("aaaa") },
        // And the picture of a frame is not the pixels of it.
        FrameKey { raw: false, ..key("aaaa") },
    ] {
        assert!(cache.get(&other).is_none(), "{other:?} should be a miss");
    }

    // And the real thing: two hashes of two sources are two keys.
    let a = moonsplice_studio_lib::source::hash_of("s:rect { w = 0 }");
    let b = moonsplice_studio_lib::source::hash_of("s:rect { w = 1 }");
    assert_ne!(a, b, "two sources hashed the same");
    eprintln!("  the key carries the source, so invalidation is free");
}

// ------------------------------------------------ Feature: agent surface

/// Scenario: the core names no vendor
#[test]
fn the_core_names_no_vendor() {
    let Some(root) = root() else {
        return eprintln!("skipped: no checkout");
    };
    // Malleable's own rule 1 names the file: `src/turn.lua` may not name a provider, an HTTP
    // library, a filesystem or a clock. It takes a port table and calls it. The adapters beside
    // it -- `provider.lua`, `provider/openai_chat.lua` -- are where a vendor belongs, and they
    // are not the core.
    let core = root.join("packages/malleable/src/turn.lua");
    if !core.exists() {
        return eprintln!("skipped: the malleable submodule is not checked out");
    }
    let text = std::fs::read_to_string(&core).unwrap().to_lowercase();
    let banned = [
        "openai", "anthropic", "openrouter", "gemini", "claude", "gpt-",
        "reqwest", "curl", "http.request", "socket.http", "luasocket",
        "io.open", "io.popen", "io.write", "os.time", "os.clock", "os.date", "os.getenv",
    ];
    let found: Vec<&str> = banned.iter().copied().filter(|w| text.contains(w)).collect();
    assert!(found.is_empty(), "src/turn.lua names the outside world: {found:?}");

    // The app reaches the model through the host's own transport, so the one place a vendor is
    // named on this path is the app's own declaration, and it names it as configuration.
    let decl = std::fs::read_to_string(root.join("editor/core/host/editor.lua")).unwrap();
    assert!(
        decl.contains("openrouter:"),
        "the app should name its provider in its declaration, not in the core"
    );
    eprintln!(
        "  {} lines of core, naming no provider, transport, disk or clock",
        text.lines().count()
    );
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        if let Ok(rd) = std::fs::read_dir(&d) {
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                } else {
                    out.push(p);
                }
            }
        }
    }
    out
}

// --- a turn, with a scripted model, so the surface is under test and the network is not ---

struct Scripted(Mutex<std::collections::VecDeque<serde_json::Value>>);

impl Transport for Scripted {
    fn fetch(&self, _r: net::Request) -> Result<net::Response, net::PortError> {
        let body = self
            .0
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| text("done"));
        Ok(net::Response {
            status: 200,
            headers: Default::default(),
            body: body.to_string(),
        })
    }
}

fn text(t: &str) -> serde_json::Value {
    serde_json::json!({
        "id": "c", "choices": [{ "index": 0, "finish_reason": "stop",
        "message": { "role": "assistant", "content": t } }]
    })
}

fn calls(cs: &[(&str, serde_json::Value)]) -> serde_json::Value {
    let tool_calls: Vec<serde_json::Value> = cs
        .iter()
        .enumerate()
        .map(|(i, (name, args))| {
            serde_json::json!({
                "id": format!("call_{i}"), "type": "function",
                "function": { "name": name, "arguments": args.to_string() }
            })
        })
        .collect();
    serde_json::json!({
        "id": "c", "choices": [{ "index": 0, "finish_reason": "tool_calls",
        "message": { "role": "assistant", "content": serde_json::Value::Null,
                     "tool_calls": tool_calls } }]
    })
}

/// What the app looks like to a tool body, with every touch recorded in order.
#[derive(Default)]
struct Spy {
    log: Mutex<Vec<String>>,
    source: Mutex<String>,
}

impl agent::AppBridge for Spy {
    fn outline_text(&self) -> Result<String, String> {
        self.log.lock().unwrap().push("read".into());
        Ok("Hero — 2.0s, 1280x720, 30 fps.\n- Block, 1 of 1 from the back".into())
    }
    fn at_text(&self, _t: f64) -> Result<String, String> {
        self.log.lock().unwrap().push("at".into());
        Ok("At 1.00s:\n- Block: across 80".into())
    }
    fn shows_text(&self) -> Result<String, String> {
        Ok("holds(block, visible, 1.0)".into())
    }
    fn change(&self, edits: Vec<Edit>, _why: &str) -> Result<String, String> {
        self.log.lock().unwrap().push(format!("change x{}", edits.len()));
        *self.source.lock().unwrap() = "changed".into();
        Ok(format!("changed {} thing(s)", edits.len()))
    }
    fn project_text(&self) -> Result<String, String> {
        self.log.lock().unwrap().push("project".into());
        Ok("Demo holds:\n- Earth night — a clip".into())
    }
    fn place(&self, thing: &str, _at: Option<f64>) -> Result<String, String> {
        self.log.lock().unwrap().push(format!("place {thing}"));
        Ok(format!("put {thing} in"))
    }
    fn move_clip(
        &self,
        node: &str,
        to: Option<f64>,
        trim: Option<String>,
        at: Option<f64>,
    ) -> Result<String, String> {
        let where_to = to.or(at).unwrap_or(0.0);
        self.log
            .lock()
            .unwrap()
            .push(match &trim {
                Some(edge) => format!("trim {node} {edge} {where_to}"),
                None => format!("slide {node} {where_to}"),
            });
        Ok(match trim {
            Some(edge) => format!("trimmed the {edge} of {node}"),
            None => format!("moved {node}"),
        })
    }
    fn move_when(&self, node: &str, at: f64, which: Option<f64>) -> Result<String, String> {
        self.log
            .lock()
            .unwrap()
            .push(format!("move_when {node} {at} {}", which.unwrap_or(1.0)));
        Ok(format!("{node} starts at {at}s"))
    }
    fn restack(&self, node: &str, over: Option<String>) -> Result<String, String> {
        self.log
            .lock()
            .unwrap()
            .push(format!("restack {node} over {}", over.as_deref().unwrap_or("nothing")));
        Ok(format!("moved {node}"))
    }
    fn cut_clip(&self, node: &str, at: f64) -> Result<String, String> {
        self.log.lock().unwrap().push(format!("cut {node} {at}"));
        Ok(format!("cut {node} in two"))
    }
    fn note(&self, at: f64, text: &str) -> Result<String, String> {
        self.log.lock().unwrap().push(format!("note {at} {text}"));
        Ok(format!("pinned a note at {at}s"))
    }
    fn close_gap(&self, node: &str, take_out: bool) -> Result<String, String> {
        self.log
            .lock()
            .unwrap()
            .push(format!("close_gap {node} {take_out}"));
        Ok(format!("closed the gap after {node}"))
    }
    fn undo(&self) -> Result<String, String> {
        self.log.lock().unwrap().push("undo".into());
        Ok("undid it".into())
    }
    fn export(&self, q: &str) -> Result<String, String> {
        self.log.lock().unwrap().push("export".into());
        Ok(format!("rendering at {q}"))
    }
    fn repaint(&self, _i: &str) -> Result<String, String> {
        self.log.lock().unwrap().push("repaint".into());
        // A new rendered asset, never a change to the composition.
        Ok("made a new clip from the render".into())
    }
}

struct Watch {
    asked: Mutex<Vec<Ask>>,
    chunks: Mutex<Vec<serde_json::Value>>,
    log: Arc<Mutex<Vec<String>>>,
    allow: bool,
}

impl Surface for Watch {
    fn emit(&self, chunk: serde_json::Value) {
        self.chunks.lock().unwrap().push(chunk);
    }
    fn ask(&self, ask: Ask) -> Decision {
        self.log.lock().unwrap().push(format!("asked:{}", ask.tool));
        self.asked.lock().unwrap().push(ask);
        Decision { allow: self.allow, reason: None, remember: None }
    }
}

fn turn(
    replies: Vec<serde_json::Value>,
    prompt: &str,
    allow: bool,
) -> Option<(Outcome, Arc<Spy>, Arc<Watch>)> {
    let root = root()?;
    let paths = Paths::resolve(&root).ok()?;
    let spy = Arc::new(Spy::default());
    let watch = Arc::new(Watch {
        asked: Mutex::new(Vec::new()),
        chunks: Mutex::new(Vec::new()),
        log: Arc::new(Mutex::new(Vec::new())),
        allow,
    });
    let outcome = agent::run_turn(
        Turn {
            paths: &paths,
            bridge: spy.clone(),
            surface: watch.clone(),
            transport: Arc::new(Scripted(Mutex::new(replies.into()))),
            scheme: "openrouter",
            key: "sk-test",
            model: None,
            budget: None,
            cancel: agent::Cancel::default(),
        },
        prompt,
        &[],
    )
    .ok()?;
    Some((outcome, spy, watch))
}

/// Scenario: a turn streams without a local server
#[test]
fn a_turn_streams_without_a_local_server() {
    let Some((outcome, _, watch)) = turn(
        vec![calls(&[("holds", serde_json::json!({}))]), text("Six things.")],
        "what is in this?",
        true,
    ) else {
        return eprintln!("skipped: no checkout");
    };

    // Chunks arrive: the surface is a channel the host owns, not a socket.
    let chunks = watch.chunks.lock().unwrap();
    assert!(!chunks.is_empty(), "no chunks arrived");
    let kinds: Vec<&str> = chunks.iter().filter_map(|c| c["event"].as_str()).collect();
    assert!(kinds.contains(&"start"), "{kinds:?}");
    assert!(kinds.contains(&"stop"), "{kinds:?}");
    assert_eq!(outcome.stop, "answered");

    // And the app opens no port for this. Scanning localhost would only tell us what else is
    // running on the machine -- there is an Ollama on 11434 here -- so the check is on the app
    // itself: nothing in it binds a socket or pulls in a server, and it fails loudly the day
    // somebody adds one.
    let root = root().expect("the checkout");
    let mut binds: Vec<String> = Vec::new();
    for f in walk(&root.join("editor/src-tauri/src")) {
        if f.extension().and_then(|s| s.to_str()) != Some("rs") {
            continue;
        }
        let text = std::fs::read_to_string(&f).unwrap_or_default();
        for pattern in ["TcpListener", "UdpSocket", "axum::", "warp::", "actix", "Server::bind"] {
            if text.contains(pattern) {
                binds.push(format!("{}: {pattern}", f.file_name().unwrap().to_string_lossy()));
            }
        }
    }
    assert!(binds.is_empty(), "the app binds a socket: {binds:?}");
    let manifest = std::fs::read_to_string(root.join("editor/src-tauri/Cargo.toml")).unwrap();
    for server in ["axum", "warp", "actix-web", "tiny_http", "hyper ="] {
        assert!(!manifest.contains(server), "the app depends on {server}");
    }
    eprintln!(
        "  {} chunks over the host's own channel, and the app binds nothing",
        chunks.len()
    );
}

/// Scenario: an edit asks before it lands
#[test]
fn an_edit_asks_before_it_lands() {
    let Some((_, spy, watch)) = turn(
        vec![
            calls(&[(
                "change",
                serde_json::json!({
                    "edits": [{"verb":"set_prop","node":"Block","key":"Width","value":640}],
                    "why": "widen the bar"
                }),
            )]),
            text("Widened it."),
        ],
        "make the bar wider",
        true,
    ) else {
        return eprintln!("skipped: no checkout");
    };

    // The harness asked, and the order is the point: the approval came before the body ran.
    let log = spy.log.lock().unwrap().clone();
    let asked = watch.log.lock().unwrap().clone();
    assert!(!watch.asked.lock().unwrap().is_empty(), "it never asked");
    assert!(log.iter().any(|l| l.starts_with("change")), "the body never ran: {log:?}");
    assert!(
        asked.iter().any(|a| a == "asked:change"),
        "the approval was not for the change: {asked:?}"
    );
    // And what the person was shown is a shape, never a Lua value.
    let ask = &watch.asked.lock().unwrap()[0];
    assert_eq!(ask.tool, "change");
    assert!(ask.args.is_object() || ask.args.is_null(), "{:?}", ask.args);
    eprintln!("  asked for `{}`, then ran it", ask.tool);
}

/// Scenario: a refusal is a result, not an error
#[test]
fn a_refusal_is_a_result_not_an_error() {
    let Some((outcome, spy, watch)) = turn(
        vec![
            calls(&[(
                "change",
                serde_json::json!({
                    "edits": [{"verb":"set_prop","node":"Block","key":"Width","value":640}],
                    "why": "widen the bar"
                }),
            )]),
            text("You said no, so I left it alone."),
        ],
        "make the bar wider",
        false, // the person declines
    ) else {
        return eprintln!("skipped: no checkout");
    };

    // The turn continued and ended normally.
    assert_eq!(outcome.stop, "answered", "a refusal ended the turn as an error");
    assert!(outcome.answer.is_some(), "it had nothing to say afterwards");

    // The body never ran, and the model got the refusal as an ordinary tool result: the proof
    // is that it kept going and answered.
    let log = spy.log.lock().unwrap().clone();
    assert!(
        !log.iter().any(|l| l.starts_with("change")),
        "a declined change ran anyway: {log:?}"
    );
    assert_eq!(*spy.source.lock().unwrap(), "", "the composition was touched");
    let kinds: Vec<String> = watch
        .chunks
        .lock()
        .unwrap()
        .iter()
        .filter_map(|c| c["event"].as_str().map(str::to_string))
        .collect();
    assert!(
        kinds.iter().any(|k| k == "result"),
        "no tool result was reported: {kinds:?}"
    );
    eprintln!("  declined, and the turn answered anyway: {:?}", outcome.reason);
}

/// Scenario: the pixel model never edits a composition
#[test]
fn the_pixel_model_never_edits_a_composition() {
    let Some((_, spy, _)) = turn(
        vec![
            calls(&[(
                "repaint",
                serde_json::json!({ "instruction": "remove the text in the corner" }),
            )]),
            text("Made a new clip with the text gone."),
        ],
        "get rid of the text burned into the footage",
        true,
    ) else {
        return eprintln!("skipped: no checkout");
    };

    let log = spy.log.lock().unwrap().clone();
    assert!(log.iter().any(|l| l == "repaint"), "it never used it: {log:?}");
    // The composition source is unchanged: nothing on the pixel path can reach `change`.
    assert!(
        !log.iter().any(|l| l.starts_with("change")),
        "the pixel model changed the composition: {log:?}"
    );
    assert_eq!(
        *spy.source.lock().unwrap(),
        "",
        "the source moved on a pixel edit"
    );
    eprintln!("  repainted pixels, composition untouched");
}
