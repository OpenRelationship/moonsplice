//! The stack, end to end, against real compositions.
//!
//! These are not unit tests. They start the real renderer, open the real eval suite, and check
//! the properties the whole app is built on:
//!
//!   * `lower(comp, [])` is the identity, byte for byte, for every composition in the repo —
//!     which is what keeps `.robot/golden/` valid while the app is open.
//!   * the ids the engine reports line up with the constructors in the source, which is what
//!     makes a span edit land on the thing the person pointed at.
//!   * an edit is a write, the engine re-reads it, and the outline changes.
//!   * a frame comes back at the composition's own size and encodes.
//!
//! They need the checkout (`MOONSPLICE_ROOT`, or being run from inside it) and a working
//! `moonsplice`. Anything that cannot find those skips rather than fails, so the suite is
//! still useful on a machine with no engine staged.

use std::path::{Path, PathBuf};

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::frames::rgba_to_jpeg;
use moonsplice_studio_lib::lower::{self, Edit, EditRefusal, Layout, NodeRef};
use moonsplice_studio_lib::project::Project;
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::words;
use moonsplice_studio_lib::{Edge, Gesture};

/// Some of these tests are about the bytes, not the wording, so they name nothing.
fn no_names() -> std::collections::HashMap<String, String> {
    std::collections::HashMap::new()
}

fn root() -> Option<PathBuf> {
    moonsplice_studio_lib::engine::moonsplice_root()
}

fn cases(root: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(root.join("evals/cases"))
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("lua"))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

fn serve_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("moonsplice-studio-test-{name}-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&d);
    d
}

/// The property everything else rests on: opening and closing a composition with no edit leaves
/// the bytes alone, so every recorded frame hash still holds.
#[test]
fn no_edit_is_byte_identical_for_every_composition_in_the_repo() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let all = cases(&root);
    assert!(all.len() > 20, "expected the eval suite, found {}", all.len());
    for comp in &all {
        let src = std::fs::read_to_string(comp).unwrap();
        let out = lower::lower(&src, &[], None).expect("no edits cannot fail");
        assert_eq!(out, src, "{} changed with no edits", comp.display());
    }
    eprintln!("{} compositions, all byte-identical with no edits", all.len());
}

/// A span edit has to land on the thing the person pointed at.
///
/// This is the measurement that decided how the alignment works. Counting constructor calls and
/// pairing them with nodes in order — what `lower.py` does — lines up for 29 of the 42
/// compositions here; the other thirteen build nodes in a loop, where one call makes many. So the
/// engine reports the line each node was written on and the alignment is by line, which places
/// every node in every composition: the ones from a loop are placed *and* marked shared, so an
/// edit naming one of eight is refused rather than changing all eight.
#[test]
fn every_node_is_traced_back_to_the_words_that_made_it() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let dir = serve_dir("align");
    let mut placed_all = 0usize;
    let mut with_loops: Vec<String> = Vec::new();
    let mut unplaceable: Vec<String> = Vec::new();
    let mut unopenable: Vec<String> = Vec::new();
    let mut total_nodes = 0usize;
    let mut total_placed = 0usize;
    let mut total_shared = 0usize;

    for comp in cases(&root) {
        let engine = match Engine::start(&comp, &root, &dir) {
            Ok(e) => e,
            Err(_) => {
                unopenable.push(name(&comp));
                continue;
            }
        };
        let outline = match engine.outline("test") {
            Ok(o) => o,
            Err(_) => {
                unopenable.push(name(&comp));
                engine.stop();
                continue;
            }
        };
        engine.stop();
        let nodes = node_refs(&outline);
        assert!(
            nodes.iter().all(|n| n.line.is_some()),
            "{} reported a node with no line",
            name(&comp)
        );
        let src = std::fs::read_to_string(&comp).unwrap();
        let layout = match Layout::read(&src, Some(&nodes)) {
            Ok(l) => l,
            Err(why) => {
                unplaceable.push(format!("{} ({why})", name(&comp)));
                continue;
            }
        };
        let mut shared = 0usize;
        let mut lost = 0usize;
        for n in &nodes {
            match layout.span(&n.id) {
                Ok(_) => {}
                Err(EditRefusal::Shared { .. }) => shared += 1,
                Err(_) => lost += 1,
            }
        }
        total_nodes += nodes.len();
        total_placed += layout.placed();
        total_shared += shared;
        if lost > 0 {
            unplaceable.push(format!("{} ({lost} of {})", name(&comp), nodes.len()));
        } else if shared > 0 {
            with_loops.push(name(&comp));
        } else {
            placed_all += 1;
        }
    }

    eprintln!(
        "{total_placed} of {total_nodes} things are directly editable; {total_shared} come from a \
         loop and are refused by name.\n  every thing editable: {placed_all} composition(s)\n  \
         some built in a loop: {} ({})\n  something unplaceable: {} ({})\n  would not open: {} ({})",
        with_loops.len(),
        with_loops.join(", "),
        unplaceable.len(),
        unplaceable.join(", "),
        unopenable.len(),
        unopenable.join(", "),
    );

    // A handful stay untraceable and the app says so rather than guessing. `s:draw(function…)`
    // is the honest case: it has no table of properties for an edit to land in.
    let lost: usize = total_nodes - total_placed - total_shared;
    assert!(
        lost * 50 <= total_nodes,
        "{lost} of {total_nodes} things cannot be traced, which is more than 2%: {unplaceable:?}"
    );
    // The bar that matters: a thing is either editable or refused *by name*. Silently losing one
    // is the failure, and `draw`'s function body is the only one in the suite.
    let traced = total_placed + total_shared;
    assert!(
        traced * 100 >= total_nodes * 99,
        "only {traced} of {total_nodes} things could be traced at all"
    );
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

