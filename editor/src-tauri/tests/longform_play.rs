//! A ten minute edit, played: from three places, and with the playhead dropped anywhere in it.
//! The fixture and how to make it are described in longform.rs; run these with `--test longform_play`.

use std::time::Instant;

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::frames::scale_rgba;
use moonsplice_studio_lib::perf::load_average;

mod longform_common;
use longform_common::*;

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
