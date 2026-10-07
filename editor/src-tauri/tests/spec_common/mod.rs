//! What every spec test file shares: the repository, a scratch directory, a project on disk, and
//! the node refs an outline names. Each test crate uses some of these, so unused ones are allowed.
#![allow(dead_code)]

use std::path::{Path, PathBuf};

use moonsplice_studio_lib::lower::NodeRef;

// ------------------------------------------------------------------ the shared bits

pub(super) fn root() -> Option<PathBuf> {
    moonsplice_studio_lib::engine::moonsplice_root()
}

pub(super) fn serve_dir(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("moonsplice-spec-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A project on disk the test owns, built from real compositions in the eval suite.
pub(super) struct Work {
    pub(super) dir: tempfile::TempDir,
}

impl Work {
    pub(super) fn with(root: &Path, comps: &[(&str, &str)]) -> Work {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("comps")).unwrap();
        for (name, case) in comps {
            std::fs::copy(
                root.join(format!("comps/cases/{case}.lua")),
                dir.path().join(format!("comps/{name}.lua")),
            )
            .unwrap();
        }
        Work { dir }
    }
    pub(super) fn path(&self) -> &Path {
        self.dir.path()
    }
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
