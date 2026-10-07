// The agent, against the real model, on a real composition.
//
// Everything else about the agent is tested with a scripted transport, which proves the wiring
// and proves nothing about whether a sentence a person would actually type turns into the right
// edit. That is the question this file asks, and the only way to ask it is to ask a model.
//
// It needs a key and a network, so it does not run by default:
//
//     OPENROUTER_API_KEY=... cargo test --test agent_live -- --ignored --nocapture
//
// Each test is one turn. The assertions are about the composition afterwards -- the words the
// model chose are its own business -- and about the two rules that cannot bend: every change is
// asked for first, and a change that lands is a change the engine can read back.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use moonsplice_studio_lib::agent::{self, Ask, Decision, Said, Surface, Turn};
use moonsplice_studio_lib::engine::Engine;
use moonsplice_studio_lib::lower::{Edit, NodeRef};
use moonsplice_studio_lib::source::SourceDoc;
use moonsplice_studio_lib::{describe, describe_instant};

fn root() -> Option<PathBuf> {
    moonsplice_studio_lib::engine::moonsplice_root()
}

fn key() -> Option<String> {
    std::env::var("OPENROUTER_API_KEY").ok().filter(|k| !k.is_empty())
}

/// Nothing in this file may be named after the case it uses: every test here works on the same
/// composition, so a directory named for the case is a directory two tests running at once both
/// own — and the second one's `remove_dir_all` deletes what the first is in the middle of using.
static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

