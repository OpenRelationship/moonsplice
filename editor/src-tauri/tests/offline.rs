//! What happens when something a composition needs is not on the disk.
//!
//! The failure this is about is not subtle: before it, one file that had been moved or renamed
//! stopped the whole composition loading. No picture, no timeline, no names, nothing to say
//! which of two hundred things was the problem or that the other hundred and ninety-nine were
//! fine -- and on a ten minute edit with seventy sounds in it, "something is missing" is not an
//! answer anybody can act on.
//!
//! So a thing that cannot be made ready takes itself off the air and the composition still
//! opens. These check that it really does open, that everything else in it is still there and
//! still moving, that the reason comes back as a word the app has a sentence for, and that no
//! part of the answer names a file -- the missing file least of all, since the point of the
//! exercise is to say what is wrong without showing a path.
//!
//! The comps are written here rather than committed: a fixture whose whole point is a file that
//! does not exist is a fixture that has to be built, not stored.

use std::path::{Path, PathBuf};

use moonsplice_studio_lib::engine::Engine;

fn root() -> Option<PathBuf> {
    let r = moonsplice_studio_lib::engine::moonsplice_root();
    if r.is_none() {
        eprintln!("skipped: no checkout found");
    }
    r
}

fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("moonsplice-offline-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).expect("a place to put the fixture");
    d
}

/// A whole project of its own: a folder, one composition, and whatever real files it needs
/// copied in beside it. Returns the project root, the composition, and a place to serve from.
///
/// Its own folder rather than a file dropped into the checkout: the missing paths here are made
/// up, and a made-up path is only reliably missing somewhere nothing else is looking.
fn project(root: &Path, name: &str, body: &str, bring: &[(&str, &str)]) -> (PathBuf, PathBuf, PathBuf) {
    let dir = scratch(name);
    for (from, to) in bring {
        let dst = dir.join(to);
        if let Some(parent) = dst.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        std::fs::copy(root.join(from), &dst).expect("the real file is brought along");
    }
    let comp = dir.join("Take.lua");
    std::fs::write(&comp, body).expect("the fixture is written");
    (dir.clone(), comp, dir.join(".serve"))
}

fn open(comp: &Path, root: &Path, serve: &Path) -> Option<Engine> {
    match Engine::start(comp, root, serve) {
        Ok(e) => Some(e),
        Err(why) => {
            eprintln!("skipped: {why}");
            None
        }
    }
}

fn nodes(outline: &serde_json::Value) -> Vec<&serde_json::Value> {
    outline["nodes"].as_array().map(|a| a.iter().collect()).unwrap_or_default()
}

fn by_label<'a>(outline: &'a serde_json::Value, label: &str) -> Option<&'a serde_json::Value> {
    nodes(outline).into_iter().find(|n| n["label"].as_str() == Some(label))
}

