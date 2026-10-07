use super::*;

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
