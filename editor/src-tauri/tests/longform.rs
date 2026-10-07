//! A ten minute edit, opened and measured the way a person uses one.
//!
//! The rest of the suite works on three second cases, and three seconds hides everything that
//! only appears at length: whether a seek to nine minutes costs more than a seek to nine seconds,
//! whether an outline of two hundred nodes still arrives while somebody is looking, whether a
//! hundred audio nodes cost anything to place, whether the frame cache is any use once the
//! composition is longer than the cache.
//!
//! The fixture is made rather than committed -- ten minutes of footage does not belong in git:
//!
//!     bin/moonsplice-longform                 # writes evals/longform/
//!
//! Without it these skip, and say so. With it:
//!
//!     MOONSPLICE_LONGFORM=$PWD/evals/longform cargo test --test longform -- --nocapture

use std::time::Instant;

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::perf::load_average;
use moonsplice_studio_lib::project::Project;

mod longform_common;
use longform_common::*;

/// The project as the left pane sees it: folders, compositions, footage, sound.
#[test]
fn a_ten_minute_project_opens_like_any_other() {
    let _alone = alone();
    let Some(root) = longform() else { return };
    let started = Instant::now();
    let project = Project::open(&root).expect("the long-form project opens");
    let opened = started.elapsed();
    let view = project.view();

    eprintln!(
        "\nproject     opened in {:.0} ms: {} compositions, {} assets",
        ms(opened),
        view.compositions.len(),
        view.assets.len()
    );

    assert!(view.compositions.len() >= 2, "the tour and the cutdown");
    assert!(view.assets.len() >= 60, "the footage, the narration, the bed and the effects");
    // The pane is the project's own folders, and this project has two.
    let folders: Vec<&str> = view
        .tree
        .iter()
        .filter_map(|i| match i {
            moonsplice_studio_lib::project::Item::Folder { name, .. } => Some(name.as_str()),
            _ => None,
        })
        .collect();
    assert!(folders.contains(&"Footage"), "{folders:?}");
    assert!(folders.contains(&"Sound"), "{folders:?}");

    // And still no paths anywhere in what the window is handed.
    let said = serde_json::to_string(&view).unwrap();
    for leak in [".mp4", ".mp3", ".lua", "/Users/", "/tmp/"] {
        assert!(!said.contains(leak), "{leak} reached the window");
    }
    assert!(
        ms(opened) < 2000.0,
        "opening the project took {:.0} ms",
        ms(opened)
    );
}

