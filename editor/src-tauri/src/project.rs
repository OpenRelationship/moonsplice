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

impl Project {
    pub fn open(root: &Path) -> std::io::Result<Project> {
        let path = root.join(MANIFEST);
        // A folder with no manifest is not a different kind of thing: it is a project whose
        // manifest agrees with nothing yet. Starting from empty and reconciling means adopting a
        // directory and picking up what somebody added yesterday are the same code, which is the
        // only way they stay the same behaviour.
        let fresh = !path.is_file();
        let manifest: Manifest = if fresh {
            Manifest {
                version: 1,
                name: humanise(root.file_name().and_then(|s| s.to_str()).unwrap_or("project")),
                compositions: Vec::new(),
                assets: Vec::new(),
            }
        } else {
            serde_json::from_str(&std::fs::read_to_string(&path)?)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?
        };
        let mut p = Project {
            root: root.to_path_buf(),
            manifest,
        };
        if p.reconcile() || fresh {
            p.save()?;
        }
        Ok(p)
    }

    /// Make the manifest agree with the folders.
    ///
    /// The pane is the project's own folder tree, so a person can make a composition by copying a
    /// file in the Finder, and can lose one by deleting it there. Either way the next look should
    /// show what is actually in the folder. Returns whether anything changed.
    fn reconcile(&mut self) -> bool {
        let mut changed = false;

        // Gone from disk is gone from the project. A variation whose file was deleted goes; a
        // composition with no variations left goes with it.
        let root = self.root.clone();
        for c in &mut self.manifest.compositions {
            let before = c.variations.len();
            c.variations.retain(|v| root.join(&v.source).is_file());
            changed |= c.variations.len() != before;
        }
        let before = self.manifest.compositions.len();
        self.manifest.compositions.retain(|c| !c.variations.is_empty());
        changed |= self.manifest.compositions.len() != before;
        let before = self.manifest.assets.len();
        self.manifest.assets.retain(|a| root.join(&a.source).is_file());
        changed |= self.manifest.assets.len() != before;

        // And a composition somebody put in a folder is a composition.
        let known: std::collections::HashSet<String> = self
            .manifest
            .compositions
            .iter()
            .flat_map(|c| c.variations.iter().map(|v| v.source.clone()))
            .collect();
        let mut found = Vec::new();
        comps_under(&self.root, "", 0, &mut found);
        found.sort();
        for rel in found {
            if known.contains(&rel) {
                continue;
            }
            let title = humanise(&rel);
            let mut id = slug(&title);
            while self.manifest.compositions.iter().any(|c| c.id == id) {
                id.push('2');
            }
            let (w, h) = declared_size(&self.root.join(&rel)).unwrap_or((1920, 1080));
            let aspect = aspect_of(w, h);
            self.manifest.compositions.push(Composition {
                id: id.clone(),
                title,
                variations: vec![Variation {
                    id,
                    title: aspect_word(&aspect).to_string(),
                    aspect,
                    source: rel,
                }],
            });
            changed = true;
        }

        // And footage somebody put in a folder is footage. The left pane is the project's own
        // directories, so a file that arrives in the Finder, over a network share, or from
        // whatever wrote it has to appear -- anything else makes the pane a copy of a manifest
        // rather than a view of the folders, which is the thing it was rebuilt not to be.
        let known: std::collections::HashSet<String> =
            self.manifest.assets.iter().map(|a| a.source.clone()).collect();
        let comps: std::collections::HashSet<String> = self
            .manifest
            .compositions
            .iter()
            .flat_map(|c| c.variations.iter().map(|v| v.source.clone()))
            .collect();
        let mut media = Vec::new();
        walk(&self.root, &mut media, 0);
        media.sort();
        for path in media {
            let rel = match path.strip_prefix(&self.root) {
                Ok(r) => r.to_string_lossy().to_string(),
                Err(_) => continue,
            };
            // The manifest is the project's own bookkeeping, not something in the project.
            if rel == MANIFEST || known.contains(&rel) || comps.contains(&rel) || !is_media(&path) {
                continue;
            }
            let name = humanise(&rel);
            let mut id = slug(&name);
            while self.manifest.assets.iter().any(|a| a.id == id) {
                id.push('2');
            }
            self.manifest.assets.push(Asset {
                id,
                name,
                kind: AssetKind::of(&path),
                source: rel,
            });
            changed = true;
        }
        changed
    }

    pub fn save(&self) -> std::io::Result<()> {
        let text = serde_json::to_string_pretty(&self.manifest)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        std::fs::write(self.root.join(MANIFEST), text + "\n")
    }

