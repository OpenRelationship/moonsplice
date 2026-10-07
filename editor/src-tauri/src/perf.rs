//! Where the time goes, per frame, always measured.
//!
//! "Playback is choppy" is not a bug report, it is a symptom with four suspects: the engine
//! evaluating and rasterising, the frame crossing the process boundary, this side scaling and
//! encoding it, and the webview decoding and painting. Any one of them can eat a 33 ms budget,
//! and an average hides the one frame in thirty that took 300 ms — which is the frame a person
//! actually notices.
//!
//! So every frame the app serves leaves a record here: the stages, in microseconds, and whether
//! it was a cache hit, a live frame or one warmed ahead. It costs a few atomics and one small
//! push, so it is on in release rather than behind a flag — a measurement you have to turn on is
//! a measurement you take after the complaint instead of before it.
//!
//! Two ways to read it:
//!
//!   * `playback_stats` — percentiles per stage, the hit rate, and what the path could feed.
//!     The app asks for this while playing, which is how it can say *why* it is behind rather
//!     than only that it is.
//!   * `MOONSPLICE_TRACE=/path/trace.json` — every span as a Chrome Trace Event, openable in
//!     ui.perfetto.dev or chrome://tracing. That format rather than OTLP because there is no
//!     collector on a person's laptop, and the spans that matter here are a few hundred
//!     microseconds apart: what is wanted is a timeline you can zoom, not a metrics backend. The
//!     frontend's own spans (`decode`, `paint`) are reported in and land on their own track, so
//!     one trace covers the whole path from `t` to pixels.

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

/// How many frames are kept. At 30 fps this is the last two minutes, which is longer than
/// anybody watches before deciding the preview is choppy.
const KEPT: usize = 3600;

/// What one served frame cost, in microseconds.
#[derive(Debug, Clone, Copy, Default, Serialize)]
pub struct FrameSpan {
    pub t_ms: u32,
    pub w: u32,
    pub h: u32,
    /// True when the frame was wanted for the picture now, false when it was warmed ahead.
    pub live: bool,
    pub hit: bool,
    /// Waiting for the engine: another frame was being rendered. This is the stage that says
    /// the app is asking for more frames than the renderer can make.
    pub wait_us: u64,
    /// The engine: evaluating the composition and rasterising it.
    pub render_us: u64,
    /// Reading the frame back across the process boundary.
    pub read_us: u64,
    /// Scaling to the pane and encoding a JPEG.
    pub encode_us: u64,
    pub total_us: u64,
    pub bytes: usize,
}

/// A span the webview measured, reported in so one trace covers the whole path.
#[derive(Debug, Clone, Deserialize)]
pub struct UiSpan {
    /// `decode`, `paint`, `drop` — what the webview was doing.
    pub name: String,
    /// When it started, on the webview's clock (ms since its own start).
    pub at_ms: f64,
    pub dur_ms: f64,
    pub t_ms: Option<u32>,
}

pub struct Perf {
    epoch: Instant,
    frames: Mutex<std::collections::VecDeque<FrameSpan>>,
    /// Counted rather than derived from the ring, so a long session still reports totals.
    served: AtomicU64,
    hits: AtomicU64,
    warm: AtomicU64,
    /// Frames the webview could not paint in time, reported by the frontend.
    dropped: AtomicU64,
    trace: Mutex<Option<std::fs::File>>,
    tracing: AtomicBool,
    /// The webview's clock has its own zero; the first reported span fixes the offset so both
    /// tracks line up in the trace.
    ui_offset_us: AtomicU64,
}

impl Default for Perf {
    fn default() -> Self {
        Perf::new()
    }
}

impl Perf {
    /// Tracing to wherever `MOONSPLICE_TRACE` says, or nowhere.
    pub fn new() -> Perf {
        match std::env::var("MOONSPLICE_TRACE").ok().filter(|p| !p.is_empty()) {
            Some(p) => Perf::tracing_to(&p),
            None => Perf::quiet(),
        }
    }

    /// Tracing to a named file. Separate from `new` so a test says where its own trace goes
    /// rather than setting an environment variable every other test would then pick up.
    pub fn tracing_to(path: &str) -> Perf {
        let me = Perf::quiet();
        let file = Some(path.to_string()).and_then(|p| {
            let f = std::fs::File::create(&p);
            match f {
                Ok(mut f) => {
                    // A Chrome trace is a JSON array. Writing it as one object per line, opened
                    // with `[` and never closed, is a valid trace to both readers and survives
                    // the app being killed -- which is how a trace of a hang gets taken at all.
                    let _ = f.write_all(b"[\n");
                    log::info!("tracing playback to {p}");
                    Some(f)
                }
                Err(e) => {
                    log::warn!("could not open {p} for tracing: {e}");
                    None
                }
            }
        });
        me.tracing.store(file.is_some(), Ordering::Relaxed);
        *me.trace.lock().expect("trace") = file;
        me
    }

