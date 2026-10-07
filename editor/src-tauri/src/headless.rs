//! The app with no window: a project, one composition open in it, and every tool the agent has.
//!
//! `moonsplice agent` is the door. It exists because the agent was only reachable from inside
//! the app, and a thing that can only be driven by a person clicking is a thing nobody can
//! measure, script, or hand to another agent. So this is the same agent -- the same declaration,
//! the same tool bodies, the same lowering and the same engine -- with a terminal where the
//! window was.
//!
//! Two halves:
//!
//! - `Session`, the headless `AppBridge`. It owns what `Studio` owns for one composition: the
//!   project, the engine and the source. Every gesture goes down the road the window's goes
//!   down (`gesture_to_edits`, `place_edit`, `write_and_reload`), so there is no second
//!   implementation of a cut or a trim to drift from the first.
//! - The producer's tools -- `transcript`, `keep`, `comp`, `draw`, `captions` -- which turn
//!   footage into a piece rather than adjust a piece that exists. They are written here as
//!   functions of a project and an open composition, returning edits, so the window's `Bridge`
//!   and this one apply the very same edits.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::agent::AppBridge;
use crate::engine::{self, Engine};
use crate::lower::{self, Edit};
use crate::project::{AssetKind, Project};
use crate::source::SourceDoc;
use crate::{
    asset_named, describe, describe_instant, gesture_to_edits, node_refs, place_edit,
    write_and_reload, words, Edge, Gesture, Open,
};

// ------------------------------------------------------------------------------- the session

/// One composition, open, with nobody watching.
pub struct Session {
    pub variation: String,
    project: Mutex<Project>,
    open: Mutex<Open>,
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

    fn apply(&self, edits: &[Edit]) -> Result<Vec<String>, String> {
        let mut o = self.open.lock().unwrap();
        apply_headless(&mut o, edits)
    }