    pub fn source_of(&self, variation_id: &str) -> Option<PathBuf> {
        for c in &self.manifest.compositions {
            for v in &c.variations {
                if v.id == variation_id {
                    return Some(self.root.join(&v.source));
                }
            }
        }
        None
    }

    /// What a person calls this variation. The composition's title on its own when there is only
    /// one, and the shape as well when there is a choice -- "Captions", or "Motion Vertical".
    pub fn title_of(&self, variation_id: &str) -> Option<String> {
        for c in &self.manifest.compositions {
            for v in &c.variations {
                if v.id == variation_id {
                    return Some(if c.variations.len() > 1 {
                        format!("{} {}", c.title, v.title)
                    } else {
                        c.title.clone()
                    });
                }
            }
        }
        None
    }

    pub fn asset_path(&self, asset_id: &str) -> Option<PathBuf> {
        self.manifest
            .assets
            .iter()
            .find(|a| a.id == asset_id)
            .map(|a| self.root.join(&a.source))
    }

    /// Bring a file into the project, into the folder it was dropped on. Anything is allowed: the
    /// left pane takes assets of any kind (`app-shell` scenario 3), and an unknown kind is
    /// `Other`, never a refusal.
    ///
    /// It lands where it was put and nowhere else. Sorting things into `footage/` and `images/`
    /// behind a person's back is an automatic grouping, and the pane is their tree, not the app's.
    pub fn add_asset(&mut self, from: &Path, into: &str) -> std::io::Result<AssetView> {
        let kind = AssetKind::of(from);
        let into = clean_folder(into);
        let dir = self.root.join(&into);
        std::fs::create_dir_all(&dir)?;
        let base = from
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("asset")
            .to_string();
        let mut dest = dir.join(&base);
        let mut n = 2;
        while dest.exists() {
            let stem = Path::new(&base)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("asset");
            let ext = Path::new(&base)
                .extension()
                .and_then(|s| s.to_str())
                .map(|e| format!(".{e}"))
                .unwrap_or_default();
            dest = dir.join(format!("{stem}-{n}{ext}"));
            n += 1;
        }
        if from != dest {
            std::fs::copy(from, &dest)?;
        }
        let rel = dest
            .strip_prefix(&self.root)
            .unwrap_or(&dest)
            .to_string_lossy()
            .to_string();
        let name = humanise(&rel);
        let mut id = slug(&name);
        while self.manifest.assets.iter().any(|a| a.id == id) {
            id.push('2');
        }
        let asset = Asset {
            id: id.clone(),
            name: name.clone(),
            kind,
            source: rel,
        };
        self.manifest.assets.push(asset);
        self.save()?;
        Ok(AssetView {
            id,
            name,
            kind,
            size: std::fs::metadata(&dest).ok().map(|m| m.len()),
        })
    }

    /// A finished export enters the project. The file is already in `exports/`, so this is a line
    /// in the manifest rather than a second copy of the video, and it is named after the
    /// composition it came from -- the name a person would look for.
    ///
    /// Exporting the same variation again replaces the entry instead of adding `Captions 2`: it
    /// is the same video, made again.
    pub fn add_export(&mut self, rel: &str, title: &str) -> std::io::Result<AssetView> {
        self.manifest.assets.retain(|a| a.source != rel);
        let mut id = slug(&format!("{title} export"));
        while self.manifest.assets.iter().any(|a| a.id == id) {
            id.push('2');
        }
        let asset = Asset {
            id: id.clone(),
            name: title.to_string(),
            kind: AssetKind::Footage,
            source: rel.to_string(),
        };
        self.manifest.assets.push(asset);
        self.save()?;
        Ok(AssetView {
            id,
            name: title.to_string(),
            kind: AssetKind::Footage,
            size: std::fs::metadata(self.root.join(rel)).ok().map(|m| m.len()),
        })
    }

    /// A new, empty composition. It is listed immediately — an empty composition is a real
    /// thing in this app, not a file you have to create first.
    pub fn add_composition(
        &mut self,
        title: &str,
        w: u32,
        h: u32,
        into: &str,
    ) -> std::io::Result<String> {
        let mut id = slug(title);
        while self.manifest.compositions.iter().any(|c| c.id == id) {
            id.push('2');
        }
        let into = clean_folder(into);
        std::fs::create_dir_all(self.root.join(&into))?;
        let rel = if into.is_empty() {
            format!("{id}.lua")
        } else {
            format!("{into}/{id}.lua")
        };
        let path = self.root.join(&rel);
        if !path.exists() {
            std::fs::write(&path, blank_comp(title, w, h))?;
        }
        let aspect = aspect_of(w, h);
        self.manifest.compositions.push(Composition {
            id: id.clone(),
            title: title.to_string(),
            variations: vec![Variation {
                id: id.clone(),
                title: aspect_word(&aspect).to_string(),
                aspect,
                source: rel,
            }],
        });
        self.save()?;
        Ok(id)
    }

