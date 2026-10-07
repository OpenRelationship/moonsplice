//! The app as the live agent sees it: a real engine and a real composition on disk.

use super::*;

/// The app, as far as a tool body can tell: a real engine over a real file, and every change a
/// real lowering that is written and read back.
pub(super) struct Live {
    pub(super) engine: Mutex<Engine>,
    pub(super) doc: Mutex<SourceDoc>,
    pub(super) outline: Mutex<serde_json::Value>,
    pub(super) changes: Mutex<Vec<String>>,
}

impl Live {
    pub(super) fn nodes(&self) -> Vec<NodeRef> {
        let outline = self.outline.lock().unwrap();
        outline["nodes"]
            .as_array()
            .map(|a| {
                a.iter()
                    .map(|n| NodeRef {
                        id: n["id"].as_str().unwrap_or_default().to_string(),
                        kind: n["kind"].as_str().unwrap_or_default().to_string(),
                        line: n["line"].as_u64().map(|l| l as u32),
                        props: n["props"]
                            .as_object()
                            .map(|o| o.keys().cloned().collect())
                            .unwrap_or_default(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}

impl agent::AppBridge for Live {
    fn outline_text(&self) -> Result<String, String> {
        Ok(describe(&self.outline.lock().unwrap()))
    }

    fn at_text(&self, t: f64) -> Result<String, String> {
        let v = self
            .engine
            .lock()
            .unwrap()
            .at(t)
            .map_err(|e| e.to_string())?;
        Ok(describe_instant(&v))
    }

    fn shows_text(&self) -> Result<String, String> {
        Err("the fact log is not available in this test".into())
    }

    fn change(&self, edits: Vec<Edit>, why: &str) -> Result<String, String> {
        let nodes = self.nodes();
        let names = moonsplice_studio_lib::words::names(&self.outline.lock().unwrap());
        let applied = {
            let mut doc = self.doc.lock().unwrap();
            doc.apply(&edits, Some(&nodes), &names).map_err(|r| r.to_string())?
        };
        let hash = self.doc.lock().unwrap().hash().to_string();
        let outline = {
            let engine = self.engine.lock().unwrap();
            engine.reload().map_err(|e| e.to_string())?;
            engine.outline(&hash).map_err(|e| e.to_string())?
        };
        *self.outline.lock().unwrap() = outline;
        self.changes.lock().unwrap().extend(applied.what.clone());
        Ok(format!("changed {} thing(s): {why}", applied.what.len()))
    }

    fn project_text(&self) -> Result<String, String> {
        Ok("The test project holds:\n- Earth night — a clip".into())
    }

    fn place(&self, thing: &str, at: Option<f64>) -> Result<String, String> {
        // The project behind this test holds exactly one clip, so the name has to be that one.
        // The refusal is the app's refusal, in the app's words, because a model that is told
        // something vague retries against nothing.
        if !thing.to_lowercase().contains("earth") {
            return Err(format!(
                "there is nothing called {thing:?} in this project; it holds Earth night"
            ));
        }
        let edit = Edit::Place {
            kind: "video".into(),
            fields: vec![
                ("src".into(), "\"comps/assets/earth_night.webm\"".into()),
                (
                    "from".into(),
                    moonsplice_studio_lib::lower::fmt_num(at.unwrap_or(0.0).max(0.0)),
                ),
            ],
            what: "Earth night".into(),
        };
        self.change(vec![edit], "put Earth night in")?;
        Ok("put Earth night in".into())
    }

    /// The same path a drag in the window takes: a gesture, lowered into edits by the app's own
    /// rules, so what the model can do here is exactly what a person can do with the mouse.
    fn move_clip(
        &self,
        node: &str,
        to: Option<f64>,
        trim: Option<String>,
        at: Option<f64>,
    ) -> Result<String, String> {
        use moonsplice_studio_lib::{words, Edge, Gesture};
        let outline = self.outline.lock().unwrap().clone();
        let names = words::names(&outline);
        let id = words::resolve(&names, node);
        let gesture = match trim.as_deref() {
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
            Some(other) => return Err(format!("there is no {other:?} end to a clip")),
        };
        let edits = moonsplice_studio_lib::gesture_to_edits(gesture, &outline)
            .map_err(|r| r.say(&names))?;
        self.change(edits, "moved a clip")?;
        Ok(match trim {
            Some(edge) => format!("trimmed the {edge} of {node}"),
            None => format!("moved {node}"),
        })
    }

    fn move_when(&self, node: &str, at: f64, which: Option<f64>) -> Result<String, String> {
        use moonsplice_studio_lib::{words, Gesture};
        let outline = self.outline.lock().unwrap().clone();
        let names = words::names(&outline);
        let gesture = Gesture::MoveStart {
            node: words::resolve(&names, node),
            t: at,
            occurrence: which.map(|w| (w as usize).saturating_sub(1)).unwrap_or(0),
        };
        let edits =
            moonsplice_studio_lib::gesture_to_edits(gesture, &outline).map_err(|r| r.say(&names))?;
        self.change(edits, "moved when something starts")?;
        Ok(format!("{node} starts at {at}s"))
    }

    fn restack(&self, node: &str, over: Option<String>) -> Result<String, String> {
        use moonsplice_studio_lib::{words, Gesture};
        let outline = self.outline.lock().unwrap().clone();
        let names = words::names(&outline);
        let gesture = Gesture::Restack {
            node: words::resolve(&names, node),
            over: over.as_deref().map(|o| words::resolve(&names, o)),
        };
        let edits =
            moonsplice_studio_lib::gesture_to_edits(gesture, &outline).map_err(|r| r.say(&names))?;
        self.change(edits, "moved something in the stack")?;
        Ok(format!("moved {node}"))
    }

    fn cut_clip(&self, node: &str, at: f64) -> Result<String, String> {
        use moonsplice_studio_lib::{words, Gesture};
        let outline = self.outline.lock().unwrap().clone();
        let names = words::names(&outline);
        let id = words::resolve(&names, node);
        let edits =
            moonsplice_studio_lib::gesture_to_edits(Gesture::Split { node: id, t: at }, &outline)
                .map_err(|r| r.say(&names))?;
        self.change(edits, "cut a clip in two")?;
        Ok(format!("cut {node} in two"))
    }

    fn note(&self, at: f64, text: &str) -> Result<String, String> {
        use moonsplice_studio_lib::{words, Gesture};
        let outline = self.outline.lock().unwrap().clone();
        let names = words::names(&outline);
        let edits = moonsplice_studio_lib::gesture_to_edits(
            Gesture::Mark {
                t: at,
                text: text.to_string(),
            },
            &outline,
        )
        .map_err(|r| r.say(&names))?;
        self.change(edits, "pinned a note")?;
        Ok(format!("pinned a note at {at}s"))
    }

    /// The ripple, by the same road the keyboard takes: a gesture lowered against the real
    /// outline, so a model that asks for something the composition cannot do is refused in the
    /// same sentence a person would be.
    fn close_gap(&self, node: &str, take_out: bool) -> Result<String, String> {
        use moonsplice_studio_lib::{words, Gesture};
        let outline = self.outline.lock().unwrap().clone();
        let names = words::names(&outline);
        let id = words::resolve(&names, node);
        let g = if take_out {
            Gesture::TakeOutAndClose { node: id }
        } else {
            Gesture::CloseGap { after: id }
        };
        let edits = moonsplice_studio_lib::gesture_to_edits(g, &outline).map_err(|r| r.say(&names))?;
        self.change(edits, "closed a gap")?;
        Ok(format!("closed the gap after {node}"))
    }

    fn undo(&self) -> Result<String, String> {
        let applied = self.doc.lock().unwrap().undo().map_err(|e| e.to_string())?;
        Ok(applied.what.join("; "))
    }

    fn export(&self, quality: &str) -> Result<String, String> {
        Ok(format!("pretended to render at {quality}"))
    }

    fn repaint(&self, _: &str) -> Result<String, String> {
        Err("not connected in this build".into())
    }
}
