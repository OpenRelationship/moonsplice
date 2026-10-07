use super::*;

// ----------------------------------------------------------------------------- the agent

pub(super) struct Bridge {
    pub(super) app: AppHandle,
    pub(super) variation: String,
}

impl Bridge {
    pub(super) fn with<T>(&self, f: impl FnOnce(&mut Open) -> Result<T, String>) -> Result<T, String> {
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open
            .get_mut(&self.variation)
            .ok_or("no composition is open")?;
        f(o)
    }
}

impl agent::AppBridge for Bridge {
    fn outline_text(&self) -> Result<String, String> {
        self.with(|o| Ok(describe(&o.outline)))
    }

    fn at_text(&self, t: f64) -> Result<String, String> {
        let v = self.with(|o| o.engine.at(t).map_err(|e| e.to_string()))?;
        Ok(describe_instant(&v))
    }

    fn shows_text(&self) -> Result<String, String> {
        let (root, comp) = {
            let studio = self.app.state::<Studio>();
            let guard = studio.project.lock().unwrap();
            let p = guard.as_ref().ok_or("no project is open")?;
            (
                p.root.clone(),
                p.source_of(&self.variation)
                    .ok_or("that composition is not in this project")?,
            )
        };
        let engine_root =
            engine::moonsplice_root().ok_or("the Moonsplice engine is not next to this app")?;
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
                trouble(&String::from_utf8_lossy(&out.stderr))
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
        let studio = self.app.state::<Studio>();
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or("no project is open")?;
        let view = p.view();
        if view.assets.is_empty() {
            return Ok(format!(
                "{} holds no footage, pictures or sound yet.",
                view.name
            ));
        }
        let mut out = format!("{} holds:", view.name);
        for a in view.assets {
            // The word for the kind, not the enum: this is read by something that answers in
            // words, and "footage" is what the left pane says.
            let kind = match a.kind {
                AssetKind::Footage => "a clip",
                AssetKind::Image => "a picture",
                AssetKind::Audio => "a sound",
                AssetKind::Font => "a typeface",
                AssetKind::Data => "some notes",
                AssetKind::Other => "a file of its own kind",
            };
            out.push_str(&format!("\n- {} — {kind}", a.name));
        }
        out.push_str("\n\nAny of the first three kinds can be put into the composition.");
        Ok(out)
    }