    /// Another aspect ratio of an existing composition. It starts as a copy, because a
    /// variation is a composition in its own right: the source is the truth and two aspect
    /// ratios are two truths.
    pub fn add_variation(
        &mut self,
        comp_id: &str,
        w: u32,
        h: u32,
    ) -> std::io::Result<String> {
        let aspect = aspect_of(w, h);
        let (from_rel, title) = {
            let c = self
                .manifest
                .compositions
                .iter()
                .find(|c| c.id == comp_id)
                .ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::NotFound, "no such composition")
                })?;
            let first = c.variations.first().ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::NotFound, "nothing to vary")
            })?;
            (first.source.clone(), c.title.clone())
        };
        let mut vid = format!("{comp_id}-{}", slug(&aspect));
        while self.variation_exists(&vid) {
            vid.push('2');
        }
        // Beside the shape it was copied from: two shapes of one composition are one row in the
        // pane, so they belong in one folder.
        let home = folder_of(&from_rel);
        let rel = if home.is_empty() {
            format!("{vid}.lua")
        } else {
            format!("{home}/{vid}.lua")
        };
        let text = std::fs::read_to_string(self.root.join(&from_rel))?;
        let text = retarget(&text, w, h);
        std::fs::write(self.root.join(&rel), text)?;
        let c = self
            .manifest
            .compositions
            .iter_mut()
            .find(|c| c.id == comp_id)
            .expect("checked above");
        c.variations.push(Variation {
            id: vid.clone(),
            title: aspect_word(&aspect).to_string(),
            aspect,
            source: rel,
        });
        let _ = title;
        self.save()?;
        Ok(vid)
    }

    fn variation_exists(&self, id: &str) -> bool {
        self.manifest
            .compositions
            .iter()
            .any(|c| c.variations.iter().any(|v| v.id == id))
    }

    pub fn view(&self) -> ProjectView {
        ProjectView {
            name: self.manifest.name.clone(),
            compositions: self
                .manifest
                .compositions
                .iter()
                .map(|c| CompositionView {
                    id: c.id.clone(),
                    title: c.title.clone(),
                    variations: c
                        .variations
                        .iter()
                        .map(|v| VariationView {
                            id: v.id.clone(),
                            title: v.title.clone(),
                            aspect: v.aspect.clone(),
                            empty: looks_empty(&self.root.join(&v.source)),
                        })
                        .collect(),
                })
                .collect(),
            assets: self
                .manifest
                .assets
                .iter()
                .map(|a| AssetView {
                    id: a.id.clone(),
                    name: a.name.clone(),
                    kind: a.kind,
                    size: std::fs::metadata(self.root.join(&a.source)).ok().map(|m| m.len()),
                })
                .collect(),
            tree: self.tree(),
        }
    }

    /// The project's folders, with what is in them.
    ///
    /// Read off the directories rather than out of the manifest, so a folder a person made and has
    /// not put anything in yet is still there, and a folder they made in the Finder shows up the
    /// next time they look. The manifest says what each file *is*; the filesystem says where it is.
    pub fn tree(&self) -> Vec<Item> {
        let comps: Vec<(String, CompositionView)> = self
            .manifest
            .compositions
            .iter()
            .filter_map(|c| {
                let first = c.variations.first()?;
                Some((
                    folder_of(&first.source),
                    CompositionView {
                        id: c.id.clone(),
                        title: c.title.clone(),
                        variations: c
                            .variations
                            .iter()
                            .map(|v| VariationView {
                                id: v.id.clone(),
                                title: v.title.clone(),
                                aspect: v.aspect.clone(),
                                empty: looks_empty(&self.root.join(&v.source)),
                            })
                            .collect(),
                    },
                ))
            })
            .collect();
        let assets: Vec<(String, AssetView)> = self
            .manifest
            .assets
            .iter()
            .map(|a| {
                (
                    folder_of(&a.source),
                    AssetView {
                        id: a.id.clone(),
                        name: a.name.clone(),
                        kind: a.kind,
                        size: std::fs::metadata(self.root.join(&a.source)).ok().map(|m| m.len()),
                    },
                )
            })
            .collect();
        self.items_in("", &comps, &assets, 0)
    }

    fn items_in(
        &self,
        at: &str,
        comps: &[(String, CompositionView)],
        assets: &[(String, AssetView)],
        depth: usize,
    ) -> Vec<Item> {
        let mut folders: Vec<Item> = Vec::new();
        if depth < MAX_DEPTH {
            let mut names: Vec<String> = Vec::new();
            if let Ok(rd) = std::fs::read_dir(self.root.join(at)) {
                for e in rd.flatten() {
                    if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                        if let Some(name) = e.file_name().to_str() {
                            if !skipped(name) {
                                names.push(name.to_string());
                            }
                        }
                    }
                }
            }
            names.sort_by_key(|n| n.to_lowercase());
            for name in names {
                let inside = if at.is_empty() {
                    name.clone()
                } else {
                    format!("{at}/{name}")
                };
                folders.push(Item::Folder {
                    name: humanise_folder(&name),
                    items: self.items_in(&inside, comps, assets, depth + 1),
                    at: inside,
                });
            }
        }

        // Folders first, then the things themselves: a person scanning the pane is looking either
        // for a place or for a thing, and the two do not interleave usefully.
        let mut out = folders;
        let mut here: Vec<Item> = comps
            .iter()
            .filter(|(f, _)| f == at)
            .map(|(_, c)| Item::Composition { comp: c.clone() })
            .collect();
        here.sort_by_key(|i| match i {
            Item::Composition { comp } => comp.title.to_lowercase(),
            _ => String::new(),
        });
        out.append(&mut here);
        let mut things: Vec<Item> = assets
            .iter()
            .filter(|(f, _)| f == at)
            .map(|(_, a)| Item::Asset { asset: a.clone() })
            .collect();
        things.sort_by_key(|i| match i {
            Item::Asset { asset } => asset.name.to_lowercase(),
            _ => String::new(),
        });
        out.append(&mut things);
        out
    }

    /// A new folder. It is a directory, because the pane is the project's folders and not a
    /// picture of them.
    pub fn add_folder(&mut self, parent: &str, name: &str) -> std::io::Result<String> {
        let leaf = folder_name(name);
        if leaf.is_empty() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "a folder needs a name",
            ));
        }
        let parent = clean_folder(parent);
        let mut rel = if parent.is_empty() {
            leaf.clone()
        } else {
            format!("{parent}/{leaf}")
        };
        let mut n = 2;
        while self.root.join(&rel).exists() {
            rel = if parent.is_empty() {
                format!("{leaf} {n}")
            } else {
                format!("{parent}/{leaf} {n}")
            };
            n += 1;
        }
        std::fs::create_dir_all(self.root.join(&rel))?;
        Ok(rel)
    }

    /// Put a thing in a folder. The file moves, because the folder is real.
    ///
    /// A composition moves with every shape of itself: they are one thing in the pane, and leaving
    /// the vertical cut behind in the old folder would make that a lie.
    pub fn move_item(&mut self, id: &str, into: &str) -> std::io::Result<()> {
        let into = clean_folder(into);
        let dir = self.root.join(&into);
        if !into.is_empty() {
            std::fs::create_dir_all(&dir)?;
        }
        let mut moves: Vec<(String, String)> = Vec::new();
        for c in &self.manifest.compositions {
            if c.id == id {
                for v in &c.variations {
                    moves.push((v.source.clone(), rehome(&v.source, &into)));
                }
            }
        }
        if moves.is_empty() {
            for a in &self.manifest.assets {
                if a.id == id {
                    moves.push((a.source.clone(), rehome(&a.source, &into)));
                }
            }
        }
        if moves.is_empty() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "no such thing in this project",
            ));
        }
        for (from, to) in &moves {
            if from == to {
                continue;
            }
            if self.root.join(to).exists() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "there is already one of those in that folder",
                ));
            }
            std::fs::rename(self.root.join(from), self.root.join(to))?;
        }
        let moved: std::collections::HashMap<&str, &str> =
            moves.iter().map(|(f, t)| (f.as_str(), t.as_str())).collect();
        for c in &mut self.manifest.compositions {
            for v in &mut c.variations {
                if let Some(to) = moved.get(v.source.as_str()) {
                    v.source = (*to).to_string();
                }
            }
        }
        for a in &mut self.manifest.assets {
            if let Some(to) = moved.get(a.source.as_str()) {
                a.source = (*to).to_string();
            }
        }
        self.save()
    }

    /// Rename a folder, which renames the directory and follows every file that was in it.
    pub fn rename_folder(&mut self, at: &str, name: &str) -> std::io::Result<String> {
        let at = clean_folder(at);
        let leaf = folder_name(name);
        if at.is_empty() || leaf.is_empty() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "a folder needs a name",
            ));
        }
        let parent = folder_of(&at);
        let rel = if parent.is_empty() {
            leaf.clone()
        } else {
            format!("{parent}/{leaf}")
        };
        if rel == at {
            return Ok(at);
        }
        if self.root.join(&rel).exists() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "there is already a folder called that",
            ));
        }
        std::fs::rename(self.root.join(&at), self.root.join(&rel))?;
        let was = format!("{at}/");
        let now = format!("{rel}/");
        let fix = |src: &mut String| {
            if let Some(rest) = src.strip_prefix(&was) {
                *src = format!("{now}{rest}");
            }
        };
        for c in &mut self.manifest.compositions {
            for v in &mut c.variations {
                fix(&mut v.source);
            }
        }
        for a in &mut self.manifest.assets {
            fix(&mut a.source);
        }
        self.save()?;
        Ok(rel)
    }
}

