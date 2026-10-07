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

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::frames::{FrameCache, FrameKey};
use moonsplice_studio_lib::project::Project;

mod spec_common;
use spec_common::*;

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
