//! What longform.rs and longform_play.rs share: where the long-form project is, and the clock.

use std::path::PathBuf;
use std::sync::Mutex;

/// Where the long-form project is, if it has been made.
pub(super) fn longform() -> Option<PathBuf> {
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

pub(super) fn serve_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("moonsplice-studio-long-{name}-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&d);
    d
}

pub(super) fn ms(d: std::time::Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

/// One at a time. Every test here starts a renderer and then times it, and four renderers on one
/// machine measure the machine rather than the renderer -- which showed up exactly as you would
/// expect: a ratio that is two to one alone came back five to four under its own siblings.
pub(super) static ALONE: Mutex<()> = Mutex::new(());

pub(super) fn alone() -> std::sync::MutexGuard<'static, ()> {
    ALONE.lock().unwrap_or_else(|e| e.into_inner())
}

pub(super) fn middle(mut v: Vec<f64>) -> (f64, f64) {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let at = |q: f64| v[(((v.len() - 1) as f64) * q).round() as usize];
    (at(0.5), at(0.95))
}
