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

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Instant;

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::frames::scale_rgba;
use moonsplice_studio_lib::perf::load_average;
use moonsplice_studio_lib::project::Project;

/// Where the long-form project is, if it has been made.
fn longform() -> Option<PathBuf> {
    let named = std::env::var("MOONSPLICE_LONGFORM").ok().map(PathBuf::from);
    let here = moonsplice_studio_lib::engine::moonsplice_root().map(|r| r.join("evals/longform"));
    for p in [named, here].into_iter().flatten() {
        if p.join("A place.lua").is_file() {
            return Some(p);
        }
    }
    eprintln!("skipped: no long-form project (run bin/moonsplice-longform)");
    None
}

fn serve_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("moonsplice-studio-long-{name}-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&d);
    d
}

fn ms(d: std::time::Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

/// One at a time. Every test here starts a renderer and then times it, and four renderers on one
/// machine measure the machine rather than the renderer -- which showed up exactly as you would
/// expect: a ratio that is two to one alone came back five to four under its own siblings.
static ALONE: Mutex<()> = Mutex::new(());

fn alone() -> std::sync::MutexGuard<'static, ()> {
    ALONE.lock().unwrap_or_else(|e| e.into_inner())
}

fn middle(mut v: Vec<f64>) -> (f64, f64) {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let at = |q: f64| v[(((v.len() - 1) as f64) * q).round() as usize];
    (at(0.5), at(0.95))
}

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

