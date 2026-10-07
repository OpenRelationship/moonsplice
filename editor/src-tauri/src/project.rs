//! The project: a directory with a manifest.
//!
//! `app-shell` left this open — "a directory with a manifest, or a single document". It is a
//! directory, and the reason is not taste. `project-sync` names three writers of a
//! composition: the user, the agent, and a text editor outside the app. A single opaque
//! document cannot have the third, because the Lua source would no longer be a file. So the
//! manifest holds project state only — what compositions exist, their variations, and the
//! asset registry — and never a copy of anything that lives in a `.lua`.
//!
//! Nothing in the manifest reaches the UI as a path. Assets and compositions carry a
//! `title` a person can read; the path stays on this side of the wall.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

mod add;
mod open;
mod tree;
mod walk;

pub use walk::*;

pub const MANIFEST: &str = "moonsplice.json";

/// One thing the centre pane can show: a composition at one aspect ratio.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Variation {
    pub id: String,
    /// "Wide", "Vertical", "Square" — never "16:9 (comps/hero-9x16.lua)".
    pub title: String,
    pub aspect: String,
    /// Relative to the project directory. Serialized, never sent to the UI.
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Composition {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub variations: Vec<Variation>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssetKind {
    Footage,
    Image,
    Audio,
    Font,
    Data,
    Other,
}

impl AssetKind {
    /// Extensions are a filesystem detail. The left pane groups by what a thing *is*.
    pub fn of(path: &Path) -> AssetKind {
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        match ext.as_str() {
            "mp4" | "mov" | "m4v" | "webm" | "mkv" | "avi" => AssetKind::Footage,
            "png" | "jpg" | "jpeg" | "webp" | "gif" | "svg" | "tif" | "tiff" | "heic" => {
                AssetKind::Image
            }
            "wav" | "mp3" | "m4a" | "aac" | "flac" | "ogg" | "aiff" => AssetKind::Audio,
            "ttf" | "otf" | "woff" | "woff2" => AssetKind::Font,
            "json" | "csv" | "txt" | "srt" | "vtt" | "ndjson" => AssetKind::Data,
            _ => AssetKind::Other,
        }
    }
}

/// What to tell a webview a file is, so it can play or show it.
///
/// By extension, which is the only thing there is to go on -- and this is the one place in the app
/// where an extension is read. It never leaves Rust: what the window gets is an id.
pub fn media_type(path: &Path) -> &'static str {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "tif" | "tiff" => "image/tiff",
        "heic" => "image/heic",
        "wav" | "aiff" => "audio/wav",
        "mp3" => "audio/mpeg",
        "m4a" | "aac" => "audio/mp4",
        "flac" => "audio/flac",
        "ogg" => "audio/ogg",
        _ => "application/octet-stream",
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Asset {
    pub id: String,
    pub name: String,
    pub kind: AssetKind,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    #[serde(default = "one")]
    pub version: u32,
    pub name: String,
    #[serde(default)]
    pub compositions: Vec<Composition>,
    #[serde(default)]
    pub assets: Vec<Asset>,
}

fn one() -> u32 {
    1
}

/// The project as the UI sees it. No `source` fields: the left pane shows compositions and
/// assets, not files.
///
/// `compositions` and `assets` are the flat lists everything looks things up in. `tree` is how
/// the left pane draws them: the project's own folders, which are real directories a person made
/// and can rename, move things between, and put anything in. Nothing here is grouped by kind --
/// an automatic grouping is somebody else's idea of your project.
#[derive(Debug, Clone, Serialize)]
pub struct ProjectView {
    pub name: String,
    pub compositions: Vec<CompositionView>,
    pub assets: Vec<AssetView>,
    pub tree: Vec<Item>,
}

/// One row of the left pane.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "what", rename_all = "snake_case")]
pub enum Item {
    Folder {
        /// What it is called, which is the directory's own name made readable.
        name: String,
        /// Where it is, relative to the project. The UI treats this as an identity to drop on and
        /// create in; it is a folder, so it carries no file name and no extension.
        at: String,
        items: Vec<Item>,
    },
    Composition {
        comp: CompositionView,
    },
    Asset {
        asset: AssetView,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct CompositionView {
    pub id: String,
    pub title: String,
    pub variations: Vec<VariationView>,
}

#[derive(Debug, Clone, Serialize)]
pub struct VariationView {
    pub id: String,
    pub title: String,
    pub aspect: String,
    /// True when the composition has no nodes yet. An empty composition is still listed —
    /// `app-shell` scenario 2 — and the UI needs to know to draw its empty state.
    pub empty: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct AssetView {
    pub id: String,
    pub name: String,
    pub kind: AssetKind,
    /// Bytes, so the UI can say "38 MB" without ever naming the file.
    pub size: Option<u64>,
}

pub struct Project {
    pub root: PathBuf,
    pub manifest: Manifest,
}

/// A path becomes the words a person would have used for it: no directories, no extension.
/// The same rule `core/runtime/serve.lua` applies, on this side of the wall.
pub fn humanise(path: &str) -> String {
    let stem = Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(path);
    let spaced = stem
        .chars()
        .map(|c| if c == '_' || c == '-' || c == '.' { ' ' } else { c })
        .collect::<String>();
    let mut out = String::new();
    let mut last_lower = false;
    for c in spaced.chars() {
        if c.is_uppercase() && last_lower {
            out.push(' ');
        }
        last_lower = c.is_lowercase() || c.is_ascii_digit();
        out.push(c);
    }
    let out = out.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut cs = out.chars();
    match cs.next() {
        Some(c) => c.to_uppercase().collect::<String>() + cs.as_str(),
        None => "Untitled".into(),
    }
}

fn slug(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let t = out.trim_matches('-').to_string();
    if t.is_empty() {
        "item".into()
    } else {
        t
    }
}

/// The aspect a size reads as. Approximate on purpose: 1918x1080 is still Wide.
pub fn aspect_of(w: u32, h: u32) -> String {
    if h == 0 {
        return "16:9".into();
    }
    let r = w as f64 / h as f64;
    let named: [(f64, &str); 6] = [
        (16.0 / 9.0, "16:9"),
        (9.0 / 16.0, "9:16"),
        (1.0, "1:1"),
        (4.0 / 5.0, "4:5"),
        (4.0 / 3.0, "4:3"),
        (21.0 / 9.0, "21:9"),
    ];
    named
        .iter()
        .min_by(|a, b| (a.0 - r).abs().partial_cmp(&(b.0 - r).abs()).unwrap())
        .map(|(_, n)| n.to_string())
        .unwrap_or_else(|| "16:9".into())
}

/// The word the tab shows for an aspect. "9:16" is a ratio; "Vertical" is a shape.
pub fn aspect_word(aspect: &str) -> &'static str {
    match aspect {
        "9:16" => "Vertical",
        "1:1" => "Square",
        "4:5" => "Portrait",
        "4:3" => "Classic",
        "21:9" => "Scope",
        _ => "Wide",
    }
}

#[cfg(test)]
mod tests;