/// The whole loop the app runs on a drag: read the outline, rewrite one span, re-read, see it.
#[test]
fn an_edit_is_a_write_and_the_engine_sees_it() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(work.path().join("comps")).unwrap();
    let comp = work.path().join("comps/captions.lua");
    std::fs::copy(root.join("comps/cases/captions.lua"), &comp).unwrap();
    // The case reads fonts from the repo, so the project's working directory is the checkout.
    let engine = match Engine::start(&comp, &root, &serve_dir("edit")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    assert_eq!(engine.meta.width, 1280);
    assert_eq!(engine.meta.height, 720);
    assert!((engine.meta.duration - 3.6).abs() < 1e-6);

    let mut doc = SourceDoc::open(&comp).unwrap();
    let before = engine.outline(doc.hash()).unwrap();
    let nodes = node_refs(&before);

    // Reword the first spoken line. `set_cue` is the verb a caption drag uses.
    doc.apply(
        &[Edit::SetCue {
            node: nodes
                .iter()
                .find(|n| n.id.starts_with("text"))
                .map(|n| n.id.clone())
                .unwrap(),
            index: 0,
            t0: None,
            t1: None,
            text: Some("Hold it there.".into()),
        }],
        Some(&nodes),
        &no_names(),
    )
    .expect_err("the first text node has no cues, so this is refused rather than misapplied");

    // The captions node is the one with cues; find it from the outline instead of guessing.
    let cue_node = before["cues"][0]["node"].as_str().unwrap().to_string();
    let applied = doc
        .apply(
            &[Edit::SetCue {
                node: cue_node.clone(),
                index: 0,
                t0: None,
                t1: None,
                text: Some("Hold it there.".into()),
            }],
            Some(&nodes),
            &words::names(&before),
        )
        .expect("the captions node takes a cue edit");
    assert_eq!(applied.what.len(), 1);
    assert!(doc.text().contains("Hold it there."));
    // And what it says about itself is something a person can read: no node id, no key.
    let said = &applied.what[0];
    assert!(!said.contains(&cue_node), "the notice named a node id: {said}");
    eprintln!("  the app said: {said}");
    assert_eq!(
        std::fs::read_to_string(&comp).unwrap(),
        doc.text(),
        "an edit is a write, with no save step"
    );

    engine.reload().unwrap();
    let after = engine.outline(doc.hash()).unwrap();
    assert_eq!(after["cues"][0]["text"].as_str(), Some("Hold it there."));
    assert_eq!(
        after["cues"][0]["t0"].as_f64(),
        before["cues"][0]["t0"].as_f64(),
        "rewording a line must not retime it"
    );

    // And undo puts the bytes back exactly.
    doc.undo().unwrap();
    assert_eq!(
        std::fs::read_to_string(&comp).unwrap(),
        std::fs::read_to_string(root.join("comps/cases/captions.lua")).unwrap()
    );
    engine.stop();
}