    fn quiet() -> Perf {
        Perf {
            epoch: Instant::now(),
            frames: Mutex::new(std::collections::VecDeque::with_capacity(KEPT)),
            served: AtomicU64::new(0),
            hits: AtomicU64::new(0),
            warm: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
            trace: Mutex::new(None),
            tracing: AtomicBool::new(false),
            ui_offset_us: AtomicU64::new(0),
        }
    }

    /// Microseconds since the app started measuring. The trace's time base.
    fn now_us(&self) -> u64 {
        self.epoch.elapsed().as_micros() as u64
    }

    pub fn record(&self, span: FrameSpan) {
        self.served.fetch_add(1, Ordering::Relaxed);
        if span.hit {
            self.hits.fetch_add(1, Ordering::Relaxed);
        }
        if !span.live {
            self.warm.fetch_add(1, Ordering::Relaxed);
        }
        if self.tracing.load(Ordering::Relaxed) {
            self.write_frame(&span);
        }
        let mut f = self.frames.lock().expect("perf");
        if f.len() == KEPT {
            f.pop_front();
        }
        f.push_back(span);
    }

    pub fn dropped(&self, n: u64) {
        self.dropped.fetch_add(n, Ordering::Relaxed);
    }

    /// Spans from the webview. The first one fixes the clock offset between the two sides.
    pub fn record_ui(&self, spans: &[UiSpan]) {
        if !self.tracing.load(Ordering::Relaxed) {
            for s in spans {
                if s.name == "drop" {
                    self.dropped(1);
                }
            }
            return;
        }
        let now = self.now_us();
        for s in spans {
            if s.name == "drop" {
                self.dropped(1);
            }
            let at = (s.at_ms * 1000.0) as u64;
            if self.ui_offset_us.load(Ordering::Relaxed) == 0 {
                // The webview reported `at` for something that has already happened, so its zero
                // is at most `now - at` ago. Close enough to put the two tracks side by side.
                self.ui_offset_us
                    .store(now.saturating_sub(at), Ordering::Relaxed);
            }
            let ts = self.ui_offset_us.load(Ordering::Relaxed) + at;
            self.event(&s.name, "webview", ts, (s.dur_ms * 1000.0) as u64, s.t_ms, None);
        }
    }

    /// One frame as four spans on their own tracks, so a stall reads as a wide bar rather than a
    /// number in a list.
    fn write_frame(&self, s: &FrameSpan) {
        let end = self.now_us();
        let start = end.saturating_sub(s.total_us);
        let mut at = start;
        let what = if s.hit {
            "cache"
        } else if s.live {
            "frame"
        } else {
            "warm"
        };
        self.event(what, "served", start, s.total_us.max(1), Some(s.t_ms), Some(s.bytes));
        for (name, dur) in [
            ("wait", s.wait_us),
            ("render", s.render_us),
            ("read", s.read_us),
            ("encode", s.encode_us),
        ] {
            if dur == 0 {
                continue;
            }
            self.event(name, "frame path", at, dur, Some(s.t_ms), None);
            at += dur;
        }
    }

    fn event(&self, name: &str, track: &str, ts: u64, dur: u64, t_ms: Option<u32>, bytes: Option<usize>) {
        let tid = match track {
            "served" => 1,
            "frame path" => 2,
            _ => 3,
        };
        let mut args = String::from("{");
        if let Some(t) = t_ms {
            args.push_str(&format!("\"t\":{:.3}", t as f64 / 1000.0));
        }
        if let Some(b) = bytes {
            if args.len() > 1 {
                args.push(',');
            }
            args.push_str(&format!("\"kb\":{}", b / 1024));
        }
        args.push('}');
        let line = format!(
            "{{\"name\":\"{name}\",\"cat\":\"{track}\",\"ph\":\"X\",\"pid\":1,\"tid\":{tid},\"ts\":{ts},\"dur\":{dur},\"args\":{args}}},\n"
        );
        if let Ok(mut f) = self.trace.lock() {
            if let Some(file) = f.as_mut() {
                if file.write_all(line.as_bytes()).is_err() {
                    self.tracing.store(false, Ordering::Relaxed);
                }
            }
        }
    }