/// The one that matters: a composition with a missing file still opens, and everything that is
/// not missing is untouched.
#[test]
fn one_missing_file_does_not_take_the_composition_with_it() {
    let Some(root) = root() else { return };
    let (proj, comp, serve) = project(
        &root,
        "one",
        r##"local e = require("moonsplice")
return e.comp {
  width = 640, height = 360, duration = 4, fps = 30, background = "#0b0d12",
  scene = function(s)
    local plate = s:image {
      src = "Stills/apollo17.jpg", label = "Here",
      x = 320, y = 180, w = 640, h = 641, anchor = "center",
    }
    -- The right half only, so one frame can be asked both questions: is the thing that is
    -- there still painting, and is the thing that is not there painting a slate.
    s:video {
      src = "Footage/nothing-is-here.mp4", label = "Gone",
      from = 0, duration = 4, x = 320, y = 0, w = 320, h = 360,
    }
    local title = s:text { x = 24, y = 300, text = "Still an edit", size = 28, opacity = 0 }
    s:script(function(t)
      t:parallel(
        function() t:tween(plate, 3, { scale = 1.2 }, "sineInOut") end,
        function() t:tween(title, 1, { opacity = 1 }, "sineOut") end
      )
    end)
  end,
}
"##,
        &[("comps/assets/apollo17.jpg", "Stills/apollo17.jpg")],
    );
    let Some(engine) = open(&comp, &proj, &serve) else { return };
    let outline = engine.outline("test").expect("an outline");

    // It opened at all, which is the whole point.
    assert_eq!(outline["comp"]["duration"].as_f64(), Some(4.0));

    let gone = by_label(&outline, "Gone").expect("the missing clip is still a lane");
    assert_eq!(
        gone["offline"].as_str(),
        Some("missing"),
        "the missing clip should say why, not vanish"
    );
    // It keeps its place in time. An offline clip is still an edit, and a timeline that dropped
    // it would lose the work as well as the file.
    let spans = gone["onscreen"].as_array().expect("still on screen for its stretch");
    assert!(!spans.is_empty(), "the offline clip lost its place in the timeline");

    let here = by_label(&outline, "Here").expect("the image that is there");
    assert!(here["offline"].is_null(), "a file that is there is not offline");

    // And the composition is still moving: the tweens survived.
    let tracks = outline["tracks"].as_array().expect("movements");
    assert!(tracks.len() >= 2, "the movements went with the missing file: {}", tracks.len());

    // A frame comes back, and both halves of it are true: the picture that is there is painted,
    // and where the missing clip would have been there is a slate rather than a hole. A hole
    // reads as a bug in the app; the same flat slate every time reads as what it is.
    let (rgba, w, h) = engine.frame(2.0).expect("a frame");
    assert_eq!((w, h), (640, 360));
    assert_eq!(rgba.len(), (w * h * 4) as usize);
    let at = |x: u32, y: u32| {
        let i = ((y * w + x) * 4) as usize;
        (rgba[i], rgba[i + 1], rgba[i + 2])
    };
    let background = (0x0b, 0x0d, 0x12);
    let left = at(w / 4, h / 2);
    let right = at(w * 3 / 4, h / 2);
    assert_ne!(left, background, "the photograph that is there stopped painting");
    assert_ne!(right, background, "the missing clip left a hole instead of a slate");
    assert_ne!(left, right, "the slate and the picture came out the same colour");
    // A slate is grey: it is deliberately not a colour that could be mistaken for footage.
    let (r, g, b) = right;
    let spread = r.max(g).max(b) - r.min(g).min(b);
    assert!(spread <= 8, "the slate is not grey: {right:?}");

    eprintln!(
        "offline   {} nodes, 1 offline ({}), {} movements; a frame at {w}x{h}: picture {left:?}, slate {right:?}",
        nodes(&outline).len(),
        gone["offline"].as_str().unwrap_or("?"),
        tracks.len(),
    );
    engine.stop();
}

/// The rule the whole app is built on, tested where it is most tempting to break: the one time
/// the app has a really good reason to print a path is when it is telling you a path is wrong.
#[test]
fn what_is_offline_is_said_without_naming_a_file() {
    let Some(root) = root() else { return };
    let (proj, comp, serve) = project(
        &root,
        "quiet",
        r##"local e = require("moonsplice")
return e.comp {
  width = 320, height = 180, duration = 3, fps = 30, background = "#0b0d12",
  scene = function(s)
    s:image { src = "Stills/a_very_distinctive_missing_name.png", x = 0, y = 0, w = 320, h = 180 }
    s:audio { src = "Sound/another_distinctive_absence.wav", at = 0, duration = 3 }
    s:text { x = 12, y = 90, text = "Fine", size = 20 }
  end,
}
"##,
        &[],
    );
    let Some(engine) = open(&comp, &proj, &serve) else { return };
    let outline = engine.outline("test").expect("an outline");
    let text = serde_json::to_string(&outline).expect("the outline serialises");

    // The label is the words a person would use for the thing, worked out from the file's own
    // stem. That is the name that may appear; the path around it may not.
    for forbidden in [
        "a_very_distinctive_missing_name",
        "another_distinctive_absence",
        "Stills/",
        "Sound/",
        ".png",
        ".wav",
    ] {
        assert!(
            !text.contains(forbidden),
            "the outline named a file: {forbidden}\n{text}"
        );
    }

    let offline: Vec<&str> = nodes(&outline)
        .iter()
        .filter_map(|n| n["offline"].as_str())
        .collect();
    assert_eq!(offline.len(), 2, "both missing things should be offline: {offline:?}");
    // The word is from the closed set the vocabulary has a sentence for. Anything else and the
    // app either shows a word nobody wrote or falls back to saying nothing useful.
    let known = ["missing", "unreadable", "needs a key", "would not load"];
    for word in &offline {
        assert!(known.contains(word), "no sentence for {word:?}");
    }
    // Named the way the timeline names it, which is the whole substitute for the path.
    let names: Vec<&str> = nodes(&outline).iter().filter_map(|n| n["label"].as_str()).collect();
    // "Stills/a_very_distinctive_missing_name.png" -> "A very distinctive missing name". The
    // underscores go, the folder goes, the extension goes, and what is left is what somebody
    // would have called it out loud -- which is the whole substitute for the path.
    assert!(
        names.iter().any(|n| *n == "A very distinctive missing name"),
        "the missing thing lost its name as well as its file: {names:?}"
    );
    assert!(
        names.iter().any(|n| *n == "Another distinctive absence"),
        "the missing sound lost its name: {names:?}"
    );

    eprintln!("quiet     {offline:?}, named {names:?}");
    engine.stop();
}