/// A frame comes back at the composition's own size, and encodes to something a webview can show.
#[test]
fn a_frame_arrives_and_encodes() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let comp = root.join("comps/cases/motion.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("frame")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let (rgba, w, h) = engine.frame(0.5).expect("a frame");
    assert_eq!((w, h), (engine.meta.width, engine.meta.height));
    assert_eq!(rgba.len(), w as usize * h as usize * 4);
    assert!(
        rgba.chunks(4).any(|p| p[0] > 8 || p[1] > 8 || p[2] > 8),
        "the frame is entirely black, so nothing was painted"
    );

    let jpeg = rgba_to_jpeg(&rgba, w, h, 640, 360, 82).expect("encoded");
    assert_eq!(&jpeg[..2], &[0xff, 0xd8]);
    assert!(jpeg.len() > 2_000, "a 640x360 frame of a real comp is not 2 KB");

    // What a frame really costs to carry, on a real composition rather than on noise: the
    // number that decides whether playback can keep up.
    for (bw, bh) in [(960u32, 540u32), (1280, 720)] {
        let t = std::time::Instant::now();
        let n = 10;
        let mut bytes = 0;
        for _ in 0..n {
            bytes = rgba_to_jpeg(&rgba, w, h, bw, bh, 82).unwrap().len();
        }
        let each = t.elapsed().as_secs_f64() * 1000.0 / n as f64;
        eprintln!(
            "  a real frame at {bw}x{bh}: {each:.2} ms, {} KB -> {:.0} fps, {:.1} MB/s at 30fps",
            bytes / 1024,
            1000.0 / each,
            bytes as f64 * 30.0 / 1_048_576.0
        );
    }

    // Two different times are two different pictures — otherwise seeking does nothing.
    let (other, _, _) = engine.frame(1.6).unwrap();
    assert_ne!(rgba, other, "seeking produced the same frame twice");

    // And the same time twice is the same picture: the app is allowed to cache on (hash, t, size).
    let (again, _, _) = engine.frame(0.5).unwrap();
    assert_eq!(rgba, again, "the renderer is not deterministic at one time");
    engine.stop();
}

/// What the agent reads. Every value in it is the number the renderer painted with.
#[test]
fn one_instant_reports_what_is_actually_on_screen() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let comp = root.join("comps/cases/captions.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("instant")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    // The bar grows from w = 0 to w = 640 between 0.15s and 0.55s.
    let early = engine.at(0.2).unwrap();
    let late = engine.at(1.0).unwrap();
    let width_of = |v: &serde_json::Value| -> Option<f64> {
        v["nodes"]
            .as_array()?
            .iter()
            .find(|n| n["id"] == "rect4")
            .and_then(|n| n["props"]["w"].as_f64())
    };
    let a = width_of(&early).expect("the bar at 0.2s");
    let b = width_of(&late).expect("the bar at 1.0s");
    assert!(a < b, "the bar did not grow: {a} then {b}");
    assert!((b - 640.0).abs() < 1.0, "the bar should have arrived at 640, got {b}");

    // The spoken line at 1.0s is the first one.
    let words = late["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|n| n["props"]["text"].as_str())
        .collect::<Vec<_>>();
    assert!(
        words.contains(&"Hold the cut."),
        "the first line should be up at 1.0s, saw {words:?}"
    );
    engine.stop();
}

/// When each thing is on screen, measured by the engine against a composition whose answer is
/// known from reading it.
///
/// The timeline draws a clip from this, so a wrong answer here is a lie the size of the widest
/// shape in the app. The fixture fades one thing in late, takes another away in the middle, and
/// gives a third no animation at all.
#[test]
fn the_engine_measures_when_each_thing_is_on_screen() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("onscreen.lua");
    std::fs::write(
        &comp,
        r##"local e = require("moonsplice")

return e.comp {
  width = 320, height = 180, duration = 2, fps = 30,
  background = "#000000",

  scene = function(s)
    local always = s:rect { x = 10, y = 10, w = 40, h = 40, color = "#ffffff" }
    local late = s:rect { x = 60, y = 10, w = 40, h = 40, color = "#ff0000", opacity = 0 }
    local leaves = s:rect { x = 110, y = 10, w = 40, h = 40, color = "#00ff00" }
    local never = s:rect { x = 160, y = 10, w = 40, h = 40, color = "#0000ff", opacity = 0 }
    s:script(function(t)
      t:parallel(
        function()
          t:wait(1)
          t:set(late, { opacity = 1 })
        end,
        function()
          t:wait(0.5)
          t:set(leaves, { opacity = 0 })
        end
      )
    end)
    return { always, never }
  end,
}
"##,
    )
    .unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("onscreen")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let outline = engine.outline("test").unwrap();
    engine.stop();

    let spans = |id: &str| -> Vec<(f64, f64)> {
        outline["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["id"] == id)
            .unwrap_or_else(|| panic!("no node {id} in the outline"))["onscreen"]
            .as_array()
            .unwrap_or_else(|| panic!("{id} carries no measurement"))
            .iter()
            .map(|c| (c["t0"].as_f64().unwrap(), c["t1"].as_f64().unwrap()))
            .collect()
    };

    let always = spans("rect1");
    assert_eq!(always.len(), 1, "a thing that is always there is one clip: {always:?}");
    assert!(always[0].0 < 0.01 && (always[0].1 - 2.0).abs() < 0.05, "{always:?}");

    let late = spans("rect2");
    assert_eq!(late.len(), 1, "one appearance: {late:?}");
    assert!((late[0].0 - 1.0).abs() < 0.05, "it arrives at 1s, not {:?}", late[0].0);
    assert!((late[0].1 - 2.0).abs() < 0.05, "and stays: {late:?}");

    let leaves = spans("rect3");
    assert_eq!(leaves.len(), 1, "one appearance: {leaves:?}");
    assert!(leaves[0].0 < 0.01, "it starts on: {leaves:?}");
    assert!((leaves[0].1 - 0.5).abs() < 0.05, "and goes at half a second: {leaves:?}");

    assert_eq!(spans("rect4"), vec![], "a thing at zero opacity is never on screen");

    assert_eq!(
        outline["comp"]["onscreen_stride"].as_u64(),
        Some(1),
        "a two-second composition is measured every frame"
    );
}

/// An empty composition opens.
///
/// It is listed — `app-shell` scenario 2 — which is only half of it: a person makes one in order
/// to open it. Both answers the engine gives about it have to be the shape the app expects, and
/// `nodes` on an instant used to come back as `{}` rather than `[]`, which reached `.map` in the
/// preview and blanked the whole window.
#[test]
fn an_empty_composition_opens_rather_than_blanking() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("empty.lua");
    std::fs::write(
        &comp,
        "local e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 1080, height = 1080, duration = 5, fps = 30,\n  background = \"#0b0d12\",\n\n  scene = function(s)\n  end,\n}\n",
    )
    .unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("empty")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };

    let outline = engine.outline("test").unwrap();
    for field in ["nodes", "tracks", "audio", "cues", "cli_only"] {
        assert!(
            outline[field].is_array(),
            "the outline's {field} came back as {:?}, not a list",
            outline[field]
        );
        assert_eq!(outline[field].as_array().unwrap().len(), 0, "{field} is empty");
    }

    let instant = engine.at(1.0).unwrap();
    assert!(
        instant["nodes"].is_array(),
        "the instant's nodes came back as {:?}, not a list",
        instant["nodes"]
    );

    // And it paints: an empty composition is its background, which is a frame like any other.
    let (rgba, w, h) = engine.frame(1.0).unwrap();
    assert_eq!((w, h), (1080, 1080));
    assert_eq!(rgba.len(), (w * h * 4) as usize);
    engine.stop();
}