/// One per engine, never one per case. Four tests here all open the same composition, and a
/// payload ring two of them share is two processes writing `s1.rgba` at each other.
fn serve_dir(name: &str) -> PathBuf {
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let d = std::env::temp_dir().join(format!(
        "moonsplice-studio-live-{name}-{}-{n}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A composition on disk that the test owns, so a turn that writes cannot touch the repo.
struct Scratch {
    dir: PathBuf,
    comp: PathBuf,
}

impl Scratch {
    fn of(root: &Path, case: &str) -> Scratch {
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "moonsplice-studio-live-src-{case}-{}-{n}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("comps/assets/fonts")).unwrap();
        // The comps reference fonts by a path relative to the checkout, so run from there and
        // only the file under edit is a copy.
        let comp = dir.join(format!("{case}.lua"));
        std::fs::copy(root.join(format!("comps/cases/{case}.lua")), &comp).unwrap();
        Scratch { dir, comp }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// The app, as far as a tool body can tell: a real engine over a real file, and every change a
/// real lowering that is written and read back.
struct Live {
    engine: Mutex<Engine>,
    doc: Mutex<SourceDoc>,
    outline: Mutex<serde_json::Value>,
    changes: Mutex<Vec<String>>,
}

impl Live {
    fn nodes(&self) -> Vec<NodeRef> {
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

/// A person who says yes, and writes down what they were asked.
struct Watcher {
    asked: Mutex<Vec<Ask>>,
    chunks: Mutex<Vec<serde_json::Value>>,
    allow: bool,
}

impl Surface for Watcher {
    fn emit(&self, chunk: serde_json::Value) {
        self.chunks.lock().unwrap().push(chunk);
    }
    fn ask(&self, ask: Ask) -> Decision {
        self.asked.lock().unwrap().push(ask);
        Decision {
            allow: self.allow,
            reason: None,
            remember: None,
        }
    }
}

struct Ran {
    outcome: agent::Outcome,
    watcher: Arc<Watcher>,
    before: String,
    after: String,
    outline: serde_json::Value,
}

fn ask(case: &str, prompt: &str, allow: bool) -> Option<Ran> {
    let root = root()?;
    let key = key()?;
    let scratch = Scratch::of(&root, case);
    let engine = Engine::start(&scratch.comp, &root, &serve_dir(case)).expect("the engine starts");
    let doc = SourceDoc::open(&scratch.comp).expect("the composition reads");
    let before = doc.text().to_string();
    let outline = engine.outline(&doc.hash()).expect("an outline");

    let live = Arc::new(Live {
        engine: Mutex::new(engine),
        doc: Mutex::new(doc),
        outline: Mutex::new(outline),
        changes: Mutex::new(Vec::new()),
    });
    let watcher = Arc::new(Watcher {
        asked: Mutex::new(Vec::new()),
        chunks: Mutex::new(Vec::new()),
        allow,
    });
    let paths = agent::Paths::resolve(&root).expect("malleable is in the checkout");

    let outcome = agent::run_turn(
        Turn {
            paths: &paths,
            bridge: live.clone(),
            surface: watcher.clone(),
            transport: Arc::new(agent::Http),
            scheme: "openrouter",
            key: &key,
            model: None,
            budget: None,
            cancel: agent::Cancel::default(),
        },
        prompt,
        &[] as &[Said],
    )
    .expect("the turn runs");

    let after = std::fs::read_to_string(&scratch.comp).expect("the composition is still there");
    let outline = live.outline.lock().unwrap().clone();
    Some(Ran {
        outcome,
        watcher,
        before,
        after,
        outline,
    })
}

fn skip(why: &str) {
    eprintln!("skipped: {why}");
}

/// The brief, enforced on the one surface a model can break it from.
///
/// It reads the composition in the app's own words and says them back. If an id or a property
/// key ever reaches it, it repeats them -- an earlier run of this suite produced "rect4 is the
/// teal bar at the bottom" for someone who opened this app so they would never see that.
fn no_code(said: &str, outline: &serde_json::Value) {
    let said = said.to_lowercase();
    let mut banned: Vec<String> = vec![
        ".lua".into(),
        "s:rect".into(),
        "s:text".into(),
        "e.comp".into(),
        "expoout".into(),
        "sineout".into(),
        "opacity".into(),
        // Its own tools and verbs. The person does not know these exist, and they read as code.
        "set_prop".into(),
        "set_ease".into(),
        "set_tween_duration".into(),
        "pin_prop".into(),
        "set_cue".into(),
    ];
    if let Some(nodes) = outline["nodes"].as_array() {
        banned.extend(nodes.iter().filter_map(|n| {
            n["id"].as_str().map(|i| i.to_lowercase())
        }));
    }
    for word in banned {
        assert!(
            !said.contains(&word),
            "it said `{word}` to someone who never wants to see code:\n{said}"
        );
    }
}

/// The plainest thing a person can ask for that is unambiguously one edit.
#[test]
#[ignore = "needs OPENROUTER_API_KEY and a network"]
fn it_changes_a_curve_when_asked_in_plain_english() {
    let Some(ran) = ask(
        "captions",
        "make the bar arrive more gently — it snaps in too hard right now",
        true,
    ) else {
        return skip("no key or no checkout");
    };
    eprintln!("stop = {} ({:?})", ran.outcome.stop, ran.outcome.reason);
    let said = ran.outcome.answer.clone().unwrap_or_default();
    eprintln!("said: {said}");
    // The whole turn, every time. A model is not deterministic, so a run that goes wrong has
    // to leave behind enough to tell what the app did rather than what the model said it did.
    for c in ran.watcher.chunks.lock().unwrap().iter() {
        let kind = c["type"].as_str().unwrap_or("?");
        if kind == "call" || kind == "result" {
            eprintln!("  {kind}: {}", serde_json::to_string(c).unwrap_or_default());
        }
    }
    no_code(&said, &ran.outline);

    assert_eq!(ran.outcome.stop, "answered", "the turn did not finish");
    if ran.before == ran.after {
        // It said it changed something. Show what actually came back, because a tool that
        // refused and a model that reported success is the worst pair in the system.
        for c in ran.watcher.chunks.lock().unwrap().iter() {
            eprintln!("  chunk {c}");
        }
        for a in ran.watcher.asked.lock().unwrap().iter() {
            eprintln!("  asked {} {}", a.tool, a.args);
        }
        panic!("it said it changed something and the composition is byte-identical");
    }

    // It asked before it wrote. This is the rule, not a preference.
    let asked = ran.watcher.asked.lock().unwrap();
    assert!(!asked.is_empty(), "it changed the composition without asking");
    assert!(
        asked.iter().any(|a| a.tool == "change"),
        "the approval was for something other than a change: {:?}",
        asked.iter().map(|a| &a.tool).collect::<Vec<_>>()
    );
    drop(asked);

    // And the thing it changed is the easing of the bar, which the engine now reads back.
    let ease = ran.outline["tracks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["prop"] == "w")
        .and_then(|t| t["segments"][0]["ease"].as_str())
        .unwrap_or("linear")
        .to_string();
    assert_ne!(ease, "expoOut", "the bar still arrives the way it did");
    eprintln!("the bar now arrives on `{ease}`");
}

/// A refusal is an answer. Nothing may reach the file.
#[test]
#[ignore = "needs OPENROUTER_API_KEY and a network"]
fn a_no_leaves_the_composition_exactly_as_it_was() {
    let Some(ran) = ask("captions", "make the bar arrive more gently", false) else {
        return skip("no key or no checkout");
    };
    eprintln!("stop = {} ({:?})", ran.outcome.stop, ran.outcome.reason);
    assert_eq!(
        ran.before, ran.after,
        "a refused change still reached the file"
    );
    assert!(
        !ran.watcher.asked.lock().unwrap().is_empty(),
        "it never asked, so there was nothing to refuse"
    );
}

/// Asked a question, it should read the composition and answer it, and change nothing.
#[test]
#[ignore = "needs OPENROUTER_API_KEY and a network"]
fn a_question_is_answered_without_touching_anything() {
    let Some(ran) = ask("captions", "what is in this composition?", true) else {
        return skip("no key or no checkout");
    };
    eprintln!("said: {}", ran.outcome.answer.clone().unwrap_or_default());
    assert_eq!(ran.outcome.stop, "answered");
    assert_eq!(ran.before, ran.after, "a question changed the composition");

    let said = ran.outcome.answer.unwrap_or_default().to_lowercase();
    assert!(!said.is_empty(), "it answered with nothing");
    no_code(&said, &ran.outline);
}

/// Something it has no verb for. The right answer is to say so, not to invent one.
#[test]
#[ignore = "needs OPENROUTER_API_KEY and a network"]
fn it_says_so_when_there_is_no_way_to_do_what_was_asked() {
    let Some(ran) = ask(
        "captions",
        "put the caption behind the bar instead of in front of it",
        true,
    ) else {
        return skip("no key or no checkout");
    };
    eprintln!("stop = {} ({:?})", ran.outcome.stop, ran.outcome.reason);
    let said = ran.outcome.answer.clone().unwrap_or_default();
    eprintln!("said: {said}");
    // Restacking has no verb. Whatever it says, it must not have quietly changed something
    // else -- and an earlier run invented a `z` property, which the lowering wrote into the
    // file where nothing reads it.
    assert_eq!(
        ran.before, ran.after,
        "it changed something else instead of saying it could not restack"
    );
    assert!(!ran.after.contains(" z ="), "it invented a z property");
    no_code(&said, &ran.outline);
}

/// The gesture an editor is for, asked for in plain English.
///
/// Nothing new gets into a composition except out of the project, and until `place` existed there
/// was no way for anyone — a person or the agent — to put a clip in at all. This is the whole
/// path against the real model: it reads what is there, asks the person, and the engine reads a
/// composition with a clip in it that was not there before.
#[test]
#[ignore = "needs OPENROUTER_API_KEY and a network"]
fn it_puts_a_clip_in_when_asked_for_one() {
    let Some(ran) = ask(
        "captions",
        "put the earth clip into this composition, starting at the beginning",
        true,
    ) else {
        return skip("no key or no checkout");
    };
    let said = ran.outcome.answer.clone().unwrap_or_default();
    eprintln!("stop = {} ({:?})\nsaid: {said}", ran.outcome.stop, ran.outcome.reason);
    no_code(&said, &ran.outline);

    assert_eq!(ran.outcome.stop, "answered", "the turn did not finish");
    assert_ne!(ran.before, ran.after, "nothing was written");

    // It asked first. Putting something in a composition is a change, and every change is put to
    // the person.
    let asked = ran.watcher.asked.lock().unwrap();
    assert!(
        asked.iter().any(|a| a.tool == "place"),
        "it wrote without being approved for it: {:?}",
        asked.iter().map(|a| &a.tool).collect::<Vec<_>>()
    );
    drop(asked);

    // And the composition now holds a clip the engine can see.
    let video = ran.outline["nodes"]
        .as_array()
        .expect("nodes")
        .iter()
        .find(|n| n["kind"] == "video")
        .expect("the clip is in the composition");
    assert_eq!(video["label"].as_str(), Some("Earth night"), "named as the pane names it");
    assert!(
        video["props"]["src"].is_null(),
        "a file name reached the app: {}",
        video["props"]
    );
}
