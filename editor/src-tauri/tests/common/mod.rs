//! The stack, end to end, against real compositions.
//!
//! These are not unit tests. They start the real renderer, open the real eval suite, and check
//! the properties the whole app is built on:
//!
//!   * `lower(comp, [])` is the identity, byte for byte, for every composition in the repo —
//!     which is what keeps `.robot/golden/` valid while the app is open.
//!   * the ids the engine reports line up with the constructors in the source, which is what
//!     makes a span edit land on the thing the person pointed at.
//!   * an edit is a write, the engine re-reads it, and the outline changes.
//!   * a frame comes back at the composition's own size and encodes.
//!
//! They need the checkout (`MOONSPLICE_ROOT`, or being run from inside it) and a working
//! `moonsplice`. Anything that cannot find those skips rather than fails, so the suite is
//! still useful on a machine with no engine staged.
//!
//! Each studio_*.rs test file shares these helpers through `mod common;` and uses some of them,
//! so the ones a file does not use are allowed.
#![allow(dead_code)]

use std::path::{Path, PathBuf};

use moonsplice_studio_lib::lower::NodeRef;

/// Some of these tests are about the bytes, not the wording, so they name nothing.
pub(super) fn no_names() -> std::collections::HashMap<String, String> {
    std::collections::HashMap::new()
}

pub(super) fn root() -> Option<PathBuf> {
    moonsplice_studio_lib::engine::moonsplice_root()
}

pub(super) fn cases(root: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(root.join("evals/cases"))
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("lua"))
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

pub(super) fn serve_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("moonsplice-studio-test-{name}-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&d);
    d
}

pub(super) fn node_refs(outline: &serde_json::Value) -> Vec<NodeRef> {
    outline["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|n| {
                    Some(NodeRef {
                        id: n["id"].as_str()?.to_string(),
                        kind: n["kind"].as_str().unwrap_or("").to_string(),
                        line: n["line"].as_u64().map(|v| v as u32),
                        props: n["props"]
                            .as_object()
                            .map(|o| o.keys().cloned().collect())
                            .unwrap_or_default(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

pub(super) fn name(p: &Path) -> String {
    p.file_stem().and_then(|s| s.to_str()).unwrap_or("?").to_string()
}
