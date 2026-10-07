//! Playback, measured. Cold and warm, on real compositions, through the real renderer.
//!
//! Choppy preview is not one problem, it is a budget shared by four steps: the engine evaluating
//! and rasterising a frame, the frame crossing the process boundary, this side scaling and
//! encoding it, and the webview decoding the result. The first three are reachable from a test,
//! and this measures them per frame rather than in aggregate, because an average of 20 ms hides
//! the one frame in thirty that took 300 and is the frame a person actually sees.
//!
//! What it prints is the table; what it asserts is the shape of the table: the warm path must be
//! able to feed the composition's own frame rate, and the cache must answer in microseconds.
//! Anything that cannot find the engine skips, like the rest of this suite.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::frames::{rgba_to_jpeg, scale_rgba, FrameCache, FrameKey};
use moonsplice_studio_lib::perf::load_average;

fn root() -> Option<PathBuf> {
    moonsplice_studio_lib::engine::moonsplice_root()
}

fn serve_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("moonsplice-studio-perf-{name}-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&d);
    d
}

/// Times, sorted, so a percentile is a lookup.
struct Spread(Vec<Duration>);

impl Spread {
    fn of(mut v: Vec<Duration>) -> Spread {
        v.sort();
        Spread(v)
    }
    fn at(&self, q: f64) -> f64 {
        if self.0.is_empty() {
            return 0.0;
        }
        let i = ((self.0.len() - 1) as f64 * q).round() as usize;
        self.0[i].as_secs_f64() * 1000.0
    }
    fn worst(&self) -> f64 {
        self.at(1.0)
    }
}

struct Pass {
    render: Spread,
    /// Scaling to the pane. The live path stops here: the window paints the pixels.
    scale: Spread,
    /// The same frame as a JPEG, which is what the path used to cost on this side alone.
    jpeg: Spread,
    total: Spread,
}

/// One playback pass: every frame of `secs` seconds at the composition's own rate, in order,
/// which is the order playback asks for them in.
fn play(engine: &Engine, w: u32, h: u32, secs: f64) -> Pass {
    let fps = if engine.meta.fps > 0.0 { engine.meta.fps } else { 30.0 };
    let n = ((secs * fps) as usize).max(1);
    let mut render = Vec::with_capacity(n);
    let mut scale = Vec::with_capacity(n);
    let mut jpeg = Vec::with_capacity(n);
    let mut total = Vec::with_capacity(n);
    for i in 0..n {
        let t = i as f64 / fps;
        if t > engine.meta.duration {
            break;
        }
        let start = Instant::now();
        let (rgba, sw, sh) = engine.frame(t).expect("a frame");
        let rendered = Instant::now();
        let (pixels, _, _) = scale_rgba(&rgba, sw, sh, w, h).expect("scaled");
        let scaled = Instant::now();
        let picture = rgba_to_jpeg(&rgba, sw, sh, w, h, 82).expect("encoded");
        let done = Instant::now();
        assert!(!pixels.is_empty() && !picture.is_empty());
        render.push(rendered - start);
        scale.push(scaled - rendered);
        jpeg.push(done - scaled);
        total.push(scaled - start);
    }
    Pass {
        render: Spread::of(render),
        scale: Spread::of(scale),
        jpeg: Spread::of(jpeg),
        total: Spread::of(total),
    }
}

/// The compositions measured, and what each one is here to show. A pane of 960x540 is what a
/// window on this machine actually asks for.
const PANE: (u32, u32) = (960, 540);

fn case(root: &Path, name: &str) -> PathBuf {
    root.join("comps/cases").join(format!("{name}.lua"))
}