/// A sound whose file is not there still has a length, a place and a lane.
///
/// This is the one that used to fail after everything else was fixed: an offline sound has no
/// file to ask how long it is, and a sound with no length is a sound the timeline cannot draw
/// and the mix cannot place -- so the composition opened and the timeline came back wrong.
#[test]
fn a_missing_sound_keeps_its_place_and_its_length() {
    let Some(root) = root() else { return };
    let (proj, comp, serve) = project(
        &root,
        "sound",
        r##"local e = require("moonsplice")
return e.comp {
  width = 320, height = 180, duration = 30, fps = 30, background = "#0b0d12",
  scene = function(s)
    s:rect { x = 0, y = 0, w = 320, h = 180, color = "#101828" }
    s:audio { src = "Sound/gone-with-a-length.wav", label = "Told", at = 5, duration = 9 }
    s:audio { src = "Sound/gone-with-no-length.wav", label = "Untold", at = 20 }
  end,
}
"##,
        &[],
    );
    let Some(engine) = open(&comp, &proj, &serve) else { return };
    let outline = engine.outline("test").expect("an outline");
    let audio = outline["audio"].as_array().expect("a sound list").clone();
    assert_eq!(audio.len(), 2, "an offline sound is still a sound");

    let told = audio.iter().find(|a| a["label"].as_str() == Some("Told")).expect("Told");
    assert_eq!(told["at"].as_f64(), Some(5.0), "it moved");
    assert_eq!(told["duration"].as_f64(), Some(9.0), "it lost the length it was written with");

    let untold = audio.iter().find(|a| a["label"].as_str() == Some("Untold")).expect("Untold");
    let len = untold["duration"].as_f64().unwrap_or(0.0);
    assert!(len > 0.0, "a sound with no length cannot be drawn: {len}");
    assert_eq!(untold["at"].as_f64(), Some(20.0), "it moved");

    eprintln!("sound     Told {}s at {}s, Untold {len}s at 20s", 9.0, 5.0);
    engine.stop();
}

/// The other half of the bargain: a render still refuses.
///
/// Tolerance is the app's, not the renderer's. A slate that quietly ships inside an export is a
/// far worse failure than one that stops the export, and the difference between the two is one
/// environment variable -- so it is worth a test that the variable is actually what decides,
/// rather than something that drifted into being always on.
#[test]
fn without_being_asked_the_renderer_still_refuses() {
    let Some(root) = root() else { return };
    let (proj, comp, _serve) = project(
        &root,
        "strict",
        r##"local e = require("moonsplice")
return e.comp {
  width = 320, height = 180, duration = 2, fps = 30, background = "#0b0d12",
  scene = function(s)
    s:image { src = "Stills/definitely-not-here.png", x = 0, y = 0, w = 320, h = 180 }
  end,
}
"##,
        &[],
    );
    let out = std::process::Command::new(root.join("moonsplice"))
        .arg("check")
        .arg(comp.strip_prefix(&proj).unwrap_or(&comp))
        .current_dir(&proj)
        .output();
    let Ok(out) = out else {
        eprintln!("skipped: no moonsplice");
        return;
    };
    assert!(
        !out.status.success(),
        "the renderer accepted a missing file when nobody asked it to be tolerant"
    );
    eprintln!("strict    refused, as it should");
}

