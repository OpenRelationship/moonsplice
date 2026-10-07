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