    /// A gesture, lowered by the app's own rules and applied. The first thing it did, in words.
    fn gesture(&self, g: impl FnOnce(&HashMap<String, String>) -> Result<Gesture, String>) -> Result<String, String> {
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
fn apply_headless(o: &mut Open, edits: &[Edit]) -> Result<Vec<String>, String> {
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

/// What the project holds, in the words `project` answers with.
pub(crate) fn project_words(p: &Project) -> String {
    let view = p.view();
    if view.assets.is_empty() {
        return format!("{} holds no footage, pictures or sound yet.", view.name);
    }
    let mut out = format!("{} holds:", view.name);
    for a in view.assets {
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
    out
}

/// One of the project's things by the name the person uses: where it is, relative to the
/// project, what kind it is, and its name.
fn asset_rel(p: &Project, thing: &str) -> Result<(String, AssetKind, String), String> {
    let asset = asset_named(p, thing).ok_or_else(|| {
        let have: Vec<String> = p.view().assets.into_iter().map(|a| a.name).collect();
        format!(
            "there is nothing called {thing:?} in this project; it holds {}",
            if have.is_empty() { "nothing yet".to_string() } else { have.join(", ") }
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
    Ok((rel, asset.kind, asset.name))
}

// ------------------------------------------------------------------------ the producer's tools

/// What a producer tool came back with: words to say, or edits to apply and words to say once
/// they have landed.
pub(crate) enum Produced {
    Said(String),
    Edits(Vec<Edit>, String),
}

pub(crate) fn produce(
    p: &Project,
    o: &Open,
    tool: &str,
    args: &serde_json::Value,
) -> Result<Produced, String> {
    match tool {
        "transcript" => transcript(p, args).map(Produced::Said),
        "keep" => keep(p, o, args),
        "comp" => comp(args),
        "draw" => draw(p, o, args),
        "captions" => captions(p, o, args),
        other => Err(format!("there is no producer tool called {other:?}")),
    }
}

fn num(v: &serde_json::Value, key: &str) -> Option<f64> {
    match &v[key] {
        serde_json::Value::Number(n) => n.as_f64(),
        serde_json::Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn text(v: &serde_json::Value, key: &str) -> Option<String> {
    v[key].as_str().map(str::to_string).filter(|s| !s.trim().is_empty())
}

/// A field a model may have sent as an object or as a string of JSON (see `agent::loosen`).
fn shape(v: &serde_json::Value, key: &str) -> serde_json::Value {
    match &v[key] {
        serde_json::Value::String(s) => serde_json::from_str(s).unwrap_or(serde_json::Value::Null),
        other => other.clone(),
    }
}

/// A length as a person says it: "3.4s" under a minute, "13:35" past one.
fn secs(v: f64) -> String {
    if v < 60.0 {
        format!("{}s", r2(v))
    } else {
        let whole = v.round() as u64;
        format!("{}:{:02}", whole / 60, whole % 60)
    }
}

fn r2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

fn comp_size(o: &Open) -> (f64, f64, f64) {
    let c = &o.outline["comp"];
    (
        c["width"].as_f64().unwrap_or(1920.0),
        c["height"].as_f64().unwrap_or(1080.0),
        c["duration"].as_f64().unwrap_or(5.0),
    )
}

// ---------------------------------------------------------------------------------- media

/// What identifies a file's content cheaply: its length and the first and last mebibyte.
///
/// A whole-file hash of a 1.5 GB take is twenty seconds of reading to answer a question whose
/// answer almost never changes; a file that is edited in the middle and keeps its length and
/// both ends is not a thing a camera or an exporter makes.
pub fn media_key(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    use std::io::{Seek, SeekFrom};
    let mut f = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let len = f.metadata().map_err(|e| e.to_string())?.len();
    let mut h = Sha256::new();
    h.update(len.to_le_bytes());
    let mut buf = vec![0u8; 1 << 20];
    let n = f.read(&mut buf).map_err(|e| e.to_string())?;
    h.update(&buf[..n]);
    if len > (2 << 20) {
        f.seek(SeekFrom::End(-(1 << 20))).map_err(|e| e.to_string())?;
        let n = f.read(&mut buf).map_err(|e| e.to_string())?;
        h.update(&buf[..n]);
    }
    let digest = h.finalize();
    Ok(digest.iter().take(10).map(|b| format!("{b:02x}")).collect())
}

/// `~/.cache/moonsplice/<what>`, shared by every project on the machine: a transcript or a proxy of
/// the same take is the same whichever project asked for it.
pub fn shared_cache(what: &str) -> PathBuf {
    let base = std::env::var("MOONSPLICE_CACHE")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".cache/moonsplice")))
        .unwrap_or_else(|_| std::env::temp_dir().join("moonsplice-cache"));
    base.join(what)
}

/// How long a file is, by ffprobe.
pub fn media_duration(path: &Path) -> Result<f64, String> {
    let out = std::process::Command::new("ffprobe")
        .args(["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0"])
        .arg(path)
        .output()
        .map_err(|e| format!("ffprobe did not run ({e})"))?;
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse::<f64>()
        .map_err(|_| "could not tell how long that is".into())
}

/// The words in a file, with their times. Cached in the project (`.moonsplice/transcripts/`) and on
/// the machine, so a fourteen minute take is listened to once.
pub fn words_of(root: &Path, path: &Path) -> Result<serde_json::Value, String> {
    let key = media_key(path)?;
    let local = root.join(".moonsplice/transcripts").join(format!("{key}.json"));
    let shared = shared_cache("transcripts").join(format!("{key}.json"));
    for p in [&local, &shared] {
        if let Ok(t) = std::fs::read_to_string(p) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) {
                if v["words"].is_array() {
                    if p == &shared {
                        let _ = std::fs::create_dir_all(local.parent().unwrap());
                        let _ = std::fs::write(&local, &t);
                    }
                    return Ok(v);
                }
            }
        }
    }
    let engine_root = engine::moonsplice_root().ok_or("the Moonsplice engine is not here")?;
    let out = std::process::Command::new(engine_root.join("bin/moonsplice-transcribe"))
        .arg(path)
        .output()
        .map_err(|e| format!("the transcriber did not start ({e})"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!(
            "the transcriber could not hear it: {}",
            err.lines().last().unwrap_or("no reason given")
        ));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("the transcript did not parse ({e})"))?;
    let text = v.to_string();
    for p in [&local, &shared] {
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        let _ = std::fs::write(p, &text);
    }
    Ok(v)
}

#[derive(Debug, Clone)]
pub struct Word {
    pub word: String,
    pub start: f64,
    pub end: f64,
}

fn word_list(v: &serde_json::Value) -> Vec<Word> {
    v["words"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|w| {
                    Some(Word {
                        word: w["word"].as_str()?.trim().to_string(),
                        start: w["start"].as_f64()?,
                        end: w["end"].as_f64()?,
                    })
                })
                .filter(|w| !w.word.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// Words into phrases, at the pauses and the full stops: the unit somebody cutting a talking
/// head actually chooses between.
pub fn phrases(ws: &[Word], max_words: usize, gap: f64) -> Vec<(f64, f64, String)> {
    let mut out: Vec<(f64, f64, Vec<&str>)> = Vec::new();
    for (i, w) in ws.iter().enumerate() {
        let start_new = match out.last() {
            None => true,
            Some((_, end, said)) => {
                let prev = &ws[i - 1].word;
                w.start - end > gap
                    || said.len() >= max_words
                    || (said.len() >= 4 && prev.ends_with(['.', '?', '!']))
            }
        };
        if start_new {
            out.push((w.start, w.end, vec![w.word.as_str()]));
        } else {
            let last = out.last_mut().unwrap();
            last.1 = w.end;
            last.2.push(w.word.as_str());
        }
    }
    out.into_iter()
        .map(|(a, b, said)| (a, b, said.join(" ")))
        .collect()
}

/// `transcript`: what is said in a clip or a sound, a phrase a line, in the clip's own seconds.
fn transcript(p: &Project, args: &serde_json::Value) -> Result<String, String> {
    let thing = text(args, "thing").ok_or("say which clip or sound to listen to")?;
    let (rel, kind, name) = asset_rel(p, &thing)?;
    if !matches!(kind, AssetKind::Footage | AssetKind::Audio) {
        return Err(format!("{name} has nothing to listen to"));
    }
    let path = p.root.join(&rel);
    let v = words_of(&p.root, &path)?;
    let ws = word_list(&v);
    let from = num(args, "from").unwrap_or(0.0);
    let to = num(args, "to").unwrap_or(f64::INFINITY);
    let picked: Vec<Word> = ws
        .into_iter()
        .filter(|w| w.end > from && w.start < to)
        .collect();
    let total = v["duration"].as_f64().unwrap_or(0.0);
    let mut out = format!(
        "{name}: {} long, {} words heard{}. Times are seconds in {name}'s own time -- what `keep` \
         takes. One phrase a line, broken at pauses.",
        secs(total),
        picked.len(),
        if from > 0.0 || to.is_finite() {
            format!(" between {}s and {}s", r2(from), if to.is_finite() { r2(to).to_string() } else { "the end".into() })
        } else {
            String::new()
        },
    );
    for (a, b, said) in phrases(&picked, 16, 0.55) {
        out.push_str(&format!("\n[{:.2}–{:.2}] {said}", a, b));
    }
    if picked.is_empty() {
        out.push_str("\nNothing is said there.");
    }
    Ok(out)
}

/// `keep`: lay chosen stretches of a clip end to end. Each stretch becomes a piece of picture and
/// the matching piece of its sound, because a video in Moonsplice is silent -- the encode hears only
/// sound nodes (`core/runtime/main.lua`) -- and a talking head with no voice is no use to anybody.
fn keep(p: &Project, o: &Open, args: &serde_json::Value) -> Result<Produced, String> {
    let thing = text(args, "thing").ok_or("say which clip to keep parts of")?;
    let (rel, kind, name) = asset_rel(p, &thing)?;
    if !matches!(kind, AssetKind::Footage | AssetKind::Audio) {
        return Err(format!("{name} is not footage or sound, so there is nothing to keep"));
    }
    let length = media_duration(&p.root.join(&rel))?;
    let ranges = match shape(args, "ranges") {
        serde_json::Value::Array(a) => a,
        _ => return Err("ranges are a list of [start, end] pairs, in seconds of the clip".into()),
    };
    let mut kept: Vec<(f64, f64)> = Vec::new();
    for (i, r) in ranges.iter().enumerate() {
        let pair = match r {
            serde_json::Value::Array(a) if a.len() == 2 => (a[0].as_f64(), a[1].as_f64()),
            serde_json::Value::Object(_) => (num(r, "start").or(num(r, "from")), num(r, "end").or(num(r, "to"))),
            _ => (None, None),
        };
        let (a, b) = match pair {
            (Some(a), Some(b)) => (a, b),
            _ => return Err(format!("range {} is not a [start, end] pair of seconds", i + 1)),
        };
        if !(b > a) || a < 0.0 {
            return Err(format!("range {} ({a}–{b}) does not run forwards from zero or later", i + 1));
        }
        if a >= length {
            return Err(format!(
                "range {} starts at {a}s, after {name} has ended ({}s long)",
                i + 1,
                r2(length)
            ));
        }
        kept.push((r2(a), r2(b.min(length))));
    }
    if kept.is_empty() {
        return Err("no ranges were given, so nothing was kept".into());
    }
    let mut sorted = kept.clone();
    sorted.sort_by(|x, y| x.0.partial_cmp(&y.0).unwrap());
    for w in sorted.windows(2) {
        if w[1].0 < w[0].1 - 0.01 {
            return Err(format!(
                "{}–{} and {}–{} overlap, so the same words would be heard twice",
                w[0].0, w[0].1, w[1].0, w[1].1
            ));
        }
    }

    let (cw, ch, cdur) = comp_size(o);
    let at0 = num(args, "at").unwrap_or(0.0).max(0.0);
    let sound = args["sound"].as_bool().unwrap_or(true);
    let picture = kind == AssetKind::Footage && args["picture"].as_bool().unwrap_or(true);
    let volume = num(args, "volume");
    let bx = shape(args, "box");
    let src = format!("\"{}\"", lower::escape_lua(&rel));

    let mut edits = Vec::new();
    let mut t = at0;
    let mut lines = Vec::new();
    for (i, (a, b)) in kept.iter().enumerate() {
        let d = r2(b - a);
        let label = format!("\"{} {}\"", lower::escape_lua(&name), i + 1);
        if picture {
            let mut fields = vec![
                ("src".to_string(), src.clone()),
                ("label".to_string(), label.clone()),
                ("from".to_string(), lower::fmt_num(r2(t))),
                ("duration".to_string(), lower::fmt_num(d)),
                ("media_start".to_string(), lower::fmt_num(*a)),
            ];
            for k in ["x", "y", "w", "h"] {
                if let Some(v) = num(&bx, k) {
                    fields.push((k.to_string(), lower::fmt_num(r2(v))));
                }
            }
            if bx["anchor"].is_string() {
                fields.push(("anchor".into(), format!("\"{}\"", lower::escape_lua(bx["anchor"].as_str().unwrap()))));
            }
            edits.push(Edit::Place {
                kind: "video".into(),
                fields,
                what: format!("{name} {}", i + 1),
            });
        }
        if sound {
            let mut fields = vec![
                ("src".to_string(), src.clone()),
                ("label".to_string(), format!("\"{} {} sound\"", lower::escape_lua(&name), i + 1)),
                ("at".to_string(), lower::fmt_num(r2(t))),
                ("duration".to_string(), lower::fmt_num(d)),
                ("media_start".to_string(), lower::fmt_num(*a)),
                // A cut in the middle of a waveform clicks; three hundredths of a second is
                // under anything a listener hears as a fade.
                ("fade_in".to_string(), "0.03".into()),
                ("fade_out".to_string(), "0.03".into()),
            ];
            if let Some(v) = volume {
                fields.push(("volume".into(), lower::fmt_num(v)));
            }
            edits.push(Edit::Place {
                kind: "audio".into(),
                fields,
                what: format!("{name} {} sound", i + 1),
            });
        }
        lines.push(format!("- {} {}: {}s–{}s of the piece, from {a}s–{b}s of {name}", name, i + 1, r2(t), r2(t + d)));
        t = r2(t + d);
    }
    let mut said = format!(
        "kept {} piece(s) of {name}, {} in all, laid end to end from {}s to {}s{}.",
        kept.len(),
        secs(t - at0),
        r2(at0),
        r2(t),
        if picture && bx.is_null() {
            format!(", filling the {cw}x{ch} frame")
        } else {
            String::new()
        }
    );
    if t > cdur {
        // The composition's length is fixed (.robot/docs/design.robot), and a piece that runs past it is cut
        // off at the encode without a word. Longer is what was meant; say so and do it.
        edits.insert(
            0,
            Edit::SetComp {
                width: None,
                height: None,
                duration: Some(r2(t)),
                fps: None,
                background: None,
            },
        );
        said.push_str(&format!(" The composition was {}s long, so it is now {}s.", r2(cdur), r2(t)));
    }
    said.push('\n');
    said.push_str(&lines.join("\n"));
    Ok(Produced::Edits(edits, said))
}

/// `comp`: the composition's own frame.
fn comp(args: &serde_json::Value) -> Result<Produced, String> {
    let e = Edit::SetComp {
        width: num(args, "width").map(|v| v.round() as u32),
        height: num(args, "height").map(|v| v.round() as u32),
        duration: num(args, "duration").map(r2),
        fps: num(args, "fps"),
        background: text(args, "background"),
    };
    let said = e.describe(&HashMap::new());
    Ok(Produced::Edits(vec![e], said))
}

const DRAWABLE: &[&str] = &["text", "rect", "circle", "image", "surface"];

/// Keys a drawn thing may be given. The rest of what the renderer knows is reachable by writing
/// a composition by hand; this is the part a model gets right without reading the renderer.
const DRAW_KEYS: &[&str] = &[
    "x", "y", "w", "h", "r", "rx", "text", "size", "color", "font", "anchor", "wrap", "leading",
    "align", "tracking", "opacity", "rotation", "scale", "src", "fit", "stroke", "stroke_width",
    "shadow", "blend", "weight",
];

/// `draw`: a title card, a label, a block, a picture -- on for a stretch, with a way in and a way
/// out. The block of Lua is written here, from these arguments and nothing else.
fn draw(p: &Project, o: &Open, args: &serde_json::Value) -> Result<Produced, String> {
    let kind = text(args, "kind").ok_or("say what kind of thing to draw: text, rect, circle or image")?;
    if !DRAWABLE.contains(&kind.as_str()) {
        return Err(format!("{kind} is not something draw makes; it makes {}", DRAWABLE.join(", ")));
    }
    let what = text(args, "what").unwrap_or_else(|| kind.clone());
    let props = shape(args, "props");
    let props = props.as_object().cloned().unwrap_or_default();
    let (_, _, cdur) = comp_size(o);
    let from = num(args, "from").unwrap_or(0.0).max(0.0);
    let to = num(args, "to").unwrap_or(cdur).min(cdur);
    if !(to > from) {
        return Err(format!(
            "it would be on screen from {from}s to {to}s, which is no time at all (the composition is {}s long)",
            r2(cdur)
        ));
    }
    let span = to - from;
    let enter = text(args, "enter").unwrap_or_else(|| "fade".into());
    let exit = text(args, "exit").unwrap_or_else(|| "fade".into());
    let over = num(args, "over").unwrap_or(0.45).clamp(0.05, 3.0).min(span / 2.0);

    let mut fields: Vec<(String, String)> = Vec::new();
    let mut target_opacity = 1.0;
    let mut y = None;
    let mut w = None;
    let mut scale = 1.0;
    for (k, v) in &props {
        if !DRAW_KEYS.contains(&k.as_str()) {
            return Err(format!(
                "{k} is not something draw can set; it sets {}",
                DRAW_KEYS.join(", ")
            ));
        }
        let lit = match (k.as_str(), v) {
            ("font", serde_json::Value::String(f)) => {
                let (rel, fkind, _) = asset_rel(p, f)?;
                if fkind != AssetKind::Font {
                    return Err(format!("{f} is not a typeface"));
                }
                format!("\"{}\"", lower::escape_lua(&rel))
            }
            ("src", serde_json::Value::String(f)) => {
                let (rel, fkind, _) = asset_rel(p, f)?;
                if fkind != AssetKind::Image {
                    return Err(format!("{f} is not a picture"));
                }
                format!("\"{}\"", lower::escape_lua(&rel))
            }
            ("shadow", serde_json::Value::Object(_)) | ("stroke", serde_json::Value::Object(_)) => {
                lua_table(v).ok_or_else(|| format!("{k} has something in it that is not a number or a word"))?
            }
            _ => lower::lua_literal(v)
                .ok_or_else(|| format!("{k} should be a number, a word or a switch"))?,
        };
        match k.as_str() {
            "opacity" => {
                target_opacity = v.as_f64().unwrap_or(1.0);
                continue;
            }
            "y" => y = v.as_f64(),
            "w" => w = v.as_f64(),
            "scale" => scale = v.as_f64().unwrap_or(1.0),
            _ => {}
        }
        fields.push((k.clone(), lit));
    }
    if kind == "image" && !props.contains_key("src") {
        return Err("a picture needs src: the name of one of the project's pictures".into());
    }
    if kind == "text" && !props.contains_key("text") {
        return Err("writing needs text".into());
    }
    fields.push(("label".into(), format!("\"{}\"", lower::escape_lua(&what))));

    // Where it starts from, for the way in.
    let mut start = vec![("opacity".to_string(), "0".to_string())];
    let mut arrive = vec![("opacity".to_string(), lower::fmt_num(target_opacity))];
    match enter.as_str() {
        "none" | "cut" | "fade" => {}
        "rise" => {
            let y = y.ok_or("rise needs a y to rise to")?;
            start.push(("y".into(), lower::fmt_num(r2(y + 36.0))));
            arrive.push(("y".into(), lower::fmt_num(y)));
        }
        "pop" => {
            start.push(("scale".into(), lower::fmt_num(r2(scale * 0.82))));
            arrive.push(("scale".into(), lower::fmt_num(scale)));
        }
        "wipe" => {
            let w = w.ok_or("wipe needs a w to grow to")?;
            start.push(("w".into(), "0".into()));
            arrive.push(("w".into(), lower::fmt_num(w)));
        }
        "type" => {
            if kind != "text" {
                return Err("only writing can be typed on".into());
            }
            start.push(("reveal".into(), "0".into()));
            arrive.push(("reveal".into(), "1".into()));
        }
        other => {
            return Err(format!(
                "{other} is not a way in; there is fade, rise, pop, wipe, type and none"
            ))
        }
    }
    for (k, v) in &start {
        if let Some(f) = fields.iter_mut().find(|(fk, _)| fk == k) {
            f.1 = v.clone();
        } else {
            fields.push((k.clone(), v.clone()));
        }
    }
    let leave: Vec<(String, String)> = match exit.as_str() {
        "none" | "cut" | "fade" => vec![("opacity".into(), "0".into())],
        "drop" => {
            let mut v = vec![("opacity".to_string(), "0".to_string())];
            if let Some(y) = y {
                v.push(("y".into(), lower::fmt_num(r2(y + 24.0))));
            }
            v
        }
        other => return Err(format!("{other} is not a way out; there is fade, drop and none")),
    };
    let table = |kv: &[(String, String)]| {
        kv.iter()
            .map(|(k, v)| format!("{k} = {v}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let cut_in = matches!(enter.as_str(), "none" | "cut");
    let cut_out = matches!(exit.as_str(), "none" | "cut") || to >= cdur - 1e-6;
    let mut script = vec![format!("    t:at({})", lower::fmt_num(r2(from)))];
    if cut_in {
        script.push(format!("    t:set(n, {{ {} }})", table(&arrive)));
    } else {
        let ease = if enter == "pop" { "backOut" } else if enter == "type" { "linear" } else { "expoOut" };
        let dur = if enter == "type" { (span * 0.5).min(0.04 * props.get("text").and_then(|t| t.as_str()).map(|t| t.len() as f64).unwrap_or(20.0)).max(over) } else { over };
        script.push(format!("    t:tween(n, {}, {{ {} }}, \"{ease}\")", lower::fmt_num(r2(dur)), table(&arrive)));
    }
    if !(to >= cdur - 1e-6 && exit != "none") || !cut_out {
        if cut_out {
            script.push(format!("    t:at({})", lower::fmt_num(r2(to))));
            script.push(format!("    t:set(n, {{ {} }})", table(&leave)));
        } else {
            script.push(format!("    t:at({})", lower::fmt_num(r2(to - over))));
            script.push(format!("    t:tween(n, {}, {{ {} }}, \"sineIn\")", lower::fmt_num(r2(over)), table(&leave)));
        }
    }
    let lua = format!(
        "do -- {}\n  local n = s:{kind} {{ {} }}\n  s:script(function(t)\n{}\n  end)\nend\n",
        what.replace('\n', " "),
        table(&fields),
        script.join("\n").replace("\n    ", "\n    "),
    );
    let said = format!(
        "drew {what}: on from {}s to {}s, in by {enter}, out by {exit}",
        r2(from),
        r2(to)
    );
    Ok(Produced::Edits(vec![Edit::Insert { lua, what }], said))
}

/// A flat JSON object as a Lua table literal, or `None` if anything in it is not a plain value.
fn lua_table(v: &serde_json::Value) -> Option<String> {
    let o = v.as_object()?;
    let mut parts = Vec::new();
    for (k, v) in o {
        if !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return None;
        }
        parts.push(format!("{k} = {}", lower::lua_literal(v)?));
    }
    Some(format!("{{ {} }}", parts.join(", ")))
}

/// `captions`: the words of a clip, on screen while they are heard, wherever its pieces landed.
///
/// Read off the composition as it stands -- which stretches of the clip are where -- so captions
/// made after `keep`, a trim or a cut follow the edit rather than the raw take.
fn captions(p: &Project, o: &Open, args: &serde_json::Value) -> Result<Produced, String> {
    let thing = text(args, "thing").ok_or("say whose words to caption")?;
    let (rel, _, name) = asset_rel(p, &thing)?;
    let file = p.root.join(&rel);
    let want = file.canonicalize().unwrap_or(file.clone());
    let media = o.engine.media().map_err(|e| e.to_string())?;
    let is_it = |id: &str| {
        media
            .get(id)
            .map(|f| {
                let f = if f.is_absolute() { f.clone() } else { p.root.join(f) };
                f.canonicalize().unwrap_or(f) == want
            })
            .unwrap_or(false)
    };
    // Where each heard stretch of it sits: (composition time, clip time, length).
    let mut pieces: Vec<(f64, f64, f64)> = Vec::new();
    for a in o.outline["audio"].as_array().cloned().unwrap_or_default() {
        if is_it(a["id"].as_str().unwrap_or("")) {
            pieces.push((
                a["at"].as_f64().unwrap_or(0.0),
                a["media_start"].as_f64().unwrap_or(0.0),
                a["duration"].as_f64().unwrap_or(0.0),
            ));
        }
    }
    if pieces.is_empty() {
        return Err(format!(
            "none of {name} is heard in the composition yet, so there is nothing to caption (keep some of it first)"
        ));
    }
    pieces.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
    let ws = word_list(&words_of(&p.root, &file)?);
    let per = num(args, "words").unwrap_or(5.0).clamp(1.0, 14.0) as usize;
    let mut cues: Vec<(f64, f64, String)> = Vec::new();
    for (at, ms, d) in &pieces {
        let inside: Vec<Word> = ws
            .iter()
            .filter(|w| w.start >= ms - 0.05 && w.end <= ms + d + 0.08)
            .map(|w| Word {
                word: w.word.clone(),
                start: at + (w.start - ms).max(0.0),
                end: (at + (w.end - ms)).min(at + d),
            })
            .collect();
        let ph = phrases(&inside, per, 0.45);
        for (i, (a, b, said)) in ph.iter().enumerate() {
            let next = ph.get(i + 1).map(|n| n.0).unwrap_or(at + d);
            let end = (b + 0.35).min(next).min(at + d);
            cues.push((r2(*a), r2(end.max(a + 0.2)), said.clone()));
        }
    }
    if cues.is_empty() {
        return Err(format!("nothing is said in the parts of {name} that are heard"));
    }
    let (cw, ch, _) = comp_size(o);
    let style = shape(args, "style");
    let mut fields: Vec<(String, String)> = vec![
        ("x".into(), lower::fmt_num(num(&style, "x").unwrap_or(cw / 2.0).round())),
        ("y".into(), lower::fmt_num(num(&style, "y").unwrap_or((ch * 0.86).round()))),
        ("size".into(), lower::fmt_num(num(&style, "size").unwrap_or((ch * 0.042).round()))),
        ("color".into(), format!("\"{}\"", lower::escape_lua(&text(&style, "color").unwrap_or_else(|| "#ffffff".into())))),
        ("anchor".into(), format!("\"{}\"", lower::escape_lua(&text(&style, "anchor").unwrap_or_else(|| "center".into())))),
        ("label".into(), format!("\"{} captions\"", lower::escape_lua(&name))),
    ];
    if let Some(f) = text(&style, "font") {
        let (frel, fkind, _) = asset_rel(p, &f)?;
        if fkind != AssetKind::Font {
            return Err(format!("{f} is not a typeface"));
        }
        fields.push(("font".into(), format!("\"{}\"", lower::escape_lua(&frel))));
    }
    if let Some(sh) = style.get("shadow").filter(|v| v.is_object()).and_then(lua_table) {
        fields.push(("shadow".into(), sh));
    }
    let lit = cues
        .iter()
        .map(|(a, b, t)| format!("{{ {}, {}, \"{}\" }}", lower::fmt_num(*a), lower::fmt_num(*b), lower::escape_lua(t)))
        .collect::<Vec<_>>()
        .join(", ");
    fields.push(("cues".into(), format!("{{ {lit} }}")));
    let said = format!(
        "captioned {name}: {} lines over {} piece(s), from {}s to {}s",
        cues.len(),
        pieces.len(),
        cues.first().map(|c| c.0).unwrap_or(0.0),
        cues.last().map(|c| c.1).unwrap_or(0.0)
    );
    Ok(Produced::Edits(
        vec![Edit::Place {
            kind: "captions".into(),
            fields,
            what: format!("{name} captions"),
        }],
        said,
    ))
}

// ------------------------------------------------------------------------------- a new project

/// What `init` made.
#[derive(Debug, serde::Serialize)]
pub struct Made {
    pub project: PathBuf,
    pub comp: String,
    pub comp_file: PathBuf,
    pub footage: Vec<serde_json::Value>,
}

/// Which way up a file says it is meant to be shown, from its display matrix. Phones store a
/// portrait take as landscape pixels and a rotation, and the renderer's decoder paints the
/// pixels.
pub fn rotation_of(path: &Path) -> i64 {
    let out = std::process::Command::new("ffprobe")
        .args([
            "-v", "error", "-select_streams", "v:0", "-show_entries",
            "stream_side_data=rotation", "-of", "csv=p=0",
        ])
        .arg(path)
        .output();
    out.ok()
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .find_map(|l| l.trim().trim_matches(',').parse::<f64>().ok())
        })
        .map(|r| r.round() as i64)
        .unwrap_or(0)
}

/// An upright copy of a take that is stored on its side, made once per machine.
///
/// The renderer's decoder reads the pixels as they are stored and ignores the rotation a phone
/// writes beside them, so an iPhone portrait take paints lying down. Teaching the decoder is
/// the right fix and a renderer change (goldens and all); until then the take is turned upright
/// once, here, on the hardware encoder, and the project uses the copy. The sound is copied, not
/// re-encoded, so a transcript of either is the same transcript.
pub fn upright(path: &Path) -> Result<PathBuf, String> {
    let key = media_key(path)?;
    let dir = shared_cache("upright");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let out = dir.join(format!("{key}.mp4"));
    if out.is_file() && media_duration(&out).is_ok() {
        return Ok(out);
    }
    let tmp = dir.join(format!("{key}.part.mp4"));
    let venc: &[&str] = if cfg!(target_os = "macos") {
        &["-c:v", "h264_videotoolbox", "-b:v", "10M"]
    } else {
        &["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"]
    };
    let status = std::process::Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-i"])
        .arg(path)
        .args(["-map", "0:v:0", "-map", "0:a:0?"])
        .args(venc)
        .args(["-pix_fmt", "yuv420p", "-c:a", "copy", "-movflags", "+faststart"])
        .arg(&tmp)
        .status()
        .map_err(|e| format!("ffmpeg did not start ({e})"))?;
    if !status.success() {
        let _ = std::fs::remove_file(&tmp);
        return Err("could not turn that take upright".into());
    }
    std::fs::rename(&tmp, &out).map_err(|e| e.to_string())?;
    Ok(out)
}

/// A project folder with footage in it and an empty composition, ready for an agent.
pub fn init(
    dir: &Path,
    footage: &[PathBuf],
    comp: &str,
    size: (u32, u32),
    fps: f64,
    duration: f64,
) -> Result<Made, String> {
    std::fs::create_dir_all(dir.join("Footage")).map_err(|e| format!("{}: {e}", dir.display()))?;
    let root = dir.canonicalize().map_err(|e| e.to_string())?;
    let mut made_footage = Vec::new();
    for f in footage {
        let f = f.canonicalize().map_err(|e| format!("{}: {e}", f.display()))?;
        let rot = rotation_of(&f);
        let stem = f.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "clip".into());
        let (target, name, note) = if rot % 360 != 0 {
            let up = upright(&f)?;
            (up, format!("{stem}.mp4"), Some(format!("stored turned {rot}°; the project uses an upright copy")))
        } else {
            (f.clone(), f.file_name().unwrap().to_string_lossy().to_string(), None)
        };
        let link = root.join("Footage").join(&name);
        let _ = std::fs::remove_file(&link);
        link_or_copy(&target, &link)?;
        made_footage.push(serde_json::json!({
            "source": f,
            "path": link.strip_prefix(&root).unwrap_or(&link),
            "upright_copy": note.is_some(),
            "note": note,
            "duration": media_duration(&target).ok(),
        }));
    }
    // Typefaces from the checkout, so writing can be set in something better than the default
    // and a composition outside the checkout can still find them.
    if let Some(engine_root) = engine::moonsplice_root() {
        let fonts = engine_root.join("comps/assets/fonts");
        if let Ok(rd) = std::fs::read_dir(&fonts) {
            let into = root.join("Fonts");
            let _ = std::fs::create_dir_all(&into);
            for e in rd.flatten() {
                let to = into.join(e.file_name());
                if !to.exists() {
                    let _ = link_or_copy(&e.path(), &to);
                }
            }
        }
    }
    let mut project = Project::open(&root).map_err(|e| e.to_string())?;
    let id = match pick_variation(&project, Some(comp)) {
        Ok(id) => id,
        Err(_) => project
            .add_composition(comp, size.0, size.1, "")
            .map_err(|e| e.to_string())?,
    };
    let file = project.source_of(&id).ok_or("the composition was not made")?;
    let text = std::fs::read_to_string(&file).map_err(|e| e.to_string())?;
    let text = lower::set_comp(&text, Some(size.0), Some(size.1), Some(duration), Some(fps), None)
        .map_err(|e| e.to_string())?;
    std::fs::write(&file, text).map_err(|e| e.to_string())?;
    Ok(Made {
        project: root,
        comp: id,
        comp_file: file,
        footage: made_footage,
    })
}

fn link_or_copy(from: &Path, to: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        if std::os::unix::fs::symlink(from, to).is_ok() {
            return Ok(());
        }
    }
    std::fs::copy(from, to)
        .map(|_| ())
        .map_err(|e| format!("{}: {e}", to.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(word: &str, start: f64, end: f64) -> Word {
        Word { word: word.into(), start, end }
    }

    #[test]
    fn phrases_break_at_pauses_and_full_stops() {
        let ws = vec![
            w("So", 0.0, 0.2),
            w("here", 0.25, 0.4),
            w("is", 0.45, 0.5),
            w("the", 0.55, 0.6),
            w("thing.", 0.65, 0.9),
            w("Next", 1.0, 1.2),
            w("one", 2.5, 2.7),
        ];
        let ph = phrases(&ws, 16, 0.55);
        assert_eq!(ph.len(), 3);
        assert_eq!(ph[0].2, "So here is the thing.");
        assert_eq!(ph[1].2, "Next");
        assert!((ph[2].0 - 2.5).abs() < 1e-9);
    }

    #[test]
    fn a_comp_frame_is_rewritten_in_the_head_only() {
        let src = "local e = require(\"moonsplice\")\nreturn e.comp {\n  width = 1280, height = 720, duration = 5, fps = 30,\n  scene = function(s)\n    s:rect { x = 0, width = 9 }\n  end,\n}\n";
        let out = lower::set_comp(src, Some(1920), Some(1080), Some(300.0), None, Some("#101010")).unwrap();
        assert!(out.contains("width = 1920, height = 1080, duration = 300"));
        assert!(out.contains("s:rect { x = 0, width = 9 }"));
        assert!(out.contains("background = \"#101010\""));
    }
}