#[test]
fn playback_keeps_up_cold_and_warm() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    eprintln!("load average {:.1}", load_average());

    // Shapes only, a clip, and type: the three costs a composition is usually made of.
    let cases = ["primitives", "video", "type"];
    let mut budget_checked = false;

    for name in cases {
        let comp = case(&root, name);
        if !comp.is_file() {
            eprintln!("skipped {name}: no such case");
            continue;
        }

        // Cold is the whole of it: the process starting, the composition loading, the first frame
        // arriving. This is what a person waits through when they open a composition.
        let started = Instant::now();
        let engine = match Engine::start(&comp, &root, &serve_dir(name)) {
            Ok(e) => e,
            Err(why) => {
                eprintln!("skipped {name}: {why}");
                continue;
            }
        };
        let up = started.elapsed();
        let first = Instant::now();
        let (rgba, sw, sh) = engine.frame(0.0).expect("the first frame");
        let first_frame = first.elapsed();
        let enc = Instant::now();
        let jpeg = rgba_to_jpeg(&rgba, sw, sh, PANE.0, PANE.1, 82).expect("encoded");
        let first_encode = enc.elapsed();

        // Warm is the pass after that: the same process, the caches inside it filled, which is
        // the state playback actually runs in.
        let first_pass = play(&engine, PANE.0, PANE.1, 1.0);
        let second_pass = play(&engine, PANE.0, PANE.1, 1.0);

        let fps = engine.meta.fps.max(1.0);
        let budget = 1000.0 / fps;
        eprintln!(
            "\n{name}  {}x{} @ {:.0} fps  ({:.1} ms a frame to spend)",
            engine.meta.width, engine.meta.height, fps, budget
        );
        eprintln!(
            "  cold      engine up {:.0} ms, first frame {:.0} ms, first encode {:.1} ms, {} KB",
            up.as_secs_f64() * 1000.0,
            first_frame.as_secs_f64() * 1000.0,
            first_encode.as_secs_f64() * 1000.0,
            jpeg.len() / 1024
        );
        for (label, pass) in [("pass 1", &first_pass), ("pass 2", &second_pass)] {
            eprintln!(
                "  {label}    render p50 {:.1} p95 {:.1} worst {:.1} | scale p50 {:.1} p95 {:.1} | live p50 {:.1} p95 {:.1} worst {:.1}  = {:.0} fps   (a jpeg of the same frame: {:.1})",
                pass.render.at(0.5),
                pass.render.at(0.95),
                pass.render.worst(),
                pass.scale.at(0.5),
                pass.scale.at(0.95),
                pass.total.at(0.5),
                pass.total.at(0.95),
                pass.total.worst(),
                1000.0 / pass.total.at(0.5).max(0.001),
                pass.jpeg.at(0.5),
            );
        }

        // The budget is asserted where it is honest to assert it: shapes at 1280x720 are the
        // cheapest thing this renderer does, so if that cannot feed the frame rate on a second
        // pass, the frame path has a problem that is not the composition's fault.
        // The budget is asserted where it is honest to assert it: shapes at 1280x720 are the
        // cheapest thing this renderer does, and only on a machine that is not busy doing
        // something else -- a timing on a loaded laptop measures the laptop.
        if name == "primitives" {
            let p50 = second_pass.total.at(0.5);
            if load_average() > 4.0 {
                eprintln!("  (not asserted: load average {:.1})", load_average());
            } else {
                budget_checked = true;
                assert!(
                    p50 < budget,
                    "warm playback of {name} costs {p50:.1} ms a frame against a {budget:.1} ms budget"
                );
            }
        }
        engine.stop();
    }
    if !budget_checked {
        eprintln!("nothing was asserted: the machine was too busy for a timing to mean anything");
    }
}

