//! The stack end to end, against real compositions (the suite's description is in tests/common/mod.rs):
//! what the engine measures, and projects: empty compositions, folders, spoken lines, export, an edit the engine cannot load.

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::project::Project;
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::words;
use moonsplice_studio_lib::Gesture;

mod common;
use common::*;

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