/// What a person does with a long edit: jump somewhere, watch a few seconds, jump again. Every
/// number here is printed; what is asserted is that nothing in it is pathological.
#[test]
fn playing_a_long_edit_from_three_places() {
    let _alone = alone();
    let Some(root) = longform() else { return };
    let comp = root.join("A place.lua");
    let engine = match Engine::start(&comp, &root, &serve_dir("play")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let fps = engine.meta.fps.max(1.0);
    let budget = 1000.0 / fps;
    let duration = engine.meta.duration;
    let _ = engine.frame(0.0);

    // The pane, in device pixels, which is what the window asks the renderer for. A composition
    // bigger than the pane is drawn at the pane's size -- playback resolution, the way an editor
    // has always done it -- and the full-size number is printed next to it so the difference is
    // on the record rather than assumed.
    const PANE: u32 = 1280;
    eprintln!("\nplayback  ({:.1} ms a frame to spend, load {:.1})", budget, load_average());
    let mut worst_stage = 0.0f64;
    for (label, at) in [("opening", 0.04), ("the map", 0.32), ("the end", 0.93)] {
        let start = duration * at;
        let mut live = Vec::new();
        let mut full = Vec::new();
        let mut scale_ms = Vec::new();
        for i in 0..(fps as usize) {
            let t = start + i as f64 / fps;
            if t > duration {
                break;
            }
            let began = Instant::now();
            let (rgba, w, h, _) = engine.frame_measured(t, Some(PANE)).expect("a frame");
            let rendered = Instant::now();
            let (pixels, _, _) = scale_rgba(&rgba, w, h, PANE, PANE * 9 / 16).expect("scaled");
            assert!(!pixels.is_empty());
            live.push(ms(began.elapsed()));
            scale_ms.push(ms(rendered.elapsed()));

            // Every fifth frame, the same time at the composition's own size, for the comparison.
            if i % 5 == 0 {
                let began = Instant::now();
                engine.frame(t).expect("a frame at full size");
                full.push(ms(began.elapsed()));
            }
        }
        let (p50, p95) = middle(live);
        let (s50, _) = middle(scale_ms);
        let (f50, _) = middle(full);
        worst_stage = worst_stage.max(p50);
        eprintln!(
            "  {label:<8} at {:>5.0}s   p50 {p50:.1} ms  p95 {p95:.1}  (scale {s50:.1})  = {:.0} fps   (at {}x{}: {f50:.1} ms)",
            start,
            1000.0 / p50.max(0.001),
            engine.meta.width,
            engine.meta.height,
        );
    }

    // A second of real footage at 1920x1080 is not obliged to render in real time on a busy
    // laptop. What it is obliged to do is stay in the neighbourhood -- and the neighbourhood is
    // now three budgets, not ten: measured on a machine at load 13, the three places cost 22,
    // 38 and 18 ms a frame against a 33 ms budget. Ten was a number nothing could fail.
    assert!(
        worst_stage < budget * 3.0,
        "the slowest second cost {worst_stage:.1} ms a frame against a {budget:.1} ms budget"
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
/// Scenario: dropping the playhead anywhere in a long edit costs the same
///
/// The question a ten minute edit asks that a four second card cannot: what does it cost to look
/// at a moment the renderer was not already next to? Every clip in this edit is a minute of
/// 1080p, and a person opening it does not start at zero and walk -- they drop the playhead in
/// the fifth minute because that is the bit they are working on.
///
/// This used to cost nine seconds for one frame, because the decoder only ever seeked *backwards*
/// and a jump forward decoded every frame in between. The picture also has to actually be there:
/// a preview that answers quickly with nothing is not an answer, so each frame is checked against
/// the composition's own background before it is timed.
#[test]
fn dropping_the_playhead_anywhere_in_a_long_edit_costs_the_same() {
    let _alone = alone();
    let Some(root) = longform() else { return };
    let comp = root.join("A place.lua");
    let opening = Instant::now();
    let engine = match Engine::start(&comp, &root, &serve_dir("anywhere")) {
        Ok(e) => e,
        Err(why) => {
            eprintln!("skipped: {why}");
            return;
        }
    };
    let opened = ms(opening.elapsed());
    eprintln!("\nopen      {opened:.0} ms");

    // The composition's own background, so "nothing is there" is measured rather than assumed.
    let bg = [0x0bu8, 0x0d, 0x12];
    let paint = |rgba: &[u8], w: u32, h: u32| -> f64 {
        let other = rgba
            .chunks_exact(4)
            .filter(|px| {
                px[0].abs_diff(bg[0]) > 6 || px[1].abs_diff(bg[1]) > 6 || px[2].abs_diff(bg[2]) > 6
            })
            .count();
        100.0 * other as f64 / (w * h) as f64
    };

    // Warm the process: the first frame of anything pays for fonts and decoders.
    let _ = engine.frame(0.0);

    // A route a person takes. The long hops are the point; the short ones beside them are the
    // control, because what is being measured is the *difference* between a hop and a step.
    let route = [0.0, 300.0, 10.0, 300.5, 20.0, 500.0, 590.0, 5.0];
    let mut hops = Vec::new();
    for t in route {
        let at = Instant::now();
        let (rgba, w, h) = engine.frame(t).expect("a frame");
        let took = ms(at.elapsed());
        let lit = paint(&rgba, w, h);
        eprintln!("  t={t:>6.1}s  {took:>7.1} ms   {lit:>5.1}% painted");
        assert!(
            lit > 5.0,
            "the frame at {t}s is the background and nothing else: the preview would be empty"
        );
        hops.push(took);
    }

    let worst = hops.iter().cloned().fold(0.0, f64::max);
    // Generous: a jump really does cost more than the next frame, because it lands on a keyframe
    // and decodes up to the moment, and six clips may be asked at once. What this catches is the
    // cost that grows with the distance, which is seconds rather than tens of milliseconds.
    assert!(
        worst < 1500.0,
        "the slowest jump in a ten minute edit took {worst:.0} ms: something is decoding through \
         rather than seeking"
    );
    // Opening it is a person waiting at a blank window, so it is held to the same bar the project
    // is. It used to be four seconds, one ffprobe per sound, every single time -- and the app
    // re-reads the composition on every edit.
    assert!(
        opened < 2500.0,
        "opening a ten minute edit took {opened:.0} ms"
    );
    engine.stop();
}