/// A folder of compositions opens as a project, with a manifest written from what is there.
#[test]
fn a_folder_of_compositions_opens_as_a_project() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(work.path().join("comps")).unwrap();
    for name in ["captions", "motion", "eases"] {
        std::fs::copy(
            root.join(format!("comps/cases/{name}.lua")),
            work.path().join(format!("comps/{name}.lua")),
        )
        .unwrap();
    }
    let p = Project::open(work.path()).unwrap();
    let view = p.view();
    assert_eq!(view.compositions.len(), 3);
    let titles: Vec<&str> = view.compositions.iter().map(|c| c.title.as_str()).collect();
    assert_eq!(titles, vec!["Captions", "Eases", "Motion"]);
    for c in &view.compositions {
        assert_eq!(c.variations.len(), 1);
        assert_eq!(c.variations[0].aspect, "16:9");
        assert!(!c.variations[0].empty);
    }
    // Nothing the UI receives is a path.
    let json = serde_json::to_string(&view).unwrap();
    assert!(!json.contains(".lua"), "a path leaked into the project view: {json}");
    assert!(!json.contains("comps/"));
}

fn name(p: &Path) -> String {
    p.file_stem().and_then(|s| s.to_str()).unwrap_or("?").to_string()
}

/// A caption's lines are recorded as steps on `text`, exactly as a hand-pinned value is. They are
/// not one, and the timeline has to be able to tell — the whole manual-versus-relational
/// distinction the desktop spec asks for turns on it. So the engine tags them, and a lane of
/// spoken words never draws as a row of values somebody set by hand.
#[test]
fn a_spoken_line_is_not_a_value_somebody_pinned() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let comp = root.join("comps/cases/captions.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("cues")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let outline = engine.outline("none").unwrap();
    let tracks = outline["tracks"].as_array().expect("tracks");

    let caption = tracks
        .iter()
        .find(|t| t["prop"] == "text")
        .expect("the captions node has a track on its words");
    for seg in caption["segments"].as_array().unwrap() {
        assert_eq!(seg["kind"], "cue", "a spoken line should be a cue");
        assert_eq!(seg["manual"], false, "a spoken line is not a hand-set value");
    }

    // And the distinction still works the other way: the bar's growth is a movement.
    let bar = tracks
        .iter()
        .find(|t| t["prop"] == "w")
        .expect("the bar has a track on its width");
    let first = &bar["segments"][0];
    assert_eq!(first["kind"], "tween");
    assert_eq!(first["manual"], false);

    // Nothing in this composition was set by hand, so nothing claims to have been.
    let pinned = tracks
        .iter()
        .flat_map(|t| t["segments"].as_array().unwrap())
        .filter(|s| s["manual"] == true)
        .count();
    assert_eq!(pinned, 0, "{} segments wrongly read as hand-set", pinned);
}

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