#[test]
fn a_frame_already_seen_comes_back_in_microseconds() {
    // The second time the playhead crosses a frame, nothing should reach the engine at all. This
    // is the whole reason a scrub back and forth over the same second feels different from the
    // first pass over it.
    let cache = FrameCache::new(64 * 1024 * 1024);
    let jpeg = vec![7u8; 90 * 1024];
    let key = |t: u32| FrameKey {
        variation: "hero".into(),
        hash: "abc".into(),
        t_ms: t,
        w: 960,
        h: 540,
        raw: true,
    };
    for t in 0..300 {
        cache.put(key(t * 33), jpeg.clone(), 960, 540);
    }
    let start = Instant::now();
    let mut got = 0usize;
    for t in 0..300 {
        got += cache.get(&key(t * 33)).map(|f| f.bytes.len()).unwrap_or(0);
    }
    let each = start.elapsed().as_secs_f64() * 1e6 / 300.0;
    eprintln!("cache hit: {each:.1} us a frame, {} MB held", got / 1024 / 1024);
    assert!(each < 200.0, "a cache hit cost {each:.1} us");
    let (hits, misses, _) = cache.stats();
    assert_eq!((hits, misses), (300, 0), "every one of them hit");
}

/// Scenario: playing gives up size to keep time
///
/// The one lever the player has that does not need a different renderer. A preview is
/// rasterised on the CPU, so what it costs goes with its area: asked for at half the width it
/// has a quarter of the work to do, and the frame a person is watching arrives four times
/// sooner. Every editor in the world does this and says so in a menu.
///
/// This is the measurement the window's controller is built on -- `pace()` in `player.ts` solves
/// `cost ∝ area` for the budget -- so if that relationship is not true of this renderer, the
/// controller is aiming at nothing. What is asserted is the relationship, generously: half the
/// width must cost decidedly less than full, and a quarter less again.
#[test]
fn playing_gives_up_size_to_keep_time() {
    let Some(root) = root() else {
        eprintln!("skipped: no checkout found");
        return;
    };
    eprintln!("load average {:.1}", load_average());

    for name in ["primitives", "type"] {
        let comp = case(&root, name);
        if !comp.is_file() {
            eprintln!("skipped {name}: no such case");
            continue;
        }
        let engine = match Engine::start(&comp, &root, &serve_dir(&format!("size-{name}"))) {
            Ok(e) => e,
            Err(why) => {
                eprintln!("skipped {name}: {why}");
                continue;
            }
        };
        // The first frame of anything pays for fonts and decoders; it is not what playback costs.
        let _ = engine.frame(0.0);

        let fps = if engine.meta.fps > 0.0 { engine.meta.fps } else { 30.0 };
        let at = |scale: f64| -> f64 {
            let want = ((PANE.0 as f64 * scale).round() as u32).max(2);
            let mut took = Vec::new();
            for i in 0..24 {
                let t = i as f64 / fps;
                if t > engine.meta.duration {
                    break;
                }
                let start = Instant::now();
                engine
                    .frame_measured(t, Some(want))
                    .expect("a frame at that size");
                took.push(start.elapsed());
            }
            Spread::of(took).at(0.5)
        };

        // Interleaved rather than one run after the other: a machine that got busy half way
        // through would otherwise be measured as a renderer that got slower.
        let (mut full, mut half, mut quarter) = (Vec::new(), Vec::new(), Vec::new());
        for _ in 0..3 {
            full.push(at(1.0));
            half.push(at(0.5));
            quarter.push(at(0.25));
        }
        let best = |v: Vec<f64>| v.into_iter().fold(f64::MAX, f64::min);
        let (full, half, quarter) = (best(full), best(half), best(quarter));
        eprintln!(
            "\n{name:<12} full {full:>6.1} ms   half {half:>6.1} ms ({:.0}%)   quarter \
             {quarter:>6.1} ms ({:.0}%)",
            100.0 * half / full,
            100.0 * quarter / full,
        );

        // Generous on purpose. The exact ratio depends on how much of the frame is rasterising
        // and how much is fixed cost per frame; what the controller needs is only that asking
        // for less picture buys real time, and keeps buying it.
        assert!(
            half < full * 0.85,
            "{name}: half size cost {half:.1} ms against {full:.1} ms full -- asking for less \
             picture bought nothing, so the player has no lever"
        );
        assert!(
            quarter <= half,
            "{name}: a quarter cost {quarter:.1} ms against {half:.1} ms at half"
        );
        engine.stop();
    }
}
