use super::*;

// ------------------------------------------------------------------------------- the session

/// One composition, open, with nobody watching.
pub struct Session {
    pub variation: String,
    pub(super) project: Mutex<Project>,
    pub(super) open: Mutex<Open>,
}

impl Session {
    /// Open `comp` in the project at `root`. `comp` is the composition's id, its title, or its
    /// file name; with `None` the project's only composition, or the one called `main`.
    pub fn open(root: &Path, comp: Option<&str>, serve_dir: &Path) -> Result<Session, String> {
        let root = root
            .canonicalize()
            .map_err(|e| format!("{}: {e}", root.display()))?;
        let project = Project::open(&root).map_err(|e| format!("{}: {e}", root.display()))?;
        let variation = pick_variation(&project, comp)?;
        let path = project
            .source_of(&variation)
            .ok_or("that composition is not in this project")?;
        let doc = SourceDoc::open(&path).map_err(|e| e.to_string())?;
        let engine = Engine::start(&path, &root, &serve_dir.join(&variation))
            .map_err(|e| engine::in_words(&e.to_string()).to_string())
            .map_err(|e| if e.is_empty() { "the composition would not open".into() } else { e })?;
        let mut open = Open {
            engine: std::sync::Arc::new(engine),
            doc,
            outline: serde_json::Value::Null,
            nodes: Vec::new(),
            media: HashMap::new(),
            trouble: None,
        };
        let outline = open
            .engine
            .outline(open.doc.hash())
            .map_err(|e| e.to_string())?;
        open.nodes = node_refs(&outline);
        open.outline = outline;
        Ok(Session {
            variation,
            project: Mutex::new(project),
            open: Mutex::new(open),
        })
    }

    pub fn root(&self) -> PathBuf {
        self.project.lock().unwrap().root.clone()
    }

    /// The composition's file.
    pub fn comp_path(&self) -> PathBuf {
        let p = self.project.lock().unwrap();
        p.source_of(&self.variation).unwrap_or_default()
    }

    pub fn outline(&self) -> serde_json::Value {
        self.open.lock().unwrap().outline.clone()
    }

    /// Stop the renderer. Dropping does it too; this is for saying so out loud.
    pub fn close(&self) {
        self.open.lock().unwrap().engine.stop();
    }

    pub(super) fn apply(&self, edits: &[Edit]) -> Result<Vec<String>, String> {
        let mut o = self.open.lock().unwrap();
        apply_headless(&mut o, edits)
    }

    /// A gesture, lowered by the app's own rules and applied. The first thing it did, in words.
    pub(super) fn gesture(&self, g: impl FnOnce(&HashMap<String, String>) -> Result<Gesture, String>) -> Result<String, String> {
        let mut o = self.open.lock().unwrap();
        let names = words::names(&o.outline);
        let gesture = g(&names)?;
        let edits = gesture_to_edits(gesture, &o.outline).map_err(|r| r.say(&names))?;
        let what = apply_headless(&mut o, &edits)?;
        Ok(what.first().cloned().unwrap_or_else(|| "done".into()))
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        if let Ok(o) = self.open.lock() {
            o.engine.stop();
        }
    }
}

/// Write the edits and read the result back -- `apply_now` without the window to tell.
pub(super) fn apply_headless(o: &mut Open, edits: &[Edit]) -> Result<Vec<String>, String> {
    let nodes = o.nodes.clone();
    let names = words::names(&o.outline);
    let engine = o.engine.clone();
    let (applied, outline) =
        write_and_reload(&mut o.doc, &engine, edits, &nodes, &names).map_err(|r| r.say(&names))?;
    o.nodes = node_refs(&outline);
    o.outline = outline;
    o.media.clear();
    Ok(applied.what)
}

/// Which composition `asked` means. An id, a title or a file name; the only one when there is
/// one; `main` when there are several and nothing was asked.
pub fn pick_variation(p: &Project, asked: Option<&str>) -> Result<String, String> {
    let all: Vec<(String, String, String)> = p
        .manifest
        .compositions
        .iter()
        .flat_map(|c| {
            c.variations
                .iter()
                .map(move |v| (v.id.clone(), c.title.clone(), v.source.clone()))
        })
        .collect();
    if all.is_empty() {
        return Err("this project has no composition in it yet (moonsplice-agent init makes one)".into());
    }
    let fold = |s: &str| s.trim().to_lowercase();
    match asked {
        Some(a) => {
            let want = fold(a.trim_end_matches(".lua"));
            all.iter()
                .find(|(id, title, src)| {
                    fold(id) == want
                        || fold(title) == want
                        || fold(src.trim_end_matches(".lua")) == want
                        || Path::new(src)
                            .file_stem()
                            .map(|s| fold(&s.to_string_lossy()) == want)
                            .unwrap_or(false)
                })
                .map(|(id, ..)| id.clone())
                .ok_or_else(|| {
                    let names: Vec<&str> = all.iter().map(|(_, t, _)| t.as_str()).collect();
                    format!("there is no composition called {a:?}; there is {}", names.join(", "))
                })
        }
        None if all.len() == 1 => Ok(all[0].0.clone()),
        None => all
            .iter()
            .find(|(id, ..)| id == "main")
            .map(|(id, ..)| id.clone())
            .ok_or_else(|| "this project has several compositions; say which with --comp".into()),
    }
}

impl AppBridge for Session {
    fn outline_text(&self) -> Result<String, String> {
        Ok(describe(&self.open.lock().unwrap().outline))
    }

    fn at_text(&self, t: f64) -> Result<String, String> {
        let v = {
            let o = self.open.lock().unwrap();
            o.engine.at(t).map_err(|e| e.to_string())?
        };
        Ok(describe_instant(&v))
    }