/// An export renders from the project's own directory and lands back in the project.
///
/// Both halves of that sentence were bugs. The renderer ran from the checkout, so a composition
/// that names anything relative to its project wrote a 262-byte stub; and a finished video went
/// into a folder nobody had been shown, because "an export enters the project" was a decision
/// nothing had implemented.
#[test]
fn an_export_renders_from_the_project_and_enters_it() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(work.path().join("comps")).unwrap();
    // `motion` names no fonts and no assets, so it is a composition that stands on its own in a
    // project directory -- which is the case this is about.
    std::fs::copy(
        root.join("comps/cases/motion.lua"),
        work.path().join("comps/motion.lua"),
    )
    .unwrap();

    let mut p = Project::open(work.path()).unwrap();
    let variation = p.view().compositions[0].variations[0].id.clone();
    let plan = moonsplice_studio_lib::plan_export(&p, &variation).expect("a plan");
    assert_eq!(plan.title, "Motion", "what the notice will call it");
    assert_eq!(plan.root, work.path(), "the renderer runs in the project");

    if let Err(why) = moonsplice_studio_lib::run_export(&plan, "standard") {
        // No engine staged on this machine is a skip; anything else is the failure it looks like.
        if why.contains("did not start") || why.contains("not next to this app") {
            eprintln!("skipped: {why}");
            return;
        }
        panic!("the export failed: {why}");
    }

    let size = std::fs::metadata(&plan.out).unwrap().len();
    assert!(size > 10_000, "the video is {size} bytes, which is a stub, not a render");

    // It is a real video of the composition's own shape and length, read back with ffprobe
    // rather than trusted.
    let probe = std::process::Command::new("ffprobe")
        .args(["-v", "error", "-show_entries", "stream=width,height,nb_frames", "-of", "csv=p=0"])
        .arg(&plan.out)
        .output();
    match probe {
        Ok(o) if o.status.success() => {
            let said = String::from_utf8_lossy(&o.stdout).trim().to_string();
            assert_eq!(said, "1280,720,60", "ffprobe read back: {said}");
        }
        _ => eprintln!("  (ffprobe not available, so the file was only sized)"),
    }

    // And it is in the project, as something a person can see, with no path anywhere in it.
    let asset = p.add_export(&plan.into, &plan.title).unwrap();
    assert_eq!(asset.name, "Motion");
    assert_eq!(asset.kind, moonsplice_studio_lib::project::AssetKind::Footage);
    let view = serde_json::to_string(&p.view()).unwrap();
    assert!(view.contains("Motion"));
    for path in [".mp4", "exports/", ".lua"] {
        assert!(!view.contains(path), "`{path}` leaked into the project view");
    }

    // Exporting again replaces it rather than stacking up a second one.
    p.add_export(&plan.into, &plan.title).unwrap();
    let footage = p
        .view()
        .assets
        .iter()
        .filter(|a| a.name == "Motion")
        .count();
    assert_eq!(footage, 1, "a second export of the same thing is the same asset");
}