/// The property that matters most at length: a composition is `f(t)`, so the ten minute mark must
/// cost what the ten second mark costs. If it does not, something is walking the timeline from
/// zero, and every seek in the second half of the edit pays for it.
#[test]
fn seeking_late_costs_what_seeking_early_costs() {
    let _alone = alone();
    let Some(root) = longform() else { return };
    let comp = root.join("A place.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("seek")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let duration = engine.meta.duration;
    eprintln!(
        "\nload average {:.1}; {} x {} @ {:.0} fps, {:.0} s",
        load_average(),
        engine.meta.width,
        engine.meta.height,
        engine.meta.fps,
        duration
    );

    // Warm the process: the first frame of anything pays for fonts and decoders.
    let _ = engine.frame(0.0);

    let mut early = Vec::new();
    let mut late = Vec::new();
    for i in 0..12 {
        // Spread across each half, and never twice at the same time -- a repeat would measure
        // the renderer's own caches rather than the seek.
        let a = duration * 0.02 + i as f64 * 0.37;
        let b = duration * 0.55 + i as f64 * 0.37;
        let t = Instant::now();
        engine.frame(a).expect("an early frame");
        early.push(ms(t.elapsed()));
        let t = Instant::now();
        engine.frame(b).expect("a late frame");
        late.push(ms(t.elapsed()));
    }
    let (e50, e95) = middle(early);
    let (l50, l95) = middle(late);
    eprintln!("  first half   p50 {e50:.1} ms  p95 {e95:.1}");
    eprintln!("  second half  p50 {l50:.1} ms  p95 {l95:.1}");

    // Generous, because a clip decoding at nine minutes really does have more to do than one at
    // nine seconds -- what this is here to catch is the linear kind of cost, which shows up as
    // multiples, not as a quarter.
    assert!(
        l50 < e50 * 3.0 + 20.0,
        "seeking late costs {l50:.1} ms against {e50:.1} ms early: something is walking the timeline"
    );
}

/// Two hundred nodes, sixty of them audio, is a shape the timeline has to draw. The outline is
/// what it draws from, so the outline has to arrive while somebody is still looking at the screen.
#[test]
fn the_outline_of_a_long_edit_arrives_at_once() {
    let _alone = alone();
    let Some(root) = longform() else { return };
    let comp = root.join("A place.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("outline")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let started = Instant::now();
    let outline = engine.outline("stress").expect("an outline");
    let took = started.elapsed();

    let nodes = outline["nodes"].as_array().map(|a| a.len()).unwrap_or(0);
    let tracks = outline["tracks"].as_array().map(|a| a.len()).unwrap_or(0);
    let audio = outline["audio"].as_array().map(|a| a.len()).unwrap_or(0);
    let bytes = serde_json::to_string(&outline).unwrap().len();
    eprintln!(
        "\noutline   {nodes} nodes, {tracks} movements, {audio} sounds, {} KB, in {:.0} ms",
        bytes / 1024,
        ms(took)
    );

    assert!(nodes >= 20, "a long edit has things in it: {nodes}");
    assert!(audio >= 60, "the narration is in the mix: {audio}");
    assert!(
        ms(took) < 3000.0,
        "the outline took {:.0} ms, which is long enough to watch",
        ms(took)
    );

    // Every sound the mix holds is placed somewhere real, and none of it reaches the window as a
    // file name -- the thing that stays true however many of them there are.
    let said = serde_json::to_string(&outline).unwrap();
    for leak in [".mp3", ".mp4", "/Users/"] {
        assert!(!said.contains(leak), "{leak} reached the window");
    }
    let late = outline["audio"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|a| a["at"].as_f64().unwrap_or(0.0) > engine.meta.duration * 0.5)
        .count();
    assert!(late > 0, "the second half has sound in it too");
    engine.stop();
}

/// The thing a long edit measures that a short one cannot: what an invisible thing costs.
///
/// One chapter of this fixture moves three cards under a camera. A card in perspective is the
/// most expensive thing a frame can hold -- a canvas the size of the composition, cleared, drawn
/// into and read back off the GPU -- and it was being built on every frame of the edit, including
/// the 588 seconds where the cards sit at zero opacity and put nothing on screen. Measured, that
/// was 21 ms of a 45 ms frame, spent on three cards nobody could see.
///
/// So this asserts a ratio rather than a number: a second of the edit where the cards are away
/// must be meaningfully cheaper than a second where they are on screen. A ratio survives a busy
/// machine, and the defect it is here to catch made the two the same.
#[test]
fn a_chapter_nobody_can_see_costs_nothing() {
    let _alone = alone();
    let Some(root) = longform() else { return };
    let comp = root.join("A place.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("unseen")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let fps = engine.meta.fps.max(1.0);
    let _ = engine.frame(0.0);

    // 180 s is where the map chapter opens; the cards fade up over the first second and are
    // gone again by about 195. 240 s is the chapter after it, which holds no perspective at all.
    let mut seen = Vec::new();
    let mut away = Vec::new();
    for i in 0..16 {
        // Interleaved, so anything that comes and goes on this machine lands on both sides.
        let t = Instant::now();
        engine.frame_measured(186.0 + i as f64 / fps, Some(1280)).expect("a frame");
        seen.push(ms(t.elapsed()));
        let t = Instant::now();
        engine.frame_measured(246.0 + i as f64 / fps, Some(1280)).expect("a frame");
        away.push(ms(t.elapsed()));
    }
    // The cheapest of each, not the middle: what a frame costs is what it costs when nothing
    // else is in the way, and every sample above that is something else on the machine.
    let least = |v: &[f64]| v.iter().cloned().fold(f64::INFINITY, f64::min);
    let (with, without) = (least(&seen), least(&away));
    eprintln!("\ncards      on screen {with:.1} ms a frame, away {without:.1} ms");

    assert!(
        without < with * 0.8,
        "a frame with the cards away costs {without:.1} ms against {with:.1} ms with them on \
         screen: something invisible is still being drawn"
    );
    engine.stop();
}

/// Scenario: a sound in the timeline shows what it sounds like
///
/// Seventy lanes of identical grey tell you there is narration at four minutes; they do not tell
/// you whether it is a sentence or a breath. The shape is the only thing that makes a sound lane
/// readable — and it is the one thing the outline cannot carry, because the outline has no paths
/// in it and a waveform is read off a file.
///
/// So the path travels a second way: `media`, which the host asks for and the window never sees.
/// This is that road end to end, on the sixty narration clips of the long-form edit.
#[test]
fn a_sound_in_the_timeline_shows_what_it_sounds_like() {
    let _alone = alone();
    let Some(root) = longform() else { return };
    let comp = root.join("A place.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("sound")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };

    // Every sound the composition holds, with the file behind it. This reply carries paths and
    // is the only one that does.
    let started = Instant::now();
    let media = engine.media().expect("where the files are");
    eprintln!("\nmedia     {} files in {:.0} ms", media.len(), ms(started.elapsed()));
    assert!(media.len() >= 60, "the narration, the bed and the effects: {}", media.len());

    // And none of it is in the outline, which is what the window is handed.
    let outline = engine.outline("shape").expect("an outline");
    let said = serde_json::to_string(&outline).unwrap();
    for leak in [".mp3", ".mp4", "/Users/"] {
        assert!(!said.contains(leak), "{leak} reached the window");
    }
    // But how long each file is does reach it, because a trimmed clip has to draw the part of
    // the sound it actually plays and that cannot be worked out without it.
    let lengths = outline["audio"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|a| a["media_duration"].as_f64().is_some_and(|d| d > 0.0))
        .count();
    assert!(lengths >= 60, "only {lengths} sounds said how long their file is");

    let shapes = moonsplice_studio_lib::waveform::Waveforms::new();
    let mut ids: Vec<&String> = media.keys().collect();
    ids.sort();

    // A dozen of them, read for real through ffmpeg.
    let started = Instant::now();
    let mut read = 0usize;
    let mut loudest = 0u8;
    for id in ids.iter().take(12) {
        let path = &media[*id];
        match shapes.of(path) {
            Ok(peaks) => {
                assert_eq!(peaks.len(), moonsplice_studio_lib::waveform::BUCKETS);
                loudest = loudest.max(*peaks.iter().max().unwrap());
                // A spoken line is not a flat block: it has pauses in it, and that is precisely
                // what somebody scanning a narration track is looking at.
                let quietest = *peaks.iter().min().unwrap();
                assert!(quietest < loudest, "{id} drew as a solid block");
                read += 1;
            }
            Err(why) => {
                eprintln!("skipped: {why}");
                return;
            }
        }
    }
    let took = ms(started.elapsed());
    eprintln!(
        "shapes    {read} sounds read in {took:.0} ms ({:.0} ms each), loudest {loudest}",
        took / read.max(1) as f64
    );
    assert!(loudest > 60, "the narration is not silence");
    assert_eq!(shapes.held(), read, "each one read once");

    // Asked again, nothing is read: a lane that scrolls back into view costs nothing.
    let started = Instant::now();
    for id in ids.iter().take(12) {
        shapes.of(&media[*id]).expect("already known");
    }
    let again = ms(started.elapsed());
    eprintln!("          and again in {again:.1} ms");
    assert!(again < took / 4.0 + 5.0, "the second pass read the files again: {again:.1} ms");
    engine.stop();
}
