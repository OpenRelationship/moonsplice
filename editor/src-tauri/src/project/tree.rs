use super::*;

impl Project {
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

    pub(super) fn items_in(
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