/// An edit the engine cannot load goes back, and the reason is a sentence.
///
/// An edit is a write, so by the time anything knows the composition will not load, the change is
/// already on disk. Leaving it there leaves a person holding a composition their app cannot open,
/// which is the worst outcome available. So it is put back.
///
/// The case that happens in practice: a composition's length is fixed (`.robot/docs/design.robot`), and dragging
/// a movement's right edge can push the script past the end of it.
#[test]
fn an_edit_the_engine_cannot_load_goes_back() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(work.path().join("comps")).unwrap();
    let comp = work.path().join("comps/captions.lua");
    std::fs::copy(root.join("comps/cases/captions.lua"), &comp).unwrap();
    let original = std::fs::read_to_string(&comp).unwrap();
    let engine = match Engine::start(&comp, &root, &serve_dir("unloadable")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let mut doc = SourceDoc::open(&comp).unwrap();
    let outline = engine.outline(doc.hash()).unwrap();
    let names = words::names(&outline);
    let nodes = node_refs(&outline);
    let bar = outline["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["prop"] == "w")
        .map(|t| t["node"].as_str().unwrap().to_string())
        .expect("the bar's width moves");

    // 0.4s of movement inside a script that already runs to the composition's own end. 0.8 puts
    // it 0.4s past.
    let edits = moonsplice_studio_lib::gesture_to_edits(
        Gesture::Lengthen { node: bar, seconds: 0.8, occurrence: 0 },
        &outline,
    )
    .expect("the gesture has a verb; it is the result the engine will not take");
    let refused =
        moonsplice_studio_lib::write_and_reload(&mut doc, &engine, &edits, &nodes, &names)
            .expect_err("a script past the end of its composition cannot be loaded");

    let said = refused.say(&names);
    eprintln!("  the app said: {said}");
    assert!(said.contains("past the end"), "said: {said}");
    for code in ["comp.", "moonsplice:", ".lua", "3.600"] {
        assert!(!said.contains(code), "`{code}` in: {said}");
    }
    assert_eq!(
        std::fs::read_to_string(&comp).unwrap(),
        original,
        "the write went back, so nobody is left with a composition that will not open"
    );
    // And the engine is still serving what it was, rather than sitting on the broken read.
    let after = engine.outline(doc.hash()).unwrap();
    assert_eq!(after["nodes"].as_array().map(Vec::len), Some(6));
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

/// Scenario: a gap is not closed over something that is animated
///
/// The thing a ripple must never do quietly. A movement is written against the composition's
/// clock, not against the clip it belongs to, so sliding a clip out from under its own fade
/// would take the fade off the shot without anybody asking for it. It is refused instead, and
/// the refusal names what stopped it and what to do about it.
#[test]
fn a_gap_is_not_closed_over_something_that_is_animated() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("animated.lua");
    let clip = "comps/assets/earth_night.webm";
    std::fs::write(
        &comp,
        format!(
            "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {{\n  \
             width = 640, height = 360, duration = 10, fps = 30,\n  background = \"#0b0d12\",\n\n  \
             scene = function(s)\n    \
             s:video {{ src = \"{clip}\", from = 0, duration = 2, media_start = 0 }}\n    \
             local late = s:video {{ src = \"{clip}\", from = 4, duration = 2, media_start = 0, \
             opacity = 0 }}\n    s:script(function(t)\n      t:at(4)\n      \
             t:tween(late, 0.5, {{ opacity = 1 }})\n    end)\n  \
             end,\n}}\n"
        ),
    )
    .unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("animated")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let doc = SourceDoc::open(&comp).unwrap();
    let outline = engine.outline(doc.hash()).unwrap();
    let names = words::names(&outline);
    let first = outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["kind"] == "video")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();

    let refused = moonsplice_studio_lib::gesture_to_edits(
        Gesture::CloseGap { after: first },
        &outline,
    )
    .expect_err("the clip after the gap is faded in by the timeline");
    let said = refused.say(&names);
    assert!(said.contains("moved by the timeline"), "{said}");
    assert!(
        said.contains("take it out without closing the gap") || said.contains("move what moves it"),
        "the refusal offers the nearest thing that can be done: {said}"
    );
    engine.stop();
}