/// A save that will not load: what the window is shown, and what it is told.
///
/// The app watches the project, so a text editor, a script or the agent's own write all arrive
/// here. When one of them leaves the composition unable to load, the engine keeps the version it
/// already had and the preview goes on painting it -- which is the right picture to keep showing
/// and the wrong one to show in silence, because from that moment the file and the window have
/// stopped being the same composition and nothing on screen says so.
///
/// So: the reload refuses, the refusal is a sentence rather than a stack trace, the picture still
/// comes, and the moment the file loads again everything catches up.
#[test]
fn a_save_that_stops_the_composition_loading_is_said_out_loud() {
    let Some(root) = root() else { return };
    let good = r##"local e = require("moonsplice")
return e.comp {
  width = 320, height = 180, duration = 3, fps = 30, background = "#0b0d12",
  scene = function(s)
    s:text { x = 20, y = 80, text = "Before", size = 24, label = "Line" }
  end,
}
"##;
    let (proj, comp, serve) = project(&root, "save", good, &[]);
    let Some(engine) = open(&comp, &proj, &serve) else { return };

    let before = engine.outline("one").expect("an outline");
    assert!(by_label(&before, "Line").is_some());
    let (rgba, w, h) = engine.frame(1.0).expect("a frame");
    assert_eq!(rgba.len(), (w * h * 4) as usize);

    // Somebody saves something that does not load. `nope` is not a function.
    std::fs::write(
        &comp,
        r##"local e = require("moonsplice")
return e.comp {
  width = 320, height = 180, duration = 3, fps = 30, background = "#0b0d12",
  scene = function(s)
    s:text { x = 20, y = 80, text = nope(), size = 24, label = "Line" }
  end,
}
"##,
    )
    .expect("the bad save lands");

    let refused = engine.reload().expect_err("that should not have loaded");
    let said = moonsplice_studio_lib::engine::in_words(&refused.to_string());
    assert!(!said.is_empty(), "the refusal said nothing at all");
    // What reaches the window is a sentence. Not a path, not a line number, not the name of a
    // file the person has never been shown and cannot open.
    assert!(!said.contains("Take.lua"), "the refusal named the file: {said}");
    assert!(!said.contains(".lua"), "the refusal named a file: {said}");
    assert!(
        !regex_lite_has_line_ref(&said),
        "the refusal carried a line number: {said}"
    );

    // And the app still has a composition. This is what the preview goes on painting while the
    // strip over it says the picture is the last one that worked.
    let still = engine.outline("one").expect("the last version that loaded");
    assert!(
        by_label(&still, "Line").is_some(),
        "the engine threw away the version that worked"
    );
    let (rgba, w, h) = engine.frame(1.5).expect("a frame from the last good version");
    assert_eq!(rgba.len(), (w * h * 4) as usize);

    // Put it right, and it catches up with no restart.
    std::fs::write(&comp, good.replace("Before", "After")).expect("the good save lands");
    engine.reload().expect("it loads again");
    let after = engine.outline("two").expect("an outline");
    let line = by_label(&after, "Line").expect("the line");
    assert_eq!(
        line["props"]["text"].as_str(),
        Some("After"),
        "the repaired version did not reach the app"
    );

    eprintln!("save      refused with: {said:?}, then caught up");
    engine.stop();
}

/// `file.lua:59:` and friends, without pulling a regex crate into the tests.
fn regex_lite_has_line_ref(s: &str) -> bool {
    s.split_whitespace().any(|w| {
        let mut parts = w.split(':');
        let (Some(_), Some(n)) = (parts.next(), parts.next()) else {
            return false;
        };
        !n.is_empty() && n.chars().all(|c| c.is_ascii_digit())
    })
}