/// How deep the pane will look. Deeper than anyone organises, shallow enough that opening a folder
/// with a checkout in it does not walk the whole thing.
const MAX_DEPTH: usize = 6;

/// Directories that are not part of a project however they got there.
fn skipped(name: &str) -> bool {
    name.starts_with('.')
        || matches!(name, "node_modules" | "target" | "dist" | "__pycache__" | "build")
}

/// The folder a file is in, relative to the project. `""` for one at the top.
pub fn folder_of(rel: &str) -> String {
    match rel.rsplit_once('/') {
        Some((dir, _)) => dir.to_string(),
        None => String::new(),
    }
}

/// The same file, in another folder.
fn rehome(rel: &str, into: &str) -> String {
    let base = rel.rsplit_once('/').map(|(_, f)| f).unwrap_or(rel);
    if into.is_empty() {
        base.to_string()
    } else {
        format!("{into}/{base}")
    }
}

/// A folder path with nothing surprising in it: no leading slash, no `..`, no trailing slash.
fn clean_folder(at: &str) -> String {
    at.split('/')
        .map(str::trim)
        .filter(|p| !p.is_empty() && *p != "." && *p != "..")
        .collect::<Vec<_>>()
        .join("/")
}

/// One folder name, as a directory can actually be called.
fn folder_name(name: &str) -> String {
    name.trim()
        .chars()
        .filter(|c| !matches!(c, '/' | '\\' | ':' | '\0'))
        .collect::<String>()
        .trim_matches('.')
        .trim()
        .to_string()
}