    /// What the last `window` frames cost. The app asks for a couple of seconds' worth; a report
    /// asks for everything.
    pub fn stats(&self, window: usize) -> PlaybackStats {
        let f = self.frames.lock().expect("perf");
        let n = f.len();
        let from = n.saturating_sub(window.max(1));
        let recent: Vec<FrameSpan> = f.iter().skip(from).copied().collect();
        drop(f);

        let live: Vec<&FrameSpan> = recent.iter().filter(|s| s.live).collect();
        let rendered: Vec<&FrameSpan> = recent.iter().filter(|s| !s.hit).collect();
        let stage = |pick: fn(&FrameSpan) -> u64, from: &[&FrameSpan]| {
            let mut v: Vec<u64> = from.iter().map(|s| pick(s)).collect();
            v.sort_unstable();
            Percentiles::of(&v)
        };
        PlaybackStats {
            served: self.served.load(Ordering::Relaxed),
            hits: self.hits.load(Ordering::Relaxed),
            warmed: self.warm.load(Ordering::Relaxed),
            dropped: self.dropped.load(Ordering::Relaxed),
            frames: recent.len() as u64,
            hit_rate: if recent.is_empty() {
                0.0
            } else {
                recent.iter().filter(|s| s.hit).count() as f64 / recent.len() as f64
            },
            live: stage(|s| s.total_us, &live),
            wait: stage(|s| s.wait_us, &rendered),
            render: stage(|s| s.render_us, &rendered),
            read: stage(|s| s.read_us, &rendered),
            encode: stage(|s| s.encode_us, &rendered),
            worst: recent.iter().filter(|s| s.live).max_by_key(|s| s.total_us).copied(),
            tracing: self.tracing.load(Ordering::Relaxed),
        }
    }

    /// The one sentence the app can say about why playback is behind. None when it is not.
    pub fn diagnosis(&self, budget_ms: f64) -> Option<String> {
        let s = self.stats(120);
        if s.frames < 12 {
            return None;
        }
        let over = s.live.p50 as f64 / 1000.0;
        if over <= budget_ms {
            return None;
        }
        let stages = [
            ("the renderer", s.render.p50),
            ("reading the frame back", s.read.p50),
            ("encoding the picture", s.encode.p50),
            ("waiting for the renderer", s.wait.p50),
        ];
        let (who, cost) = stages.iter().copied().max_by_key(|(_, us)| *us)?;
        Some(format!(
            "{over:.0} ms a frame against {budget_ms:.0}; most of it is {who} ({:.0} ms)",
            cost as f64 / 1000.0
        ))
    }
}

/// How busy the machine is, one minute averaged. Measurements are only comparable against
/// each other when this is comparable, and on a laptop that is also compiling something it is
/// not: every number a perf test prints comes with this next to it.
pub fn load_average() -> f64 {
    #[cfg(target_os = "linux")]
    if let Ok(s) = std::fs::read_to_string("/proc/loadavg") {
        if let Some(first) = s.split_whitespace().next() {
            return first.parse().unwrap_or(0.0);
        }
    }
    #[cfg(target_os = "macos")]
    if let Ok(out) = std::process::Command::new("sysctl").args(["-n", "vm.loadavg"]).output() {
        // `{ 21.39 16.75 16.23 }`
        let text = String::from_utf8_lossy(&out.stdout);
        if let Some(first) = text.split_whitespace().nth(1) {
            return first.parse().unwrap_or(0.0);
        }
    }
    0.0
}

/// Microseconds, at the three points worth knowing.
#[derive(Debug, Clone, Copy, Default, Serialize)]
pub struct Percentiles {
    pub p50: u64,
    pub p95: u64,
    pub worst: u64,
}