/// Scenario: a note is pinned to a moment and read back where it was pinned
///
/// Markers, which every editor has and this one did not. The point of the design is what it did
/// *not* need: a marker is a node, so putting one in is `place`, moving it and renaming it are
/// `set_value`, and taking it out is `remove` -- four verbs that already existed, and no
/// eleventh. The renderer never draws it and the encode never hears it; it is a thing the edit
/// contains rather than a thing the picture does.
///
/// What this checks is the whole round trip, because that is where a new kind of node goes
/// wrong: the composition compiles, the engine reports it, it is never on screen, and the three
/// things a person does to one all reach the file and all come back.
#[test]
fn a_note_is_pinned_to_a_moment_and_read_back_where_it_was_pinned() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let work = tempfile::tempdir().unwrap();
    let comp = work.path().join("notes.lua");
    std::fs::write(
        &comp,
        "-- Untitled\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {\n  \
         width = 320, height = 180, duration = 6, fps = 30,\n  background = \"#101418\",\n\n  \
         scene = function(s)\n    \
         s:rect { x = 40, y = 40, w = 240, h = 100, color = \"#3ee0c6\" }\n  end,\n}\n",
    )
    .unwrap();
    let was = std::fs::read_to_string(&comp).unwrap();

    let engine = match Engine::start(&comp, &root, &serve_dir("notes")) {
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
        let edits = moonsplice_studio_lib::gesture_to_edits(g, outline)
            .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        let nodes = node_refs(outline);
        let (applied, next) =
            moonsplice_studio_lib::write_and_reload(doc, &engine, &edits, &nodes, &names)
                .unwrap_or_else(|r| panic!("{}", r.say(&names)));
        (applied, next)
    };
    let notes = |o: &serde_json::Value| -> Vec<(String, f64, String)> {
        o["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|n| n["kind"] == "marker")
            .map(|n| {
                (
                    n["id"].as_str().unwrap().to_string(),
                    n["props"]["at"].as_f64().unwrap(),
                    n["props"]["text"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    };

    assert!(notes(&outline).is_empty(), "nothing is pinned yet");

    // Pinned where the playhead was.
    let (applied, next) = apply(
        &outline,
        &mut doc,
        Gesture::Mark {
            t: 2.5,
            text: "fix this cut".into(),
        },
    );
    outline = next;
    assert_eq!(
        notes(&outline),
        vec![("marker2".to_string(), 2.5, "fix this cut".to_string())],
        "{:?}",
        applied.what
    );

    // A note is never on screen. If it were, the timeline would draw a bar across the whole
    // composition for a thing that has no length at all -- which is what "it has no opacity, so
    // its opacity is one" would have said.
    let note = &outline["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["kind"] == "marker")
        .unwrap();
    assert_eq!(
        note["onscreen"].as_array().map(|a| a.len()),
        Some(0),
        "a note is not on screen: {:?}",
        note["onscreen"]
    );
    // And it is called by what it says, everywhere the app says anything.
    let names = words::names(&outline);
    assert_eq!(words::name_of(&names, "marker2"), "fix this cut");

    // Changing what it says, and when it is -- the two things a note has, and both of them are
    // the same `set_value` the inspector writes for anything else.
    outline = apply(
        &outline,
        &mut doc,
        Gesture::SetValue {
            node: "marker2".into(),
            key: "text".into(),
            value: serde_json::json!("colour pass"),
        },
    )
    .1;
    outline = apply(
        &outline,
        &mut doc,
        Gesture::SetValue {
            node: "marker2".into(),
            key: "at".into(),
            value: serde_json::json!(4.25),
        },
    )
    .1;
    assert_eq!(
        notes(&outline),
        vec![("marker2".to_string(), 4.25, "colour pass".to_string())]
    );

    // The picture is untouched by all of it: a note is not in the frame, so no frame changed.
    let (rgba, w, h) = engine.frame(4.25).expect("a frame where the note is");
    assert_eq!((w, h), (320, 180));
    assert!(rgba.iter().any(|b| *b != 0), "the frame is still painted");

    // Taken out.
    outline = apply(
        &outline,
        &mut doc,
        Gesture::Remove {
            node: "marker2".into(),
        },
    )
    .1;
    assert!(notes(&outline).is_empty());

    // A note with nothing written on it is not a note.
    let refused = moonsplice_studio_lib::gesture_to_edits(
        Gesture::Mark {
            t: 1.0,
            text: "   ".into(),
        },
        &outline,
    )
    .expect_err("an empty note");
    assert!(refused.say(&names).contains("nothing written on it"));

    // Four changes, four undos, and the file is what it was.
    for _ in 0..4 {
        doc.undo().unwrap();
    }
    assert_eq!(std::fs::read_to_string(&comp).unwrap(), was);
    engine.stop();
}

/// Scenario: a frame reaches the canvas as the window would read it
///
/// The last link in the chain, and the one nothing was watching. The renderer made frames
/// perfectly well and the pane showed its "nothing here yet" checkerboard, because the size
/// travelled in `x-frame-width` and `x-frame-height` -- and the page is served from one scheme
/// and frames from another, so every fetch of a frame is cross-origin and script may only read
/// the handful of response headers CORS safelists. Both read `null`, the width was zero, and
/// every frame was thrown away by the check that exists to catch a cut-off one.
///
/// So the size is in the frame now, and this walks a real frame the whole way: engine, scaled to
/// the pane the way the app scales it, stamped the way the app stamps it -- and then read back
/// under exactly the rules `paint()` in `editor/src/player.ts` applies. Nothing here is a
/// stand-in: if this passes, a frame that arrives is a frame that paints.
#[test]
fn a_frame_reaches_the_canvas_as_the_window_would_read_it() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    let comp = root.join("comps/cases/motion.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("canvas")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };

    // The pane, at a couple of shapes: wider than the composition, and taller.
    for (bw, bh) in [(880u32, 500u32), (400, 900)] {
        let (want, _) = moonsplice_studio_lib::frames::fit(engine.meta.width, engine.meta.height, bw, bh);
        let (rgba, sw, sh, _) = engine
            .frame_measured(0.5, Some(want))
            .expect("a frame at the size the pane asked for");
        let (bytes, dw, dh) = moonsplice_studio_lib::frames::scale_rgba(&rgba, sw, sh, bw, bh)
            .expect("that frame did not scale");
        let body = moonsplice_studio_lib::stamped(&moonsplice_studio_lib::frames::Frame {
            bytes: std::sync::Arc::new(bytes),
            w: dw,
            h: dh,
        });

        // From here down is `paint()`, in Rust, rule for rule.
        assert!(body.len() >= 8, "a body too short to say how big it is");
        let w = u32::from_le_bytes(body[0..4].try_into().unwrap());
        let h = u32::from_le_bytes(body[4..8].try_into().unwrap());
        assert!(w > 0 && h > 0, "the window would read this as not a frame");
        assert!(
            body.len() - 8 >= w as usize * h as usize * 4,
            "the window would refuse this as a frame that was cut off"
        );
        // And what it says it is, is what the app decided it is.
        assert_eq!((w, h), (dw, dh));
        // The picture keeps its proportions inside the box rather than being stretched to it.
        assert!(w <= bw && h <= bh, "{w}x{h} does not fit in {bw}x{bh}");
        let was = engine.meta.width as f64 / engine.meta.height as f64;
        let now = w as f64 / h as f64;
        assert!((was - now).abs() < 0.02, "the frame was stretched: {was} -> {now}");
        // And there is a picture in it. A preview that answers with an empty rectangle is the
        // thing this whole test exists to notice.
        let pixels = &body[8..];
        assert!(
            pixels.chunks(4).any(|p| p[0] > 8 || p[1] > 8 || p[2] > 8),
            "the frame that would be painted is entirely black"
        );
        eprintln!("  a {bw}x{bh} pane gets {w}x{h}, {} KB, stamped", body.len() / 1024);
    }
    engine.stop();
}

/// Nothing the window asks these two schemes for may come back without permission to read it.
///
/// This is a source-level test, which is unusual here and is the point: the thing that failed
/// was not a value a function returned, it was a header a response did not carry, and the
/// responses are built inside two closures handed to the Tauri builder -- there is no seam to
/// call and assert on without inventing one that exists only for the test.
///
/// What it is guarding is worth the unusual shape. Without the header the webview refuses every
/// response before the app sees a byte, `fetch` reports only "Load failed", and the app shows
/// the same checkerboard it shows when the renderer is broken -- while the renderer, the queue
/// and the cache all work, and the count of frames served goes up for every one thrown away.
/// It cost most of a day. The rule it leaves behind is one line: every `Response::builder()` in
/// those two handlers goes through `across_the_origin`.
#[test]
fn a_frame_and_a_sound_come_back_with_permission_to_read_them() {
    let src = include_str!("../src/lib.rs");
    // The two scheme handlers, from the first to the end of the second.
    let from = src
        .find("register_asynchronous_uri_scheme_protocol(\"cframe\"")
        .expect("the frame scheme is registered");
    let to = src[from..]
        .find(".setup(|app| {")
        .map(|i| from + i)
        .expect("the scheme handlers end at setup");
    let handlers = &src[from..to];

    let plain = handlers.matches("tauri::http::Response::builder()").count();
    let wrapped = handlers
        .matches("across_the_origin(tauri::http::Response::builder())")
        .count();
    assert!(wrapped >= 6, "expected every response to be wrapped, found {wrapped}");
    assert_eq!(
        plain, wrapped,
        "{} of {} responses from cframe/casset skip across_the_origin, and the window cannot \
         read what they send",
        plain - wrapped,
        plain
    );

    // And the wrapper actually says the thing.
    for header in [
        "access-control-allow-origin",
        "access-control-allow-methods",
        "access-control-allow-headers",
    ] {
        assert!(
            src.contains(&format!("\"{header}\"")),
            "across_the_origin does not send {header}"
        );
    }
    // A `<audio>` element asking for a range preflights first, and a preflight nobody answers
    // fails exactly as silently as a missing header.
    assert!(
        handlers.contains("Method::OPTIONS"),
        "the asset scheme does not answer a preflight"
    );
    eprintln!("cors      {wrapped} responses, all of them readable by the window");
}