/// A directory name as the pane says it. A folder a person named keeps their capitals and their
/// spaces; `my-footage` reads as "My footage" the same way everything else here does.
fn humanise_folder(name: &str) -> String {
    if name.chars().any(|c| c == ' ' || c.is_uppercase()) {
        name.to_string()
    } else {
        humanise(name)
    }
}

/// A composition with nothing in it. Cheap enough to do on every listing, and it means the
/// UI never has to start an engine to find out whether to draw an empty state.
fn looks_empty(path: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        return true;
    };
    let ctor = regex::Regex::new(r"\bs\s*:\s*\w+\s*\{").unwrap();
    !ctor.is_match(&text)
}

/// Every composition in the project, wherever it is, relative to the root.
fn comps_under(root: &Path, at: &str, depth: usize, out: &mut Vec<String>) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(rd) = std::fs::read_dir(root.join(at)) else {
        return;
    };
    for e in rd.flatten() {
        let Some(name) = e.file_name().to_str().map(str::to_string) else {
            continue;
        };
        let rel = if at.is_empty() {
            name.clone()
        } else {
            format!("{at}/{name}")
        };
        if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            if !skipped(&name) {
                comps_under(root, &rel, depth + 1, out);
            }
        } else if name.ends_with(".lua") {
            out.push(rel);
        }
    }
}

/// A file the project can use. Anything else in the folder -- a readme, a script, a stray
/// `.DS_Store` -- is somebody's business and not the app's.
fn is_media(path: &Path) -> bool {
    !matches!(AssetKind::of(path), AssetKind::Other)
}

fn walk(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    if depth > MAX_DEPTH {
        return;
    }
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            if p.is_dir() {
                if skipped(&name) {
                    continue;
                }
                walk(&p, out, depth + 1);
            } else if !p
                .file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|n| n.starts_with('.'))
            {
                out.push(p);
            }
        }
    }
}

/// `width = 1280, height = 720` read off the text. Cheap, and wrong only for a comp that
/// computes its own size — in which case the engine corrects it the moment it opens.
pub fn declared_size(path: &Path) -> Option<(u32, u32)> {
    let text = std::fs::read_to_string(path).ok()?;
    let re = regex::Regex::new(r"width\s*=\s*(\d+)\s*,\s*height\s*=\s*(\d+)").unwrap();
    let c = re.captures(&text)?;
    Some((c[1].parse().ok()?, c[2].parse().ok()?))
}