    fn change(&self, edits: Vec<Edit>, why: &str) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        let applied = apply_now(&app, o, &variation, &edits).map_err(|r| r.to_string())?;
        let n = applied["what"].as_array().map(|a| a.len()).unwrap_or(0);
        Ok(format!("changed {n} thing(s): {why}"))
    }

    fn place(&self, thing: &str, at: Option<f64>) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let edit = {
            let guard = studio.project.lock().unwrap();
            let p = guard.as_ref().ok_or("no project is open")?;
            let asset = asset_named(p, thing).ok_or_else(|| {
                let have: Vec<String> = p.view().assets.into_iter().map(|a| a.name).collect();
                format!(
                    "there is nothing called {thing:?} in this project; it holds {}",
                    if have.is_empty() {
                        "nothing yet".to_string()
                    } else {
                        have.join(", ")
                    }
                )
            })?;
            let path = p
                .asset_path(&asset.id)
                .ok_or("that is not one of this project's things")?;
            let rel = path
                .strip_prefix(&p.root)
                .unwrap_or(&path)
                .to_string_lossy()
                .to_string();
            place_edit(&rel, asset.kind, &asset.name, at.unwrap_or(0.0))?
        };
        let what = match &edit {
            Edit::Place { what, .. } => what.clone(),
            _ => thing.to_string(),
        };
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        apply_now(&app, o, &variation, &[edit]).map_err(|r| r.to_string())?;
        Ok(format!("put {what} in"))
    }

    /// Moving a clip along the timeline, or trimming an end of it. The same gesture the drag in
    /// the window makes, so the two cannot drift: what the agent can do is what a person can do.
    fn move_clip(
        &self,
        node: &str,
        to: Option<f64>,
        trim: Option<String>,
        at: Option<f64>,
    ) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        let names = words::names(&o.outline);
        let id = words::resolve(&names, node);
        let gesture = match trim.as_deref() {
            None => {
                let t = to.ok_or("say where it should begin, in seconds")?;
                Gesture::Slide { node: id, t }
            }
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
                    "there is no {other:?} end to a clip; there is the one it starts on and the \
                     one it stops on"
                ))
            }
        };
        let edits = gesture_to_edits(gesture, &o.outline).map_err(|r| r.say(&names))?;
        let applied = apply_now(&app, o, &variation, &edits).map_err(|r| r.to_string())?;
        Ok(applied["what"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .unwrap_or("moved it")
            .to_string())
    }

    /// The razor, by the same road a click on the clip takes.
    fn cut_clip(&self, node: &str, at: f64) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        let names = words::names(&o.outline);
        let id = words::resolve(&names, node);
        let edits = gesture_to_edits(Gesture::Split { node: id, t: at }, &o.outline)
            .map_err(|r| r.say(&names))?;
        let applied = apply_now(&app, o, &variation, &edits).map_err(|r| r.to_string())?;
        Ok(applied["what"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|w| w.as_str())
            .unwrap_or("cut it in two")
            .to_string())
    }

    /// A note pinned to a moment, by the same road the M key takes.
    fn note(&self, at: f64, text: &str) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        let names = words::names(&o.outline);
        let edits = gesture_to_edits(
            Gesture::Mark {
                t: at,
                text: text.to_string(),
            },
            &o.outline,
        )
        .map_err(|r| r.say(&names))?;
        apply_now(&app, o, &variation, &edits).map_err(|r| r.to_string())?;
        Ok(format!("pinned a note at {at}s"))
    }

    /// Closing a hole in the timeline, with or without taking the clip out first.
    ///
    /// The same road the keyboard takes, which is the whole point: a model can do what a person
    /// can do and no more, and is refused in the same sentence when it cannot.
    fn close_gap(&self, node: &str, take_out: bool) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        let names = words::names(&o.outline);
        let id = words::resolve(&names, node);
        let g = if take_out {
            Gesture::TakeOutAndClose { node: id }
        } else {
            Gesture::CloseGap { after: id }
        };
        let edits = gesture_to_edits(g, &o.outline).map_err(|r| r.say(&names))?;
        let applied = apply_now(&app, o, &variation, &edits).map_err(|r| r.to_string())?;
        Ok(applied["what"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|w| w.as_str())
            .unwrap_or("closed the gap")
            .to_string())
    }

    /// When a movement begins, by the same road the left edge of its bar takes. `which` counts
    /// from one, because that is how a person counts and the model is talking to a person.
    fn move_when(&self, node: &str, at: f64, which: Option<f64>) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        let names = words::names(&o.outline);
        let gesture = Gesture::MoveStart {
            node: words::resolve(&names, node),
            t: at,
            occurrence: which.map(|w| (w as usize).saturating_sub(1)).unwrap_or(0),
        };
        let edits = gesture_to_edits(gesture, &o.outline).map_err(|r| r.say(&names))?;
        let applied = apply_now(&app, o, &variation, &edits).map_err(|r| r.to_string())?;
        Ok(applied["what"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|w| w.as_str())
            .unwrap_or("moved it")
            .to_string())
    }

    /// Up and down the stack, by the same road the arrows on the lane take.
    fn restack(&self, node: &str, over: Option<String>) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        let names = words::names(&o.outline);
        let gesture = Gesture::Restack {
            node: words::resolve(&names, node),
            over: over.as_deref().map(|o| words::resolve(&names, o)),
        };
        let edits = gesture_to_edits(gesture, &o.outline).map_err(|r| r.say(&names))?;
        let applied = apply_now(&app, o, &variation, &edits).map_err(|r| r.to_string())?;
        Ok(applied["what"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|w| w.as_str())
            .unwrap_or("moved it")
            .to_string())
    }

    fn undo(&self) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let mut open = studio.open.lock().unwrap();
        let o = open.get_mut(&variation).ok_or("no composition is open")?;
        let applied = o.doc.undo().map_err(|e| e.to_string())?;
        o.refresh_outline()?;
        broadcast(&app, &variation, o, applied.what.clone());
        Ok(applied.what.join("; "))
    }

    fn export(&self, quality: &str) -> Result<String, String> {
        // `export_now` rather than the command: a turn already runs off the main thread, so
        // there is nothing to hand to a blocking pool that it is not already on.
        let studio = self.app.state::<Studio>();
        export_now(
            self.app.clone(),
            &studio,
            self.variation.clone(),
            Some(quality.to_string()),
        )
        .map(|name| format!("rendering at {quality} quality, into {name}"))
    }

    fn repaint(&self, _instruction: &str) -> Result<String, String> {
        // The pixel model is not wired up yet, and saying so is better than pretending. The
        // shape is settled: it takes a rendered video and answers with another one, which
        // enters the project as footage. It never sees the composition.
        Err("the pixel model is not connected in this build, so the render was left alone".into())
    }

    /// The producer's tools, by the road every other change takes: `headless` decides the
    /// edits, `apply_now` writes them and tells the window.
    fn produce(&self, tool: &str, args: serde_json::Value) -> Result<String, String> {
        let app = self.app.clone();
        let variation = self.variation.clone();
        let studio = self.app.state::<Studio>();
        let made = {
            let guard = studio.project.lock().unwrap();
            let p = guard.as_ref().ok_or("no project is open")?;
            let open = studio.open.lock().unwrap();
            let o = open.get(&variation).ok_or("no composition is open")?;
            headless::produce(p, o, tool, &args)?
        };
        match made {
            headless::Produced::Said(s) => Ok(s),
            headless::Produced::Edits(edits, said) => {
                let mut open = studio.open.lock().unwrap();
                let o = open.get_mut(&variation).ok_or("no composition is open")?;
                let names = words::names(&o.outline);
                apply_now(&app, o, &variation, &edits).map_err(|r| r.say(&names))?;
                Ok(said)
            }
        }
    }
}