    fn shows_text(&self) -> Result<String, String> {
        let root = self.root();
        let comp = self.comp_path();
        let engine_root = engine::moonsplice_root().ok_or("the Moonsplice engine is not here")?;
        let rel = comp.strip_prefix(&root).unwrap_or(&comp);
        let out = std::process::Command::new(engine_root.join("bin/moonsplice-vision"))
            .arg("call")
            .arg("fact_log")
            .arg(format!("source={}", rel.display()))
            .current_dir(&root)
            .output()
            .map_err(|e| format!("the fact log is not available here ({e})"))?;
        if !out.status.success() {
            return Err(format!(
                "the fact log is not available here: {}",
                crate::trouble(&String::from_utf8_lossy(&out.stderr))
            ));
        }
        let doc: serde_json::Value = serde_json::from_slice(&out.stdout)
            .map_err(|e| format!("the fact log did not parse ({e})"))?;
        doc["log"]
            .as_str()
            .map(String::from)
            .ok_or_else(|| "the fact log came back empty".into())
    }

    fn project_text(&self) -> Result<String, String> {
        let mut p = self.project.lock().unwrap();
        // Something may have arrived since the session opened -- an export, a file another
        // tool wrote -- and the answer should be the folder as it is.
        if let Ok(fresh) = Project::open(&p.root) {
            *p = fresh;
        }
        Ok(project_words(&p))
    }

    fn change(&self, edits: Vec<Edit>, why: &str) -> Result<String, String> {
        let what = self.apply(&edits)?;
        Ok(format!("changed {} thing(s): {why}", what.len()))
    }

    fn place(&self, thing: &str, at: Option<f64>) -> Result<String, String> {
        let edit = {
            let p = self.project.lock().unwrap();
            let (rel, kind, name) = asset_rel(&p, thing)?;
            place_edit(&rel, kind, &name, at.unwrap_or(0.0))?
        };
        let what = match &edit {
            Edit::Place { what, .. } => what.clone(),
            _ => thing.to_string(),
        };
        self.apply(&[edit])?;
        Ok(format!("put {what} in"))
    }

    fn move_clip(
        &self,
        node: &str,
        to: Option<f64>,
        trim: Option<String>,
        at: Option<f64>,
    ) -> Result<String, String> {
        self.gesture(|names| {
            let id = words::resolve(names, node);
            Ok(match trim.as_deref() {
                None => Gesture::Slide {
                    node: id,
                    t: to.ok_or("say where it should begin, in seconds")?,
                },
                Some("in") | Some("start") | Some("head") => Gesture::Trim {
                    node: id,
                    edge: Edge::In,
                    t: at.or(to).ok_or("say where that end should land, in seconds")?,
                },
                Some("out") | Some("end") | Some("tail") => Gesture::Trim {
                    node: id,
                    edge: Edge::Out,
                    t: at.or(to).ok_or("say where that end should land, in seconds")?,
                },
                Some(other) => {
                    return Err(format!(
                        "there is no {other:?} end to a clip; there is the one it starts on and \
                         the one it stops on"
                    ))
                }
            })
        })
    }

    fn cut_clip(&self, node: &str, at: f64) -> Result<String, String> {
        self.gesture(|names| {
            Ok(Gesture::Split {
                node: words::resolve(names, node),
                t: at,
            })
        })
    }

    fn close_gap(&self, node: &str, take_out: bool) -> Result<String, String> {
        self.gesture(|names| {
            let id = words::resolve(names, node);
            Ok(if take_out {
                Gesture::TakeOutAndClose { node: id }
            } else {
                Gesture::CloseGap { after: id }
            })
        })
    }

    fn note(&self, at: f64, text: &str) -> Result<String, String> {
        self.gesture(|_| {
            Ok(Gesture::Mark {
                t: at,
                text: text.to_string(),
            })
        })?;
        Ok(format!("pinned a note at {at}s"))
    }

    fn restack(&self, node: &str, over: Option<String>) -> Result<String, String> {
        self.gesture(|names| {
            Ok(Gesture::Restack {
                node: words::resolve(names, node),
                over: over.as_deref().map(|o| words::resolve(names, o)),
            })
        })
    }

    fn move_when(&self, node: &str, at: f64, which: Option<f64>) -> Result<String, String> {
        self.gesture(|names| {
            Ok(Gesture::MoveStart {
                node: words::resolve(names, node),
                t: at,
                occurrence: which.map(|w| (w as usize).saturating_sub(1)).unwrap_or(0),
            })
        })
    }

    fn undo(&self) -> Result<String, String> {
        let mut o = self.open.lock().unwrap();
        let applied = o.doc.undo().map_err(|e| e.to_string())?;
        o.refresh_outline()?;
        Ok(applied.what.join("; "))
    }

    /// Rendered where the window renders, and waited for: there is no window to come back to
    /// later and say it finished.
    fn export(&self, quality: &str) -> Result<String, String> {
        let p = self.project.lock().unwrap();
        let plan = crate::plan_export(&p, &self.variation)?;
        crate::run_export(&plan, quality)?;
        Ok(format!("rendered at {quality} quality, into {}", plan.into))
    }

    fn repaint(&self, _instruction: &str) -> Result<String, String> {
        Err("the pixel model is not connected in this build, so the render was left alone".into())
    }

    fn produce(&self, tool: &str, args: serde_json::Value) -> Result<String, String> {
        let made = {
            let p = self.project.lock().unwrap();
            let o = self.open.lock().unwrap();
            produce(&p, &o, tool, &args)?
        };
        match made {
            Produced::Said(s) => Ok(s),
            Produced::Edits(edits, said) => {
                self.apply(&edits)?;
                Ok(said)
            }
        }
    }
}
