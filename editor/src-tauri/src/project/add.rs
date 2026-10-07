use super::*;

impl Project {
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

    pub(super) fn variation_exists(&self, id: &str) -> bool {
        self.manifest
            .compositions
            .iter()
            .any(|c| c.variations.iter().any(|v| v.id == id))
    }
}