impl Percentiles {
    /// `sorted` must be sorted; an empty one is all zeroes, which reads as "nothing measured".
    pub fn of(sorted: &[u64]) -> Percentiles {
        if sorted.is_empty() {
            return Percentiles::default();
        }
        let at = |q: f64| sorted[(((sorted.len() - 1) as f64) * q).round() as usize];
        Percentiles {
            p50: at(0.5),
            p95: at(0.95),
            worst: at(1.0),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct PlaybackStats {
    /// Everything since the app started.
    pub served: u64,
    pub hits: u64,
    pub warmed: u64,
    pub dropped: u64,
    /// The window these percentiles came from.
    pub frames: u64,
    pub hit_rate: f64,
    /// What a frame the picture was waiting for cost, end to end.
    pub live: Percentiles,
    /// The stages, over the frames that were actually rendered rather than served from cache.
    pub wait: Percentiles,
    pub render: Percentiles,
    pub read: Percentiles,
    pub encode: Percentiles,
    pub worst: Option<FrameSpan>,
    pub tracing: bool,
}

/// A stopwatch that reads in microseconds, because everything here is measured that way.
pub struct Watch(Instant);

impl Watch {
    pub fn start() -> Watch {
        Watch(Instant::now())
    }
    /// Microseconds since the last lap, and reset.
    pub fn lap(&mut self) -> u64 {
        let now = Instant::now();
        let d = now.duration_since(self.0);
        self.0 = now;
        d.as_micros() as u64
    }
    pub fn since(&self) -> Duration {
        self.0.elapsed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn span(total: u64, render: u64, encode: u64, live: bool) -> FrameSpan {
        FrameSpan {
            t_ms: 0,
            w: 960,
            h: 540,
            live,
            hit: false,
            wait_us: 0,
            render_us: render,
            read_us: 0,
            encode_us: encode,
            total_us: total,
            bytes: 60_000,
        }
    }

    #[test]
    fn percentiles_of_nothing_are_nothing() {
        let p = Percentiles::of(&[]);
        assert_eq!((p.p50, p.p95, p.worst), (0, 0, 0));
    }

    #[test]
    fn the_worst_frame_is_kept_not_averaged_away() {
        let perf = Perf::new();
        for _ in 0..99 {
            perf.record(span(8_000, 5_000, 3_000, true));
        }
        perf.record(span(300_000, 290_000, 10_000, true));
        let s = perf.stats(200);
        assert_eq!(s.frames, 100);
        assert_eq!(s.live.p50, 8_000, "one bad frame does not move the middle");
        assert_eq!(s.live.worst, 300_000, "and it is still there to be found");
        assert_eq!(s.worst.map(|w| w.render_us), Some(290_000));
    }

    #[test]
    fn a_cache_hit_is_not_counted_as_a_render() {
        let perf = Perf::new();
        for _ in 0..10 {
            let mut s = span(120, 0, 0, true);
            s.hit = true;
            perf.record(s);
        }
        perf.record(span(40_000, 30_000, 9_000, true));
        let s = perf.stats(100);
        assert_eq!(s.hit_rate, 10.0 / 11.0);
        // The stage percentiles are over rendered frames only, or ten zeroes would say the
        // renderer is instant.
        assert_eq!(s.render.p50, 30_000);
    }

    #[test]
    fn the_diagnosis_names_the_stage_that_is_eating_the_budget() {
        let perf = Perf::new();
        for _ in 0..30 {
            perf.record(span(50_000, 8_000, 40_000, true));
        }
        let said = perf.diagnosis(33.3).expect("it is behind, so it says so");
        assert!(said.contains("encoding the picture"), "{said}");
        assert!(said.contains("40 ms"), "{said}");

        // And says nothing when there is nothing to say.
        let ok = Perf::new();
        for _ in 0..30 {
            ok.record(span(9_000, 5_000, 3_000, true));
        }
        assert!(ok.diagnosis(33.3).is_none());
    }

    #[test]
    fn a_trace_is_written_when_one_is_asked_for() {
        let dir = std::env::temp_dir().join(format!("moonsplice-perf-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("trace.json");
        let perf = Perf::tracing_to(path.to_str().unwrap());
        perf.record(span(20_000, 12_000, 6_000, true));
        perf.record_ui(&[UiSpan {
            name: "decode".into(),
            at_ms: 1.0,
            dur_ms: 4.0,
            t_ms: Some(0),
        }]);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.starts_with("[\n"), "a Chrome trace is an array");
        for want in ["\"name\":\"render\"", "\"name\":\"encode\"", "\"name\":\"decode\""] {
            assert!(text.contains(want), "{want} missing from\n{text}");
        }
        // It parses as a trace: closing the array is all a reader needs.
        let closed = format!("{}]", text.trim_end().trim_end_matches(','));
        let v: serde_json::Value = serde_json::from_str(&closed).expect("valid JSON");
        // The frame, the two stages it actually spent time in, and the window's own span. A
        // stage that cost nothing is not written: an empty bar teaches nothing.
        assert!(v.as_array().is_some_and(|a| a.len() == 4), "{v}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
