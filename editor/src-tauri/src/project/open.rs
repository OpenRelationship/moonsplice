use super::*;

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
    pub(super) fn reconcile(&mut self) -> bool {
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
}