fn retarget(text: &str, w: u32, h: u32) -> String {
    let re = regex::Regex::new(r"width\s*=\s*\d+\s*,\s*height\s*=\s*\d+").unwrap();
    re.replace(text, format!("width = {w}, height = {h}").as_str())
        .to_string()
}

pub fn blank_comp(title: &str, w: u32, h: u32) -> String {
    format!(
        "-- {title}\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {{\n  \
         width = {w}, height = {h}, duration = 5, fps = 30,\n  background = \"#0b0d12\",\n\n  \
         scene = function(s)\n  end,\n}}\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn a_path_becomes_words() {
        assert_eq!(humanise("assets/footage/handoff_take_02.mp4"), "Handoff take 02");
        assert_eq!(humanise("comps/heroCutdown.lua"), "HeroCutdown".replace("roC", "ro C"));
        assert_eq!(humanise("x/.hidden"), "Hidden".replace("Hidden", "Hidden"));
    }

    #[test]
    fn an_aspect_reads_as_a_shape() {
        assert_eq!(aspect_of(1920, 1080), "16:9");
        assert_eq!(aspect_of(1080, 1920), "9:16");
        assert_eq!(aspect_of(1080, 1080), "1:1");
        assert_eq!(aspect_word("9:16"), "Vertical");
    }

    #[test]
    fn kinds_come_from_what_a_thing_is() {
        assert_eq!(AssetKind::of(Path::new("a.MOV")), AssetKind::Footage);
        assert_eq!(AssetKind::of(Path::new("a.woff2")), AssetKind::Font);
        assert_eq!(AssetKind::of(Path::new("a.zzz")), AssetKind::Other);
    }

    /// The shell decided that an export's result enters the project. It enters as the video a
    /// person made, named after the composition, and exporting twice does not leave two of them.
    #[test]
    fn an_export_enters_the_project_as_the_video_it_is() {
        let dir = tempdir().unwrap();
        let mut p = Project::open(dir.path()).unwrap();
        p.add_composition("Hero", 1920, 1080, "").unwrap();
        std::fs::create_dir_all(dir.path().join("exports")).unwrap();
        std::fs::write(dir.path().join("exports/hero.mp4"), b"not really a video").unwrap();

        let a = p.add_export("exports/hero.mp4", "Hero").unwrap();
        assert_eq!(a.name, "Hero");
        assert_eq!(a.kind, AssetKind::Footage);
        assert_eq!(a.size, Some(18));
        assert_eq!(p.view().assets.len(), 1);

        // The same export again is the same video, made again.
        p.add_export("exports/hero.mp4", "Hero").unwrap();
        assert_eq!(p.view().assets.len(), 1);

        // And it is registered where it already is, not copied into `assets/`.
        assert!(!dir.path().join("assets/footage/hero.mp4").exists());
        assert_eq!(p.manifest.assets[0].source, "exports/hero.mp4");
    }

    /// What the export is called. A choice of shapes means the shape is part of the name, because
    /// two files called "Motion" in the left pane are not two names.
    #[test]
    fn an_export_of_one_shape_among_several_says_which() {
        let dir = tempdir().unwrap();
        let mut p = Project::open(dir.path()).unwrap();
        let id = p.add_composition("Motion", 1920, 1080, "").unwrap();
        assert_eq!(p.title_of(&id).unwrap(), "Motion");
        let other = p.add_variation("motion", 1080, 1920).unwrap();
        assert_eq!(p.title_of(&other).unwrap(), "Motion Vertical");
        assert_eq!(p.title_of("nothing-like-it"), None);
    }

    #[test]
    fn an_empty_composition_is_still_listed() {
        let dir = tempdir().unwrap();
        let mut p = Project::open(dir.path()).unwrap();
        p.add_composition("Hero", 1920, 1080, "").unwrap();
        let view = p.view();
        assert_eq!(view.compositions.len(), 1);
        assert!(view.compositions[0].variations[0].empty);
    }

    #[test]
    fn a_new_variation_is_the_other_shape() {
        let dir = tempdir().unwrap();
        let mut p = Project::open(dir.path()).unwrap();
        let id = p.add_composition("Hero", 1920, 1080, "").unwrap();
        p.add_variation(&id, 1080, 1920).unwrap();
        let view = p.view();
        let titles: Vec<&str> = view.compositions[0]
            .variations
            .iter()
            .map(|v| v.title.as_str())
            .collect();
        assert_eq!(titles, vec!["Wide", "Vertical"]);
        // Beside the shape it came from, which is where the composition lives.
        let src = std::fs::read_to_string(dir.path().join("hero-9-16.lua")).unwrap();
        assert!(src.contains("width = 1080, height = 1920"));
    }

    #[test]
    fn a_file_of_any_kind_becomes_an_asset() {
        let dir = tempdir().unwrap();
        let drop = dir.path().join("Some Thing.zzz");
        std::fs::write(&drop, b"x").unwrap();
        let proj = tempdir().unwrap();
        let mut p = Project::open(proj.path()).unwrap();
        // Into the folder it was dropped on, which here is the top of the project.
        let a = p.add_asset(&drop, "").unwrap();
        assert_eq!(a.kind, AssetKind::Other);
        assert_eq!(a.name, "Some Thing");
        assert!(proj.path().join("Some Thing.zzz").is_file());

        // And onto a folder, which is where a drop on a folder puts it.
        let other = dir.path().join("Another.zzz");
        std::fs::write(&other, b"x").unwrap();
        p.add_asset(&other, "Interviews").unwrap();
        assert!(proj.path().join("Interviews/Another.zzz").is_file());
    }

    /// Footage that arrived without the app looking is still footage.
    ///
    /// Found by opening a ten minute project made outside the app: it held sixty clips and sound
    /// files in two folders, and the pane showed none of them, because discovery only ever looked
    /// in a folder called `assets`. The pane is the project's own directories now, so anything
    /// the project can use, anywhere in it, is part of the project.
    #[test]
    fn footage_put_in_a_folder_by_hand_is_in_the_project() {
        let proj = tempdir().unwrap();
        std::fs::create_dir_all(proj.path().join("Footage")).unwrap();
        std::fs::create_dir_all(proj.path().join("Sound/Music")).unwrap();
        std::fs::write(proj.path().join("Footage/harbour.mp4"), b"x").unwrap();
        std::fs::write(proj.path().join("Sound/Music/bed.mp3"), b"x").unwrap();
        std::fs::write(proj.path().join("Sound/vo-01.mp3"), b"x").unwrap();
        // Not media, and not the app's business.
        std::fs::write(proj.path().join("Footage/notes.zzz"), b"x").unwrap();

        let p = Project::open(proj.path()).unwrap();
        let mut names: Vec<&str> = p.manifest.assets.iter().map(|a| a.name.as_str()).collect();
        names.sort();
        assert_eq!(names, vec!["Bed", "Harbour", "Vo 01"]);
        assert_eq!(
            p.manifest
                .assets
                .iter()
                .find(|a| a.name == "Harbour")
                .map(|a| a.kind),
            Some(AssetKind::Footage)
        );

        // Adopted once, not once per open, and the folders they are in are the folders they stay
        // in -- the tree is the directories, so nothing moved to be listed.
        let again = Project::open(proj.path()).unwrap();
        assert_eq!(again.manifest.assets.len(), 3);
        assert!(proj.path().join("Sound/Music/bed.mp3").is_file());
    }

    /// The pane is the project's own folders.
    #[test]
    fn the_tree_is_the_project_s_own_folders() {
        let dir = tempdir().unwrap();
        let mut p = Project::open(dir.path()).unwrap();
        p.add_composition("Opening", 1920, 1080, "").unwrap();
        p.add_composition("Vertical cut", 1080, 1920, "Cutdowns").unwrap();
        let clip = dir.path().join("day-one.mov");
        std::fs::write(&clip, b"x").unwrap();
        p.add_asset(&clip, "Interviews").unwrap();
        // A folder with nothing in it yet is still a folder.
        p.add_folder("", "Music").unwrap();

        let tree = p.view().tree;
        let names: Vec<String> = tree
            .iter()
            .map(|i| match i {
                Item::Folder { name, .. } => format!("{name}/"),
                Item::Composition { comp } => comp.title.clone(),
                Item::Asset { asset } => asset.name.clone(),
            })
            .collect();
        // Folders first, alphabetically, then the things at the top level.
        assert_eq!(names, vec!["Cutdowns/", "Interviews/", "Music/", "Opening"]);

        let Item::Folder { items, at, .. } = &tree[0] else {
            panic!("the first row is a folder");
        };
        assert_eq!(at, "Cutdowns");
        assert!(matches!(&items[0], Item::Composition { comp } if comp.title == "Vertical cut"));
        let Item::Folder { items, .. } = &tree[1] else {
            panic!("a folder");
        };
        assert!(matches!(&items[0], Item::Asset { asset } if asset.name == "Day one"));
        let Item::Folder { items, .. } = &tree[2] else {
            panic!("a folder");
        };
        assert!(items.is_empty(), "an empty folder is empty, not absent");

        // Nothing in the pane is a file name. Ids are still ids -- they are slugs of the name a
        // person reads, the same as everywhere else in the app, and nothing shows them.
        let json = serde_json::to_string(&p.view()).unwrap();
        for code in [".lua", ".mov", ".zzz"] {
            assert!(!json.contains(code), "`{code}` reached the pane: {json}");
        }
    }

    /// Dragging a thing into a folder moves it, and a composition takes every shape of itself.
    #[test]
    fn dragging_a_thing_into_a_folder_moves_the_file() {
        let dir = tempdir().unwrap();
        let mut p = Project::open(dir.path()).unwrap();
        let id = p.add_composition("Hero", 1920, 1080, "").unwrap();
        p.add_variation(&id, 1080, 1920).unwrap();
        assert!(dir.path().join("hero.lua").is_file());

        p.move_item(&id, "Cutdowns").unwrap();
        assert!(dir.path().join("Cutdowns/hero.lua").is_file());
        assert!(dir.path().join("Cutdowns/hero-9-16.lua").is_file());
        assert!(!dir.path().join("hero.lua").exists());
        // And the project still knows what it is, which is the point of moving the file rather
        // than remembering a folder somewhere.
        assert_eq!(p.source_of(&id).unwrap(), dir.path().join("Cutdowns/hero.lua"));
        assert_eq!(p.view().compositions.len(), 1);

        // Reopening reads the same thing back: the manifest and the folders agree.
        let again = Project::open(dir.path()).unwrap();
        assert_eq!(again.view().compositions.len(), 1);
        let tree = again.view().tree;
        assert!(matches!(&tree[0], Item::Folder { at, .. } if at == "Cutdowns"));
    }

    #[test]
    fn renaming_a_folder_follows_its_files() {
        let dir = tempdir().unwrap();
        let mut p = Project::open(dir.path()).unwrap();
        p.add_composition("Hero", 1920, 1080, "Cutdowns").unwrap();
        let at = p.rename_folder("Cutdowns", "Social").unwrap();
        assert_eq!(at, "Social");
        assert!(dir.path().join("Social/hero.lua").is_file());
        assert_eq!(p.manifest.compositions[0].variations[0].source, "Social/hero.lua");
        // A folder that is already there is refused rather than merged into.
        p.add_folder("", "Music").unwrap();
        assert!(p.rename_folder("Social", "Music").is_err());
    }

    /// The folder is the truth: a composition copied in by hand is a composition, and one deleted
    /// in the Finder is gone.
    #[test]
    fn the_folders_are_the_truth_when_the_app_was_not_looking() {
        let dir = tempdir().unwrap();
        let mut p = Project::open(dir.path()).unwrap();
        p.add_composition("Hero", 1920, 1080, "").unwrap();
        std::fs::create_dir_all(dir.path().join("Someone else")).unwrap();
        std::fs::write(
            dir.path().join("Someone else/brief.lua"),
            "return e.comp { width = 1080, height = 1080, scene = function(s) s:text{} end }",
        )
        .unwrap();

        let p2 = Project::open(dir.path()).unwrap();
        let titles: Vec<String> = p2.view().compositions.iter().map(|c| c.title.clone()).collect();
        assert!(titles.contains(&"Brief".to_string()), "adopted: {titles:?}");
        assert!(titles.contains(&"Hero".to_string()));

        std::fs::remove_file(dir.path().join("hero.lua")).unwrap();
        let p3 = Project::open(dir.path()).unwrap();
        let titles: Vec<String> = p3.view().compositions.iter().map(|c| c.title.clone()).collect();
        assert_eq!(titles, vec!["Brief"], "a deleted composition leaves the project");
        let _ = p;
    }

    #[test]
    fn a_folder_of_comps_opens_without_a_manifest() {
        let dir = tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("comps")).unwrap();
        std::fs::write(
            dir.path().join("comps/hero.lua"),
            "return e.comp { width = 1080, height = 1920, scene = function(s) s:text{} end }",
        )
        .unwrap();
        let p = Project::open(dir.path()).unwrap();
        assert!(dir.path().join(MANIFEST).is_file());
        let v = p.view();
        assert_eq!(v.compositions.len(), 1);
        assert_eq!(v.compositions[0].variations[0].aspect, "9:16");
        assert!(!v.compositions[0].variations[0].empty);
    }
}
