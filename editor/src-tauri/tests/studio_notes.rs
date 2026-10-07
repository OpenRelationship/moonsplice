//! The stack end to end, against real compositions (the suite's description is in tests/common/mod.rs):
//! a gap not closed over animation, a note pinned to a moment, and frames and sounds reaching the window.

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::words;
use moonsplice_studio_lib::Gesture;

mod common;
use common::*;

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
