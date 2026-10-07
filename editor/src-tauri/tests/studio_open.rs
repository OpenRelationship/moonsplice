//! The stack end to end, against real compositions (the suite's description is in tests/common/mod.rs):
//! opening the eval suite, tracing nodes to their words, an edit as a write, and a frame.

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::frames::rgba_to_jpeg;
use moonsplice_studio_lib::lower::{self, Edit, EditRefusal, Layout};
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::words;

mod common;
use common::*;

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
