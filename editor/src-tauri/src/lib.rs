//! Moonsplice Studio: the Tauri host.
//!
//! Rust is the single writer (`project-sync`). Every change to a composition — a drag, an
//! agent's edit, a file changed in a text editor outside the app — arrives here, becomes a
//! span rewrite of the Lua source, and is broadcast. The UI holds no second copy: it holds a
//! hash and asks for what it needs.
//!
//! Three kinds of state, kept apart:
//!
//! | kind      | lives in                       | persisted            |
//! |-----------|--------------------------------|----------------------|
//! | comp      | the `.lua` file                | it *is* the file     |
//! | project   | `moonsplice.json`                 | yes                  |
//! | ephemeral | React (playhead, zoom, tab)    | never leaves the UI  |

pub mod agent;
pub mod engine;
pub mod perf;
pub mod queue;
pub mod frames;
pub mod headless;
pub mod lower;
pub mod net;
pub mod project;
pub mod secrets;
pub mod source;
pub mod waveform;
pub mod words;

use std::cmp::Ordering;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use tauri::ipc::Channel;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::agent::{Ask, Cancel, Decision, Said};
use crate::engine::{Engine, EngineMeta};
use crate::frames::{Frame, FrameCache, FrameKey};
use crate::lower::{Edit, EditRefusal, NodeRef};
use crate::project::{AssetKind, AssetView, Project, ProjectView};
use crate::source::SourceDoc;

/// How many megabytes of decoded frames to hold. Raw pane-size frames are about 2 MB each, so
/// 384 MB is roughly six seconds of 30 fps preview: enough that scrubbing back over a beat, or
/// playing the same phrase twice, never asks the renderer twice. `MOONSPLICE_FRAME_CACHE_MB` moves
/// it, for a machine with less to spare or a comp with more to hold.
fn frame_budget() -> usize {
    let mb = std::env::var("MOONSPLICE_FRAME_CACHE_MB")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|mb| *mb >= 16)
        .unwrap_or(384);
    mb * 1024 * 1024
}

/// One composition, open: the renderer that paints it, the source that *is* it, and the
/// outline the UI draws from.
struct Open {
    /// Shared, so a frame can be rendered without the map of open compositions held. An
    /// `Engine` serialises its own protocol; the `Arc` only lets go of the map.
    engine: std::sync::Arc<Engine>,
    doc: SourceDoc,
    outline: serde_json::Value,
    /// What the engine says each thing is and which line of the composition wrote it. This is
    /// what makes a span edit land on the thing the person pointed at.
    nodes: Vec<NodeRef>,
    /// Where each thing's file is. Filled the first time anybody needs one, emptied whenever the
    /// composition is reloaded, and never sent to the window -- see `Engine::media`.
    media: HashMap<String, PathBuf>,
    /// Why the last re-read of this composition did not take, if it did not.
    ///
    /// A save that will not load used to be silent: the engine kept the version it already had,
    /// the preview kept painting it, and nothing anywhere said that what was on the disk and
    /// what was on the screen had stopped being the same thing. Held here so the window can be
    /// told when it starts and told again when it stops.
    trouble: Option<String>,
}

/// The engine's node list, in the shape the lowering aligns against.
fn node_refs(outline: &serde_json::Value) -> Vec<NodeRef> {
    outline["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|n| {
                    Some(NodeRef {
                        id: n["id"].as_str()?.to_string(),
                        kind: n["kind"].as_str().unwrap_or("").to_string(),
                        line: n["line"].as_u64().map(|v| v as u32),
                        props: n["props"]
                            .as_object()
                            .map(|o| o.keys().cloned().collect())
                            .unwrap_or_default(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

impl Open {
    fn refresh_outline(&mut self) -> Result<(), String> {
        self.engine.reload().map_err(|e| e.to_string())?;
        let outline = self
            .engine
            .outline(self.doc.hash())
            .map_err(|e| e.to_string())?;
        self.nodes = node_refs(&outline);
        self.outline = outline;
        // A reload can have moved, added or taken away a file, so what was known about them is
        // no longer known. The shapes themselves stay -- they are keyed on the file.
        self.media.clear();
        Ok(())
    }
}

pub struct Studio {
    project: Arc<Mutex<Option<Project>>>,
    open: Mutex<HashMap<String, Open>>,
    cache: FrameCache,
    /// Where every frame's time went. Always on; see `perf.rs`.
    perf: Arc<perf::Perf>,
    /// The workers that answer frame requests, live ones first. Made in `setup`, because making
    /// a frame needs the app handle.
    frames: std::sync::OnceLock<Arc<queue::FrameQueue>>,
    serve_dir: PathBuf,
    /// The turn in flight, and the question it is waiting on.
    turn: Mutex<Option<Cancel>>,
    pending: Mutex<HashMap<u64, std::sync::mpsc::Sender<Decision>>>,
    next_ask: Mutex<u64>,
    /// What every sound the app has looked at looks like. See `waveform.rs`.
    shapes: Arc<waveform::Waveforms>,
}

impl Studio {
    fn new(serve_dir: PathBuf) -> Studio {
        Studio {
            project: Arc::new(Mutex::new(None)),
            open: Mutex::new(HashMap::new()),
            cache: FrameCache::new(frame_budget()),
            perf: Arc::new(perf::Perf::new()),
            frames: std::sync::OnceLock::new(),
            serve_dir,
            turn: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            next_ask: Mutex::new(1),
            shapes: Arc::new(waveform::Waveforms::new()),
        }
    }

}

// --------------------------------------------------------------------------------- events

/// Everything the UI is told, in one place. A name it has to spell twice is a name that
/// drifts, so they are listed here and nowhere else.
mod event {
    pub const PROJECT: &str = "project";
    pub const COMP: &str = "comp";
    pub const EXPORT: &str = "export";
    /// A composition that is open stopped reloading, or started again. See `Open::trouble`.
    pub const TROUBLE: &str = "trouble";
}

/// What the window is told about a composition that will not re-read. `why` is `None` when the
/// trouble has cleared, which is the same message rather than a second one: the window has one
/// place to put it and one rule for emptying it.
#[derive(Debug, Clone, Serialize)]
pub struct Trouble {
    pub variation: String,
    pub why: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
struct CompChanged {
    variation: String,
    hash: String,
    what: Vec<String>,
    undo: usize,
    redo: usize,
    undo_label: Option<String>,
    redo_label: Option<String>,
    outline: serde_json::Value,
}

fn broadcast(app: &AppHandle, variation: &str, open: &Open, what: Vec<String>) {
    let _ = app.emit(
        event::COMP,
        CompChanged {
            variation: variation.to_string(),
            hash: open.doc.hash().to_string(),
            what,
            undo: open.doc.undo_depth(),
            redo: open.doc.redo_depth(),
            undo_label: open.doc.undo_label().map(String::from),
            redo_label: open.doc.redo_label().map(String::from),
            outline: open.outline.clone(),
        },
    );
}

// -------------------------------------------------------------------------------- commands

#[derive(Debug, Clone, Serialize)]
pub struct Opened {
    pub variation: String,
    pub meta: EngineMeta,
    pub hash: String,
    pub outline: serde_json::Value,
}

/// Commands that wait for the renderer run off the main thread.
///
/// A synchronous Tauri command runs on the thread the window is drawn on. Every one of these
/// either starts a process, writes the file and has it re-read, or asks the renderer a question
/// -- hundreds of milliseconds at best, seconds on a long edit -- and for all of that time the
/// window is frozen and the pointer is a spinning wheel. The work is unchanged; what changes is
/// that the window keeps answering while it happens.
#[tauri::command]
async fn open_project(app: AppHandle, path: String) -> Result<ProjectView, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        open_project_now(&app, &studio, path)
    })
    .await
    .map_err(|e| format!("opening that project did not finish: {e}"))?
}

fn open_project_now(app: &AppHandle, studio: &Studio, path: String) -> Result<ProjectView, String> {
    let root = PathBuf::from(&path);
    if !root.is_dir() {
        return Err("that is not a folder".into());
    }
    let p = Project::open(&root).map_err(|e| e.to_string())?;
    let view = p.view();
    studio.open.lock().unwrap().clear();
    *studio.project.lock().unwrap() = Some(p);
    remember_path(&app, &root);
    watch(app.clone(), root);
    Ok(view)
}

/// The folder the app was last working in.
///
/// Reopening where you left off is the behaviour, and it is also what lets the app be started
/// straight into a project from a shell — `MOONSPLICE_PROJECT=… moonsplice-studio` — which is how the
/// screenshots and the manual passes are taken.
fn remembered_path(app: &AppHandle) -> Option<PathBuf> {
    if let Ok(p) = std::env::var("MOONSPLICE_PROJECT") {
        let p = PathBuf::from(p);
        if p.is_dir() {
            return Some(p);
        }
    }
    let file = app.path().app_config_dir().ok()?.join("last-project");
    let text = std::fs::read_to_string(file).ok()?;
    let p = PathBuf::from(text.trim());
    p.is_dir().then_some(p)
}

fn remember_path(app: &AppHandle, root: &Path) {
    let Ok(dir) = app.path().app_config_dir() else { return };
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(dir.join("last-project"), root.to_string_lossy().as_bytes());
}

#[tauri::command]
fn project(studio: State<Studio>) -> Result<ProjectView, String> {
    studio
        .project
        .lock()
        .unwrap()
        .as_ref()
        .map(|p| p.view())
        .ok_or_else(|| "no project is open".to_string())
}

/// Open a composition: start its renderer, read its outline, keep both.
///
/// Off the main thread, and that is not a detail. A synchronous Tauri command runs on the
/// thread the window is drawn on, so for as long as this takes -- starting a process, waiting
/// for it to read a ten minute edit and say hello -- nothing in the window moves and the
/// pointer turns into a spinning wheel. It was reported exactly that way: double-click a
/// composition, watch the rainbow wheel, and eventually it appears. The work is the same; what
/// changes is that the window keeps answering while it happens.
#[tauri::command]
async fn open_variation(app: AppHandle, variation: String) -> Result<Opened, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        open_variation_now(&app, &studio, variation)
    })
    .await
    .map_err(|e| format!("opening that composition did not finish: {e}"))?
}

fn open_variation_now(
    app: &AppHandle,
    studio: &Studio,
    variation: String,
) -> Result<Opened, String> {
    {
        let open = studio.open.lock().unwrap();
        if let Some(o) = open.get(&variation) {
            return Ok(Opened {
                variation,
                meta: o.engine.meta,
                hash: o.doc.hash().to_string(),
                outline: o.outline.clone(),
            });
        }
    }
    let (root, comp) = {
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or("no project is open")?;
        let c = p
            .source_of(&variation)
            .ok_or("that composition is not in this project")?;
        (p.root.clone(), c)
    };
    let doc = SourceDoc::open(&comp).map_err(|e| e.to_string())?;
    let dir = studio.serve_dir.join(&variation);
    let engine = Engine::start(&comp, &root, &dir).map_err(|e| e.to_string())?;
    let mut o = Open {
        engine: std::sync::Arc::new(engine),
        doc,
        outline: serde_json::Value::Null,
        nodes: Vec::new(),
        media: HashMap::new(),
        trouble: None,
    };
    let outline = o
        .engine
        .outline(o.doc.hash())
        .map_err(|e| e.to_string())?;
    o.nodes = node_refs(&outline);
    o.outline = outline;
    let opened = Opened {
        variation: variation.clone(),
        meta: o.engine.meta,
        hash: o.doc.hash().to_string(),
        outline: o.outline.clone(),
    };
    studio.open.lock().unwrap().insert(variation, o);
    let _ = app;
    Ok(opened)
}

#[tauri::command]
fn close_variation(studio: State<Studio>, variation: String) {
    if let Some(o) = studio.open.lock().unwrap().remove(&variation) {
        studio.cache.forget(o.doc.hash());
        o.engine.stop();
    }
}

/// Where preview frames come from. The URL carries the source hash, so the webview's own
/// cache is correct for free and a changed composition is a different URL.
#[tauri::command]
fn frame_base() -> String {
    if cfg!(target_os = "windows") || cfg!(target_os = "android") {
        "http://cframe.localhost/".into()
    } else {
        "cframe://localhost/".into()
    }
}

/// What playback is costing, per stage, over the last little while.
///
/// The window asks for this while it is playing, so that "the preview is choppy" can be answered
/// with which of the four steps is eating the budget rather than with a shrug. `budget_ms` is the
/// composition's own frame interval, and `why` is the one sentence worth showing a person.
#[derive(Debug, Clone, Serialize)]
struct PlaybackReport {
    #[serde(flatten)]
    stats: perf::PlaybackStats,
    /// Frames the picture is still waiting for. More than a couple means the app is asking for
    /// more than the renderer can make.
    waiting: usize,
    why: Option<String>,
}

#[tauri::command]
fn playback(app: AppHandle, budget_ms: Option<f64>, window: Option<usize>) -> PlaybackReport {
    let studio = app.state::<Studio>();
    let budget = budget_ms.unwrap_or(1000.0 / 30.0);
    PlaybackReport {
        stats: studio.perf.stats(window.unwrap_or(120)),
        waiting: studio
            .frames
            .get()
            .map(|q| q.live_waiting())
            .unwrap_or(0),
        why: studio.perf.diagnosis(budget),
    }
}

/// What the window measured: how long a frame took to arrive and paint, and the frames it could
/// not paint in time. Reported in batches so one trace covers the whole path rather than stopping
/// at the process boundary.
#[tauri::command]
fn report_playback(app: AppHandle, spans: Vec<perf::UiSpan>) {
    app.state::<Studio>().perf.record_ui(&spans);
}

/// Where an asset's own bytes come from. Same trick as `cframe`: the window is handed an id, and
/// Rust serves the file behind it, so nothing with a dot in it reaches the UI.
#[tauri::command]
fn asset_base() -> String {
    if cfg!(target_os = "windows") || cfg!(target_os = "android") {
        "http://casset.localhost/".into()
    } else {
        "casset://localhost/".into()
    }
}

/// One asset, ready to look at. This is what a double-click in the left pane asks for, the way an
/// editor loads footage into its source viewer.
#[derive(Debug, Clone, Serialize)]
pub struct Source {
    pub id: String,
    pub name: String,
    pub kind: AssetKind,
    /// The URL the window points a picture or a player at.
    pub url: String,
    /// What it is, so the window shows it, plays it, or says plainly that it cannot.
    pub media: String,
}

#[tauri::command]
fn asset_source(studio: State<Studio>, asset: String) -> Result<Source, String> {
    let guard = studio.project.lock().unwrap();
    let p = guard.as_ref().ok_or("no project is open")?;
    let path = p
        .asset_path(&asset)
        .ok_or("that is not one of this project's things")?;
    if !path.is_file() {
        return Err("that is not there any more".into());
    }
    let view = p
        .view()
        .assets
        .into_iter()
        .find(|a| a.id == asset)
        .ok_or("that is not one of this project's things")?;
    Ok(Source {
        url: format!("{}{}", asset_base(), view.id),
        id: view.id,
        name: view.name,
        kind: view.kind,
        media: project::media_type(&path).to_string(),
    })
}

/// One asset's bytes, or the slice of them a player asked for.
///
/// A webview plays video by asking for ranges, so this answers them; without that, seeking in a
/// clip does nothing and a long one may not start at all.
fn serve_asset(
    app: &AppHandle,
    path: &str,
    range: Option<&str>,
) -> Result<(u16, Vec<u8>, String, Option<(u64, u64, u64)>), String> {
    let id = urldecode(path.trim_start_matches('/'));
    if id.is_empty() {
        return Err("no asset was asked for".into());
    }
    let studio = app.state::<Studio>();

    // `sound/<variation>/<node>` is the composition's own sound rather than the project's: the
    // narration a `tts` node generated has no entry in the project at all, and a clip somebody
    // dropped in is the same file under two names. The composition already knows where each one
    // is (`Engine::media`), and that is the map used here -- so the window plays a sound by the
    // name the timeline calls it, and still never learns a path.
    if let Some((variation, node)) = sound_asked_for(&id)? {
        let file = sound_path(&studio, &variation, &node)?;
        return read_slice(&file, range);
    }

    let file = {
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or("no project is open")?;
        p.asset_path(&id).ok_or("no such thing in this project")?
    };
    read_slice(&file, range)
}

/// `sound/<variation>/<node>`, taken apart. `None` for anything that is not one.
///
/// Its own function because it is the only parsing in the scheme handler and a scheme handler is
/// the one place in this app that a stranger's string could reach: a variation with a slash in
/// it, or an empty name, must come back as a refusal rather than as a path.
pub fn sound_asked_for(id: &str) -> Result<Option<(String, String)>, String> {
    let Some(rest) = id.strip_prefix("sound/") else {
        return Ok(None);
    };
    let (variation, node) = rest.split_once('/').ok_or("no sound was asked for")?;
    if variation.is_empty() || node.is_empty() || node.contains('/') {
        return Err("no sound was asked for".into());
    }
    Ok(Some((variation.to_string(), node.to_string())))
}

/// Where one of a composition's sounds is, asking the engine once and remembering.
fn sound_path(studio: &Studio, variation: &str, node: &str) -> Result<PathBuf, String> {
    let (engine, known) = {
        let open = studio.open.lock().unwrap();
        let o = open.get(variation).ok_or("that composition is not open")?;
        (o.engine.clone(), o.media.get(node).cloned())
    };
    if let Some(p) = known {
        return Ok(p);
    }
    let media = engine.media().map_err(|e| e.to_string())?;
    let found = media.get(node).cloned();
    let mut open = studio.open.lock().unwrap();
    if let Some(o) = open.get_mut(variation) {
        o.media = media;
    }
    found.ok_or_else(|| "that is not a sound with a file behind it".into())
}

/// One file, or the slice of it a player asked for: `(status, bytes, what it is, the part)`.
pub fn read_slice(
    file: &Path,
    range: Option<&str>,
) -> Result<(u16, Vec<u8>, String, Option<(u64, u64, u64)>), String> {
    let media = project::media_type(file).to_string();
    let total = std::fs::metadata(file).map_err(|e| e.to_string())?.len();

    let Some(asked) = range.and_then(parse_range) else {
        let bytes = std::fs::read(file).map_err(|e| e.to_string())?;
        return Ok((200, bytes, media, None));
    };
    if total == 0 {
        return Ok((200, Vec::new(), media, None));
    }

    // At most this much in one answer. A player asking for "everything from here on" gets a
    // chunk and asks again, which is how a long clip starts playing without reading all of it.
    const CHUNK: u64 = 4 * 1024 * 1024;
    let start = asked.0.min(total - 1);
    let end = asked.1.unwrap_or(total - 1).min(total - 1).min(start + CHUNK - 1);
    let mut f = std::fs::File::open(file).map_err(|e| e.to_string())?;
    use std::io::{Read, Seek, SeekFrom};
    f.seek(SeekFrom::Start(start)).map_err(|e| e.to_string())?;
    let mut bytes = vec![0u8; (end - start + 1) as usize];
    f.read_exact(&mut bytes).map_err(|e| e.to_string())?;
    Ok((206, bytes, media, Some((start, end, total))))
}

/// `bytes=0-` or `bytes=1000-2000`. Anything else is no range at all.
fn parse_range(header: &str) -> Option<(u64, Option<u64>)> {
    let spec = header.trim().strip_prefix("bytes=")?;
    let (a, b) = spec.split_once('-')?;
    let start: u64 = a.trim().parse().ok()?;
    let end = match b.trim() {
        "" => None,
        other => Some(other.parse().ok()?),
    };
    Some((start, end))
}

/// What every property actually is at one instant. The inspector shows these, and the preview
/// draws its handles from them — a thing you can grab has to be where the renderer put it.
#[tauri::command]
async fn instant(
    app: AppHandle,
    variation: String,
    t: f64,
) -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        instant_now(&studio, variation, t)
    })
    .await
    .map_err(|e| format!("that did not finish: {e}"))?
}

fn instant_now(studio: &Studio, variation: String, t: f64) -> Result<serde_json::Value, String> {
    let open = studio.open.lock().unwrap();
    let o = open
        .get(&variation)
        .ok_or("that composition is not open")?;
    o.engine.at(t).map_err(|e| e.to_string())
}

/// What a sound looks like, so a lane can draw it instead of a grey bar.
///
/// The peaks come back and the path does not. The window asks by the name the composition gave
/// the sound; the app looks the file up, reads it once, and keeps the shape — which is what lets
/// a ten minute edit with seventy sounds in it draw them all without reading anything twice.
#[tauri::command]
async fn sound_shape(
    studio: State<'_, Studio>,
    variation: String,
    node: String,
) -> Result<Vec<u8>, String> {
    // The list of files is read once per composition and then only when the engine reloads,
    // because the answer changes exactly when the composition does.
    let path = sound_path(&studio, &variation, &node)?;
    // Off the async runtime: reading a sound waits on ffmpeg and on the four-at-a-time gate, and
    // seventy lanes all parked on that inside the runtime's own threads is a window that stops
    // answering anything at all.
    let shapes = studio.shapes.clone();
    tauri::async_runtime::spawn_blocking(move || shapes.of(&path).map(|p| p.as_ref().clone()))
        .await
        .map_err(|e| format!("the sound could not be read: {e}"))?
}

/// A gesture the UI made. Each one either maps to a lowering verb or is refused — there is
/// no third path, which is the whole of `project-sync`'s "no second edit path".
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "gesture", rename_all = "snake_case")]
pub enum Gesture {
    /// Dragging a thing in the preview.
    Move {
        node: String,
        x: f64,
        y: f64,
    },
    /// Typing a value in the inspector.
    SetValue {
        node: String,
        key: String,
        value: serde_json::Value,
    },
    /// Picking a curve for a movement.
    Curve {
        node: String,
        ease: String,
        #[serde(default)]
        occurrence: usize,
    },
    /// Dragging a movement's right edge.
    Lengthen {
        node: String,
        seconds: f64,
        #[serde(default)]
        occurrence: usize,
    },
    /// Dragging a spoken line, or retyping it.
    Line {
        node: String,
        index: usize,
        #[serde(default)]
        t0: Option<f64>,
        #[serde(default)]
        t1: Option<f64>,
        #[serde(default)]
        text: Option<String>,
    },
    /// Pinning a value by hand at a time.
    Pin {
        node: String,
        t: f64,
        key: String,
        value: serde_json::Value,
    },
    /// Taking a thing out, with the key a person reaches for.
    Remove { node: String },
    /// Dragging a clip or a sound along the timeline: it begins at `t` now.
    Slide { node: String, t: f64 },
    /// Dragging a clip's edge. `edge` is where the drag was: the front of it or the back.
    Trim {
        node: String,
        edge: Edge,
        t: f64,
    },
    /// The razor: cut a clip in two where the playhead is.
    Split { node: String, t: f64 },
    /// Dragging a movement's *left* edge: it begins at `t` now. Which movement, when a thing has
    /// several, is `occurrence` -- the same numbering the curve and the length take.
    MoveStart {
        node: String,
        t: f64,
        #[serde(default)]
        occurrence: usize,
    },
    /// Reordering things in the stack: `node` now paints over `over`. `None` sends it to the
    /// very back. On the timeline that is a lane dragged above or below another one.
    Restack {
        node: String,
        #[serde(default)]
        over: Option<String>,
    },
    /// Taking a thing out *and closing the hole it leaves*: everything of its own kind that
    /// came after it moves up by its length. The ripple every editor has, on the key every
    /// editor puts it on.
    TakeOutAndClose { node: String },
    /// Closing the empty stretch that follows `after`, without taking anything out. On the
    /// timeline it is the gap itself, clicked.
    CloseGap { after: String },
    /// Pinning a note to a moment. The one thing you put in a composition that is not in the
    /// picture and not in the mix.
    Mark { t: f64, text: String },
}

/// Which end of a clip a drag had hold of.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Edge {
    /// Where it starts playing from. Moving it changes when it begins *and* where in the
    /// footage it begins, which is what a person means by trimming the head off a shot.
    In,
    /// Where it stops. Only its length changes.
    Out,
}

/// What a thing with a length is: when it starts, how long it runs, and how far into its own
/// footage it begins. A clip says `from`; a sound says `at`; both say the other two.
struct Span {
    start_key: &'static str,
    start: f64,
    duration: f64,
    media_start: f64,
}

/// The clip or sound `node` is, read off the outline. `None` for anything that has no length of
/// its own -- a rectangle is on screen whenever the composition says so, and there is nothing to
/// take hold of.
fn span_of(outline: &serde_json::Value, node: &str) -> Option<Span> {
    let n = outline["nodes"]
        .as_array()?
        .iter()
        .find(|n| n["id"].as_str() == Some(node))?;
    let props = &n["props"];
    let num = |k: &str| props[k].as_f64();
    let start_key = if props.get("from").is_some() {
        "from"
    } else if props.get("at").is_some() {
        "at"
    } else {
        return None;
    };
    Some(Span {
        start_key,
        start: num(start_key).unwrap_or(0.0),
        duration: num("duration").unwrap_or(0.0),
        media_start: num("media_start").unwrap_or(0.0),
    })
}

/// One frame of the composition, or a thirtieth of a second if it does not say. The shortest a
/// clip is allowed to get: a clip of no length is a clip nobody can find again.
fn one_frame(outline: &serde_json::Value) -> f64 {
    let fps = outline["comp"]["fps"].as_f64().unwrap_or(30.0);
    if fps > 0.0 {
        1.0 / fps
    } else {
        1.0 / 30.0
    }
}

fn comp_duration(outline: &serde_json::Value) -> f64 {
    outline["comp"]["duration"].as_f64().unwrap_or(0.0)
}

/// When a thing's `occurrence`-th movement begins, as the engine measured it.
///
/// The numbering is the outline's own: every movement of that thing, across every property, in
/// the order the timeline draws them. That is what the curve and the length already take, so a
/// drag on a bar means the same movement to all three.
fn tween_start(outline: &serde_json::Value, node: &str, occurrence: usize) -> Option<f64> {
    let mut starts: Vec<f64> = Vec::new();
    for track in outline["tracks"].as_array()? {
        if track["node"].as_str() != Some(node) {
            continue;
        }
        for seg in track["segments"].as_array()? {
            if seg["kind"] == "tween" && seg["manual"] != true {
                starts.push(seg["t0"].as_f64()?);
            }
        }
    }
    starts.sort_by(|a, b| a.partial_cmp(b).unwrap());
    starts.get(occurrence).copied()
}

/// A note pinned to a moment: in the edit, in neither the picture nor the mix.
fn is_note(outline: &serde_json::Value, node: &str) -> bool {
    outline["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .any(|n| n["id"].as_str() == Some(node) && n["kind"].as_str() == Some("marker"))
        })
        .unwrap_or(false)
}

/// Sound, as the composition reports it: a kind the mix owns rather than the picture.
fn is_sound(outline: &serde_json::Value, node: &str) -> bool {
    outline["nodes"]
        .as_array()
        .and_then(|ns| ns.iter().find(|n| n["id"].as_str() == Some(node)))
        .and_then(|n| n["kind"].as_str())
        .is_some_and(|k| matches!(k, "audio" | "tts" | "sfx" | "music"))
}

/// A refusal for a thing that has no length to take hold of.
fn not_a_clip(outline: &serde_json::Value, node: &str) -> EditRefusal {
    let who = words::name_of(&words::names(outline), node);
    EditRefusal::Conflict {
        detail: format!(
            "{who} has no length of its own to drag -- it is on screen for as long as the \
             composition says, so what moves it is a movement"
        ),
    }
}

pub fn gesture_to_edits(
    g: Gesture,
    outline: &serde_json::Value,
) -> Result<Vec<Edit>, EditRefusal> {
    Ok(match g {
        Gesture::Move { node, x, y } => {
            // Dragging sets where a thing *starts*. If a movement already decides that at the
            // moment on screen, the drag would appear to do nothing — so it is refused with the
            // reason, rather than written and silently overridden at evaluation.
            for key in ["x", "y"] {
                if moving_anywhere(outline, &node, key) {
                    let who = words::name_of(&words::names(outline), &node);
                    return Err(EditRefusal::Conflict {
                        detail: format!(
                            "{who}'s position is moved by the timeline, so dragging it would \
                             not stick — change the movement instead"
                        ),
                    });
                }
            }
            vec![
                Edit::SetProp {
                    node: node.clone(),
                    key: "x".into(),
                    value: serde_json::json!(round2(x)),
                },
                Edit::SetProp {
                    node,
                    key: "y".into(),
                    value: serde_json::json!(round2(y)),
                },
            ]
        }
        Gesture::SetValue { node, key, value } => vec![Edit::SetProp { node, key, value }],
        Gesture::Curve {
            node,
            ease,
            occurrence,
        } => vec![Edit::SetEase {
            node,
            ease,
            occurrence,
        }],
        Gesture::Lengthen {
            node,
            seconds,
            occurrence,
        } => vec![Edit::SetTweenDuration {
            node,
            seconds: round2(seconds),
            occurrence,
        }],
        Gesture::Line {
            node,
            index,
            t0,
            t1,
            text,
        } => vec![Edit::SetCue {
            node,
            index,
            t0: t0.map(round2),
            t1: t1.map(round2),
            text,
        }],
        Gesture::Pin { node, t, key, value } => {
            let covered = moving_at(outline, &node, &key, t);
            vec![Edit::PinProp {
                node,
                t: round2(t),
                key,
                value,
                covered,
            }]
        }
        Gesture::Remove { node } => vec![Edit::Remove { node }],
        // Dragging a clip along the timeline. The composition's length is fixed, so a clip
        // dragged past the end stops at the end rather than lengthening the composition, and a
        // clip dragged before zero stops at zero -- the same two walls an editor puts up.
        Gesture::Slide { node, t } => {
            let Some(span) = span_of(outline, &node) else {
                return Err(not_a_clip(outline, &node));
            };
            let last = (comp_duration(outline) - span.duration).max(0.0);
            let start = t.clamp(0.0, last);
            vec![Edit::SetProp {
                node,
                key: span.start_key.into(),
                value: serde_json::json!(round2(start)),
            }]
        }
        // Trimming. The front of a clip moves two things at once: when it begins, and how far
        // into its own footage it begins -- otherwise trimming the head off a shot would play
        // the same frames later rather than starting later in the shot. The back moves one.
        Gesture::Trim { node, edge, t } => {
            let Some(span) = span_of(outline, &node) else {
                return Err(not_a_clip(outline, &node));
            };
            let frame = one_frame(outline);
            let end = span.start + span.duration;
            match edge {
                Edge::In => {
                    // Not past its own first frame, and never past its own tail.
                    let earliest = span.start - span.media_start;
                    let start = t.clamp(earliest.max(0.0), end - frame);
                    let moved = start - span.start;
                    vec![
                        Edit::SetProp {
                            node: node.clone(),
                            key: span.start_key.into(),
                            value: serde_json::json!(round2(start)),
                        },
                        Edit::SetProp {
                            node: node.clone(),
                            key: "media_start".into(),
                            value: serde_json::json!(round2((span.media_start + moved).max(0.0))),
                        },
                        Edit::SetProp {
                            node,
                            key: "duration".into(),
                            value: serde_json::json!(round2(span.duration - moved)),
                        },
                    ]
                }
                Edge::Out => {
                    let stop = t.clamp(span.start + frame, comp_duration(outline));
                    vec![Edit::SetProp {
                        node,
                        key: "duration".into(),
                        value: serde_json::json!(round2(stop - span.start)),
                    }]
                }
            }
        }
        // The razor. A clip that is cut where nothing of it is -- before it starts, after it
        // ends -- is refused with where it actually runs, because a cut that quietly did nothing
        // is the worst answer of the three.
        Gesture::Split { node, t } => {
            if span_of(outline, &node).is_none() {
                return Err(not_a_clip(outline, &node));
            }
            vec![Edit::Split {
                node,
                at: round2(t),
            }]
        }
        // When a movement begins is not a number written next to it -- it is everything before
        // it in the script added up. So the drag is a difference, and the lowering changes the
        // one thing immediately before it that holds time. What follows moves with it, because
        // that is what a script means; making a movement longer has always worked this way.
        Gesture::MoveStart {
            node,
            t,
            occurrence,
        } => {
            let Some(was) = tween_start(outline, &node, occurrence) else {
                let who = words::name_of(&words::names(outline), &node);
                return Err(EditRefusal::Conflict {
                    detail: format!("{who} has no movement there to take hold of"),
                });
            };
            vec![Edit::MoveTweenStart {
                node,
                occurrence,
                delta: round2(t.max(0.0) - was),
            }]
        }
        // What paints over what is the order the statements are written in, so reordering the
        // lanes is moving a statement. Sound has no stack -- a mix is not a picture -- so a
        // sound dragged among the lanes is refused rather than written somewhere meaningless.
        Gesture::Restack { node, over } => {
            if over.as_deref() == Some(node.as_str()) {
                return Err(EditRefusal::Conflict {
                    detail: format!(
                        "{} is already where it is; a thing cannot be put in front of itself",
                        words::name_of(&words::names(outline), &node)
                    ),
                });
            }
            for who in [Some(&node), over.as_ref()].into_iter().flatten() {
                if is_sound(outline, who) {
                    return Err(EditRefusal::Conflict {
                        detail: format!(
                            "{} is sound, and sound has no front or back -- what is louder is \
                             its loudness",
                            words::name_of(&words::names(outline), who)
                        ),
                    });
                }
            }
            vec![Edit::Restack { node, over }]
        }
        // Take it out and close the hole. Two things in one breath, and one undo: the thing
        // goes, and everything of its own kind that came after it moves up by its length.
        //
        // The order is load-bearing. Every `set_value` is written against the text as it stands
        // now, so the removal goes last -- a statement taken out first would shift every line
        // after it and the moves would be aimed at the wrong ones.
        Gesture::TakeOutAndClose { node } => {
            let Some(span) = span_of(outline, &node) else {
                return Err(not_a_clip(outline, &node));
            };
            if span.duration <= 0.0 {
                return Err(EditRefusal::Conflict {
                    detail: format!(
                        "{} has no length, so there is no hole to close",
                        words::name_of(&words::names(outline), &node)
                    ),
                });
            }
            let sound = is_sound(outline, &node);
            let mut edits = ripple(
                outline,
                span.start + span.duration - 1e-6,
                -span.duration,
                sound,
                &node,
            )?;
            edits.push(Edit::Remove { node });
            edits
        }
        // The gap itself, closed. A hole in a lane is a thing a person can see and point at, so
        // it is a thing they can click -- and what it does is exactly what taking the clip out
        // would have done, minus the taking out.
        Gesture::CloseGap { after } => {
            let Some(span) = span_of(outline, &after) else {
                return Err(not_a_clip(outline, &after));
            };
            let sound = is_sound(outline, &after);
            let ends = span.start + span.duration;
            let frame = one_frame(outline);
            let next = placed(outline)
                .into_iter()
                .find(|(id, sp)| {
                    id != &after && is_sound(outline, id) == sound && sp.start > ends + 1e-6
                })
                .map(|(_, sp)| sp.start);
            let Some(next) = next else {
                return Err(EditRefusal::Conflict {
                    detail: format!(
                        "there is nothing after {}, so there is no gap to close",
                        words::name_of(&words::names(outline), &after)
                    ),
                });
            };
            let gap = next - ends;
            if gap < frame {
                return Err(EditRefusal::Conflict {
                    detail: "there is no gap there worth closing".into(),
                });
            }
            ripple(outline, next - 1e-6, -gap, sound, "")?
        }
        // A note, pinned where you were looking. It is `place` and nothing else -- a marker is a
        // node, so putting one in, moving it, renaming it and taking it out are the four verbs
        // the app already had, and none of them had to learn a thing.
        Gesture::Mark { t, text } => {
            let said = text.trim();
            if said.is_empty() {
                return Err(EditRefusal::Conflict {
                    detail: "a note with nothing written on it is not a note".into(),
                });
            }
            vec![Edit::Place {
                kind: "marker".into(),
                fields: vec![
                    ("at".into(), lower::fmt_num(round2(t.max(0.0)))),
                    (
                        "text".into(),
                        format!("\"{}\"", lower::escape_lua(said)),
                    ),
                ],
                what: said.to_string(),
            }]
        }
    })
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// Everything in the composition that has a length, in the order it starts.
///
/// "Everything" is narrower than it sounds: a rectangle is on screen whenever the composition
/// says so and has no start of its own, so it is not here and a ripple never touches it.
fn placed(outline: &serde_json::Value) -> Vec<(String, Span)> {
    let mut out: Vec<(String, Span)> = outline["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|n| {
                    let id = n["id"].as_str()?.to_string();
                    let span = span_of(outline, &id)?;
                    Some((id, span))
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| a.1.start.partial_cmp(&b.1.start).unwrap_or(Ordering::Equal));
    out
}

/// Is anything on the timeline deciding this thing's properties over time -- a movement or a
/// value pinned at a moment?
///
/// It is the question a ripple has to ask before it moves anything. A movement is written against
/// the composition's clock, not against the clip; moving the clip and leaving the movement where
/// it is would take a fade off the shot it belongs to, quietly, which is the one thing a ripple
/// must never do.
fn timed(outline: &serde_json::Value, node: &str) -> bool {
    outline["tracks"]
        .as_array()
        .map(|tracks| {
            tracks.iter().any(|tr| {
                tr["node"].as_str() == Some(node)
                    && tr["segments"]
                        .as_array()
                        .map(|segs| !segs.is_empty())
                        .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// The edits that move everything after `from` by `delta`, or the reason nothing can.
///
/// A ripple is not a verb of its own. It is the same "set this to that" the inspector writes,
/// said of several things at once -- so it lowers through the path everything else lowers
/// through, undoes in one step, and there is still no eleventh verb.
///
/// Only one family moves: sound ripples sound, picture ripples picture. That is not a
/// simplification, it is the honest reading of what a person means. Closing a gap in narration
/// under a fixed picture is the commonest edit there is, and it would be wrong to slide the
/// pictures because a line was taken out of the voiceover.
fn ripple(
    outline: &serde_json::Value,
    from: f64,
    delta: f64,
    sound: bool,
    except: &str,
) -> Result<Vec<Edit>, EditRefusal> {
    let names = words::names(outline);
    let whole = comp_duration(outline);
    let mut edits = Vec::new();
    for (id, span) in placed(outline) {
        if id == except || is_sound(outline, &id) != sound {
            continue;
        }
        // A note stays where it was put. It is about a moment in the edit rather than about the
        // clip that happens to be under it, and "the bit at four minutes is wrong" does not stop
        // being about four minutes because something earlier got shorter. Moving it silently
        // would be a guess about what somebody meant; leaving it is not a guess at all.
        if is_note(outline, &id) {
            continue;
        }
        if span.start < from - 1e-6 {
            continue;
        }
        if timed(outline, &id) {
            return Err(EditRefusal::Conflict {
                detail: format!(
                    "{} is moved by the timeline after that point, and closing the gap would \
                     leave the movement where it is -- take it out without closing the gap, or \
                     move what moves it first",
                    words::name_of(&names, &id)
                ),
            });
        }
        let now = round2(span.start + delta);
        if now < -1e-6 {
            return Err(EditRefusal::Conflict {
                detail: format!(
                    "that would put {} before the start of the composition",
                    words::name_of(&names, &id)
                ),
            });
        }
        if whole > 0.0 && now + span.duration > whole + 1e-6 {
            return Err(EditRefusal::Conflict {
                detail: format!(
                    "there is no room: {} would run past the end of a composition {}s long",
                    words::name_of(&names, &id),
                    crate::lower::fmt_num(whole)
                ),
            });
        }
        edits.push(Edit::SetProp {
            node: id,
            key: span.start_key.into(),
            value: serde_json::json!(now.max(0.0)),
        });
    }
    Ok(edits)
}

/// Does anything move `key` on `node` at all?
fn moving_anywhere(outline: &serde_json::Value, node: &str, key: &str) -> bool {
    outline["tracks"]
        .as_array()
        .map(|tracks| {
            tracks.iter().any(|tr| {
                tr["node"].as_str() == Some(node)
                    && tr["prop"].as_str() == Some(key)
                    && tr["segments"]
                        .as_array()
                        .map(|segs| segs.iter().any(|s| !s["manual"].as_bool().unwrap_or(false)))
                        .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// Is a movement already deciding `key` on `node` at `t`? Read off the outline, which is the
/// only place that knows — and the reason `pin_prop` takes it as an argument rather than
/// guessing.
fn moving_at(outline: &serde_json::Value, node: &str, key: &str, t: f64) -> bool {
    let Some(tracks) = outline["tracks"].as_array() else {
        return false;
    };
    tracks.iter().any(|tr| {
        tr["node"].as_str() == Some(node)
            && tr["prop"].as_str() == Some(key)
            && tr["segments"]
                .as_array()
                .map(|segs| {
                    segs.iter().any(|s| {
                        let t0 = s["t0"].as_f64().unwrap_or(0.0);
                        let t1 = s["t1"].as_f64().unwrap_or(0.0);
                        t1 > t0 && t >= t0 - 1e-6 && t <= t1 + 1e-6
                    })
                })
                .unwrap_or(false)
    })
}

#[derive(Debug, Clone, Serialize)]
pub struct Refused {
    pub refused: bool,
    pub why: String,
    pub kind: EditRefusal,
}

#[tauri::command]
async fn apply_gesture(
    app: AppHandle,
    variation: String,
    gesture: Gesture,
) -> Result<serde_json::Value, Refused> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        apply_gesture_now(&app, &studio, variation, gesture)
    })
    .await
    .map_err(|e| Refused {
        refused: true,
        why: format!("that change did not finish: {e}"),
        kind: EditRefusal::NoVerb {
            gesture: "finish a change".into(),
        },
    })?
}

fn apply_gesture_now(
    app: &AppHandle,
    studio: &Studio,
    variation: String,
    gesture: Gesture,
) -> Result<serde_json::Value, Refused> {
    let mut open = studio.open.lock().unwrap();
    let o = open.get_mut(&variation).ok_or_else(|| Refused {
        refused: true,
        why: "that composition is not open".into(),
        kind: EditRefusal::NoVerb {
            gesture: "change a composition that is not open".into(),
        },
    })?;
    let names = words::names(&o.outline);
    let edits = gesture_to_edits(gesture, &o.outline).map_err(refusal(&names))?;
    apply_now(app, o, &variation, &edits).map_err(refusal(&names))
}

/// Put a thing from the project into the composition in front: a clip, a picture or a sound.
///
/// This is the gesture an editor is for, and it is the one the vocabulary could not express until
/// now — an asset could be dragged and nothing could take it. The decision about *what* a dropped
/// thing is (where it starts, what it is called) is made here, where the project is; the lowering
/// only writes the constructor.
#[tauri::command]
async fn place_asset(
    app: AppHandle,
    variation: String,
    asset: String,
    t: Option<f64>,
) -> Result<serde_json::Value, Refused> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        place_asset_now(&app, &studio, variation, asset, t)
    })
    .await
    .map_err(|e| Refused {
        refused: true,
        why: format!("putting that in did not finish: {e}"),
        kind: EditRefusal::NoVerb {
            gesture: "put that in a composition".into(),
        },
    })?
}

fn place_asset_now(
    app: &AppHandle,
    studio: &Studio,
    variation: String,
    asset: String,
    t: Option<f64>,
) -> Result<serde_json::Value, Refused> {
    let said = |why: &str| Refused {
        refused: true,
        why: why.to_string(),
        kind: EditRefusal::NoVerb {
            gesture: "put that in a composition".into(),
        },
    };
    let (rel, kind, name) = {
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or_else(|| said("no project is open"))?;
        let view = p
            .view()
            .assets
            .into_iter()
            .find(|a| a.id == asset)
            .ok_or_else(|| said("that is not one of this project's things"))?;
        let path = p
            .asset_path(&asset)
            .ok_or_else(|| said("that is not one of this project's things"))?;
        (
            path.strip_prefix(&p.root)
                .unwrap_or(&path)
                .to_string_lossy()
                .to_string(),
            view.kind,
            view.name,
        )
    };

    let edit = place_edit(&rel, kind, &name, t.unwrap_or(0.0)).map_err(|w| said(&w))?;

    let mut open = studio.open.lock().unwrap();
    let o = open
        .get_mut(&variation)
        .ok_or_else(|| said("that composition is not open"))?;
    let names = words::names(&o.outline);
    apply_now(&app, o, &variation, &[edit]).map_err(refusal(&names))
}

/// What a dropped thing becomes in the composition, or why it cannot become anything.
///
/// The decision lives here rather than in the lowering because it is about the project: a clip
/// starts where it was dropped, a picture fills the frame, a sound is heard from that moment, and
/// a typeface is not a thing you put in a composition at all.
fn place_edit(rel: &str, kind: AssetKind, name: &str, t: f64) -> Result<Edit, String> {
    let at = round2(t.max(0.0));
    let src = lower::escape_lua(rel);
    let fields: Vec<(String, String)> = match kind {
        // A clip and a picture fill the frame by default, which is what the engine does with a
        // video or an image that says nothing about its size.
        AssetKind::Footage => vec![
            ("src".into(), format!("\"{src}\"")),
            ("from".into(), lower::fmt_num(at)),
        ],
        AssetKind::Image => vec![("src".into(), format!("\"{src}\""))],
        AssetKind::Audio => vec![
            ("src".into(), format!("\"{src}\"")),
            ("at".into(), lower::fmt_num(at)),
        ],
        AssetKind::Font => {
            return Err("type is something a piece of writing is set in, not something that \
                        goes in a composition on its own"
                .into())
        }
        AssetKind::Data | AssetKind::Other => {
            return Err("there is nothing to show or hear in that one".into())
        }
    };
    Ok(Edit::Place {
        kind: match kind {
            AssetKind::Footage => "video".into(),
            AssetKind::Image => "image".into(),
            _ => "audio".into(),
        },
        fields,
        what: name.to_string(),
    })
}

/// One of the project's things, by the name the left pane shows. The agent reads those names and
/// asks in them, the same way it names a thing in a composition.
fn asset_named(p: &Project, asked: &str) -> Option<AssetView> {
    let fold = |s: &str| s.trim().to_lowercase();
    let want = fold(asked);
    let all = p.view().assets;
    if let Some(a) = all.iter().find(|a| fold(&a.name) == want || a.id == asked) {
        return Some(a.clone());
    }
    let mut hits = all.iter().filter(|a| fold(&a.name).starts_with(&want));
    match (hits.next(), hits.next()) {
        (Some(a), None) => Some(a.clone()),
        _ => None,
    }
}

#[tauri::command]
fn apply_edits(
    app: AppHandle,
    studio: State<Studio>,
    variation: String,
    edits: Vec<Edit>,
) -> Result<serde_json::Value, Refused> {
    let mut open = studio.open.lock().unwrap();
    let o = open.get_mut(&variation).ok_or_else(|| Refused {
        refused: true,
        why: "that composition is not open".into(),
        kind: EditRefusal::NoVerb {
            gesture: "change a composition that is not open".into(),
        },
    })?;
    let names = words::names(&o.outline);
    apply_now(&app, o, &variation, &edits).map_err(refusal(&names))
}

/// A refusal on its way to the corner of the window. `why` is the sentence a person reads, so
/// it goes through `say` and the names the timeline uses; `kind` keeps the structure, ids and
/// all, because that half is for the code.
fn refusal(names: &std::collections::HashMap<String, String>) -> impl Fn(EditRefusal) -> Refused + '_ {
    move |r: EditRefusal| Refused {
        refused: true,
        why: r.say(names),
        kind: r,
    }
}

/// Read the composition back after it has been written to.
fn reread(engine: &Engine, doc: &SourceDoc) -> Result<serde_json::Value, String> {
    engine.reload().map_err(|e| e.to_string())?;
    engine.outline(doc.hash()).map_err(|e| e.to_string())
}

/// Write the edits and have the engine read the result back.
///
/// The second half is the part worth naming. An edit is a write, so by the time the engine
/// refuses the composition the change is already on disk -- and a composition the app cannot
/// load is not a thing to leave a person holding. So the write is put back and the reason comes
/// out as a sentence. This is the one place both those decisions live, and it is out here rather
/// than inside the command so that it can be tested without a window.
pub fn write_and_reload(
    doc: &mut SourceDoc,
    engine: &Engine,
    edits: &[Edit],
    nodes: &[NodeRef],
    names: &HashMap<String, String>,
) -> Result<(source::Applied, serde_json::Value), EditRefusal> {
    let applied = doc.apply(edits, Some(nodes), names).map_err(|e| match e {
        source::SourceError::Refused(r) => r,
        other => EditRefusal::Conflict {
            detail: other.to_string(),
        },
    })?;
    match reread(engine, doc) {
        Ok(outline) => Ok((applied, outline)),
        Err(why) => {
            let _ = doc.undo();
            let _ = reread(engine, doc);
            Err(EditRefusal::Conflict {
                detail: unloadable(&why),
            })
        }
    }
}

/// Why a written composition could not be read back, said to the person who wrote it.
///
/// The one that happens in practice is the static duration: dragging a movement's right edge past
/// the end of the composition. `.robot/docs/design.robot` makes a composition's length fixed on purpose, so this
/// is a rule being enforced rather than a fault, and it should read like one.
fn unloadable(why: &str) -> String {
    if why.contains("duration is static") {
        return "that would run past the end of the composition, and a composition's length is \
                fixed, so nothing was changed"
            .into();
    }
    let said = trouble(why);
    if said.is_empty() {
        "that left the composition unreadable, so nothing was changed".into()
    } else {
        format!("{said} — so nothing was changed")
    }
}

fn apply_now(
    app: &AppHandle,
    o: &mut Open,
    variation: &str,
    edits: &[Edit],
) -> Result<serde_json::Value, EditRefusal> {
    let nodes = o.nodes.clone();
    let names = words::names(&o.outline);
    // The source changed, so the engine re-reads it. There is no delta to apply to a canvas:
    // a composition is a pure function of time and the preview re-seeks.
    let engine = o.engine.clone();
    let (applied, outline) = write_and_reload(&mut o.doc, &engine, edits, &nodes, &names)?;
    o.nodes = node_refs(&outline);
    o.outline = outline;
    o.media.clear();
    broadcast(app, variation, o, applied.what.clone());
    Ok(serde_json::json!({
        "hash": applied.hash,
        "what": applied.what,
        "undo": applied.undo_depth,
        "redo": applied.redo_depth,
    }))
}

#[tauri::command]
async fn undo(app: AppHandle, variation: String) -> Result<String, String> {
    step_back_or_on(app, variation, true).await
}

#[tauri::command]
async fn redo(app: AppHandle, variation: String) -> Result<String, String> {
    step_back_or_on(app, variation, false).await
}

async fn step_back_or_on(app: AppHandle, variation: String, back: bool) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        step_history(&app, &studio, variation, back)
    })
    .await
    .map_err(|e| format!("that did not finish: {e}"))?
}

fn step_history(
    app: &AppHandle,
    studio: &Studio,
    variation: String,
    back: bool,
) -> Result<String, String> {
    let mut open = studio.open.lock().unwrap();
    let o = open
        .get_mut(&variation)
        .ok_or("that composition is not open")?;
    let applied = if back { o.doc.undo() } else { o.doc.redo() }.map_err(|e| e.to_string())?;
    o.refresh_outline()?;
    broadcast(&app, &variation, o, applied.what.clone());
    Ok(applied.what.join("; "))
}

#[tauri::command]
fn add_composition(
    studio: State<Studio>,
    title: String,
    width: u32,
    height: u32,
    into: Option<String>,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.add_composition(&title, width, height, into.as_deref().unwrap_or(""))
        .map_err(|e| e.to_string())?;
    Ok(p.view())
}

/// A new folder in the project. It is a directory, so the pane and the folder say the same thing.
#[tauri::command]
fn add_folder(
    app: AppHandle,
    studio: State<Studio>,
    parent: Option<String>,
    name: String,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.add_folder(parent.as_deref().unwrap_or(""), &name)
        .map_err(|e| e.to_string())?;
    let view = p.view();
    let _ = app.emit(event::PROJECT, view.clone());
    Ok(view)
}

/// Drag a thing into a folder. The file moves with it.
#[tauri::command]
fn move_item(
    app: AppHandle,
    studio: State<Studio>,
    id: String,
    into: Option<String>,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.move_item(&id, into.as_deref().unwrap_or(""))
        .map_err(|e| e.to_string())?;
    let view = p.view();
    let _ = app.emit(event::PROJECT, view.clone());
    Ok(view)
}

#[tauri::command]
fn rename_folder(
    app: AppHandle,
    studio: State<Studio>,
    at: String,
    name: String,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.rename_folder(&at, &name).map_err(|e| e.to_string())?;
    let view = p.view();
    let _ = app.emit(event::PROJECT, view.clone());
    Ok(view)
}

#[tauri::command]
fn add_variation(
    studio: State<Studio>,
    composition: String,
    width: u32,
    height: u32,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.add_variation(&composition, width, height)
        .map_err(|e| e.to_string())?;
    Ok(p.view())
}

#[tauri::command]
fn add_assets(
    app: AppHandle,
    studio: State<Studio>,
    paths: Vec<String>,
    into: Option<String>,
) -> Result<Vec<AssetView>, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    let into = into.unwrap_or_default();
    let mut out = Vec::new();
    for path in paths {
        let from = PathBuf::from(&path);
        if !from.is_file() {
            continue;
        }
        out.push(p.add_asset(&from, &into).map_err(|e| e.to_string())?);
    }
    let _ = app.emit(event::PROJECT, p.view());
    Ok(out)
}

/// Files dropped on the window. Tauri intercepts the webview's own drag and drop, so the paths
/// arrive here rather than in the DOM — which is just as well, because a browser `File` has no
/// path and the project needs one.
#[tauri::command]
fn drop_paths(
    app: AppHandle,
    studio: State<Studio>,
    paths: Vec<String>,
    into: Option<String>,
) -> Result<Vec<AssetView>, String> {
    add_assets(app, studio, paths, into)
}

/// Everything an export needs to know before anything renders. Read under the project lock and
/// then let go of it: a render takes seconds and the window must stay live.
#[derive(Debug, Clone)]
pub struct ExportPlan {
    /// The project directory, which is also the renderer's working directory. The one export bug
    /// that reached a person was here: a composition that names its fonts relative to the
    /// checkout renders to a 262-byte stub from anywhere else.
    pub root: PathBuf,
    /// The composition, relative to the project.
    pub rel: PathBuf,
    /// Where the video lands, absolute.
    pub out: PathBuf,
    /// And relative, which is what enters the project as an asset.
    pub into: String,
    /// What to call it out loud.
    pub title: String,
}

/// What to render, or why it cannot be.
pub fn plan_export(p: &Project, variation: &str) -> Result<ExportPlan, String> {
    let comp = p
        .source_of(variation)
        .ok_or("that composition is not in this project")?;
    let title = p
        .title_of(variation)
        .ok_or("that composition is not in this project")?;
    let out = p.root.join("exports").join(format!("{variation}.mp4"));
    std::fs::create_dir_all(out.parent().unwrap()).map_err(|e| e.to_string())?;
    Ok(ExportPlan {
        rel: comp.strip_prefix(&p.root).unwrap_or(&comp).to_path_buf(),
        into: out
            .strip_prefix(&p.root)
            .unwrap_or(&out)
            .to_string_lossy()
            .to_string(),
        out,
        root: p.root.clone(),
        title,
    })
}

/// Render it. `Err` is already a sentence for a person, not a traceback.
pub fn run_export(plan: &ExportPlan, quality: &str) -> Result<(), String> {
    let engine_root = engine::moonsplice_root().ok_or("the Moonsplice engine is not next to this app")?;
    // In this process, on a thread of its own, like the preview (engine.rs): the same runtime
    // `moonsplice render` runs, with the project as its working directory.
    let result = moonsplice_engine::Session::run(
        &engine_root.join("core").join("runtime"),
        vec![
            "--render".into(),
            plan.rel.display().to_string(),
            "-o".into(),
            plan.out.display().to_string(),
        ],
        vec![
            ("MOONSPLICE_CWD".into(), plan.root.display().to_string()),
            ("MOONSPLICE_HEADLESS".into(), "1".into()),
            ("MOONSPLICE_QUALITY".into(), quality.to_string()),
        ],
    );
    match result {
        Ok((0, _)) => Ok(()),
        Ok((_, said)) => Err(trouble(&said.join("\n"))),
        Err(_) => Err("the engine did not start".into()),
    }
}

#[tauri::command]
async fn export(
    app: AppHandle,
    variation: String,
    quality: Option<String>,
) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        export_now(app.clone(), &studio, variation, quality)
    })
    .await
    .map_err(|e| format!("the render did not finish: {e}"))?
}

fn export_now(
    app: AppHandle,
    studio: &Studio,
    variation: String,
    quality: Option<String>,
) -> Result<String, String> {
    let plan = {
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or("no project is open")?;
        plan_export(p, &variation)?
    };
    let quality = quality.unwrap_or_else(|| "standard".into());
    let name = variation.clone();
    let shown = plan.title.clone();
    let title = plan.title.clone();
    let project = studio.project.clone();
    std::thread::spawn(move || {
        let _ = app.emit(
            event::EXPORT,
            serde_json::json!({ "variation": name, "state": "running", "title": shown }),
        );
        let payload = match run_export(&plan, &quality) {
            Ok(()) => {
                // `app-shell` decided that an export's result enters the project. The left pane
                // is where a person looks for a finished video, and a path they never saw is no
                // answer to "where did it go".
                let mut guard = project.lock().unwrap();
                if let Some(p) = guard.as_mut() {
                    if p.add_export(&plan.into, &shown).is_ok() {
                        let _ = app.emit(event::PROJECT, p.view());
                    }
                }
                serde_json::json!({ "variation": name, "state": "done", "title": shown })
            }
            Err(why) => serde_json::json!({
                "variation": name, "state": "failed", "title": shown, "why": why,
            }),
        };
        let _ = app.emit(event::EXPORT, payload);
    });
    Ok(title)
}

/// What went wrong, in words, out of an engine failure that is written for a programmer.
///
/// The engine's stderr ends in a LÖVE traceback, so the last line of it is a stack frame: showing
/// it broke `app-shell` scenario 5 the moment an export failed, which is exactly when a person is
/// least able to ignore it. This reads the one line that carries a reason, strips the positions
/// and paths out of it, and says something plain when there is nothing worth passing on.
fn trouble(stderr: &str) -> String {
    let reason = stderr
        .lines()
        .find_map(|l| l.trim().strip_prefix("moonsplice error:"))
        .or_else(|| {
            // Anything that is plainly a traceback: a frame, a bracketed chunk name, or the
            // heading over them, which ends in a colon and says nothing.
            stderr.lines().map(str::trim).find(|l| {
                !l.is_empty()
                    && !l.starts_with('[')
                    && !l.contains("in function")
                    && !l.ends_with(':')
                    && l.contains(' ')
            })
        })
        .unwrap_or("")
        .trim();

    // `scene.lua:43: moonsplice-scene: font not found: comps/assets/fonts/Roboto.ttf` -- the heads
    // are machinery (a chunk and a line, then the component that raised it) and the tail is often
    // a path. A head with no space in it is a name, not a sentence, so it goes; the clause in the
    // middle is the part somebody wrote for a reader.
    let mut clause = reason;
    while let Some((head, rest)) = clause.split_once(": ") {
        if head.trim().contains(' ') || rest.trim().is_empty() {
            break;
        }
        clause = rest.trim();
    }
    let clause = clause
        .rsplit_once(": ")
        .map(|(words, tail)| if looks_like_a_path(tail) { words } else { clause })
        .unwrap_or(clause)
        .trim();

    let clause: String = clause
        .split_whitespace()
        .filter(|w| !looks_like_a_path(w))
        .collect::<Vec<_>>()
        .join(" ");

    if clause.is_empty() || clause.len() > 120 {
        return "the render did not finish".into();
    }
    clause
}

/// A word a person did not choose: it has a directory in it, or an extension, or a line number.
fn looks_like_a_path(w: &str) -> bool {
    let w = w.trim_matches(|c: char| !c.is_alphanumeric());
    w.contains('/')
        || w.contains('\\')
        || w.rsplit_once('.')
            .is_some_and(|(_, ext)| (1..=5).contains(&ext.len()) && ext.chars().all(|c| c.is_ascii_alphanumeric()))
        || w.split_once(':').is_some_and(|(_, n)| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

// ----------------------------------------------------------------------------- the agent

struct Bridge {
    app: AppHandle,
    variation: String,
}

impl Bridge {
    fn with<T>(&self, f: impl FnOnce(&mut Open) -> Result<T, String>) -> Result<T, String> {
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

/// The outline, as a paragraph a model reads well: no JSON, no byte counts, one line a thing.
///
/// And no code. The engine calls things `rect4` and properties `x`; the person calls them
/// "Block 2" and "across", and so does every other surface in this app. If the model reads ids
/// it will say ids back, which is what it did -- "rect4 is the teal bar" -- to someone who
/// opened this app precisely so they would never have to see that. So it reads the same words
/// the timeline shows, and `change` takes them back (see `words::resolve`).
pub fn describe(outline: &serde_json::Value) -> String {
    let comp = &outline["comp"];
    let names = words::names(outline);
    let who = |v: &serde_json::Value| words::name_of(&names, v.as_str().unwrap_or(""));

    let mut out = vec![format!(
        "{} — {:.1}s, {}x{}, {} fps.",
        comp["title"].as_str().unwrap_or("This composition"),
        comp["duration"].as_f64().unwrap_or(0.0),
        comp["width"].as_u64().unwrap_or(0),
        comp["height"].as_u64().unwrap_or(0),
        comp["fps"].as_f64().unwrap_or(30.0),
    )];
    if let Some(nodes) = outline["nodes"].as_array() {
        if nodes.is_empty() {
            out.push("It is empty: nothing has been put in it yet.".into());
        }
        for (i, n) in nodes.iter().enumerate() {
            // Front to back, because that is the only ordering the composition has and the
            // one a person asking about layering means.
            let name = who(&n["id"]);
            let kind = words::kind(n["kind"].as_str().unwrap_or(""));
            // "Block — block" says one thing twice; the name already came from the kind.
            let what = if name.starts_with(&kind) {
                String::new()
            } else {
                format!(" — {}", kind.to_lowercase())
            };
            out.push(format!(
                "- {name}{what}, {} of {} from the back",
                i + 1,
                nodes.len()
            ));
        }
    }
    if let Some(tracks) = outline["tracks"].as_array() {
        for tr in tracks {
            let prop = words::property(tr["prop"].as_str().unwrap_or("")).to_lowercase();
            for s in tr["segments"].as_array().unwrap_or(&vec![]) {
                let t0 = s["t0"].as_f64().unwrap_or(0.0);
                let t1 = s["t1"].as_f64().unwrap_or(0.0);
                match s["kind"].as_str().unwrap_or("tween") {
                    "cue" => {}
                    _ if s["manual"].as_bool().unwrap_or(false) => out.push(format!(
                        "- {}'s {prop} was set by hand at {t0:.2}s to {}",
                        who(&tr["node"]),
                        brief(&s["to"])
                    )),
                    _ => out.push(format!(
                        "- {}'s {prop} moves from {} to {} between {t0:.2}s and {t1:.2}s{}",
                        who(&tr["node"]),
                        brief(&s["from"]),
                        brief(&s["to"]),
                        s["ease"]
                            .as_str()
                            .map(|e| format!(", {}", words::curve(e).to_lowercase()))
                            .unwrap_or_default()
                    )),
                }
            }
        }
    }
    if let Some(cues) = outline["cues"].as_array() {
        for c in cues {
            out.push(format!(
                "- {} line {}: {:.2}s–{:.2}s \"{}\"",
                who(&c["node"]),
                c["index"].as_u64().unwrap_or(0) + 1,
                c["t0"].as_f64().unwrap_or(0.0),
                c["t1"].as_f64().unwrap_or(0.0),
                c["text"].as_str().unwrap_or("")
            ));
        }
    }
    if let Some(audio) = outline["audio"].as_array() {
        for a in audio {
            out.push(format!(
                "- {} is sound, starting at {:.2}s",
                who(&a["id"]),
                a["at"].as_f64().unwrap_or(0.0),
            ));
        }
    }
    if let Some(cli) = outline["cli_only"].as_array() {
        for c in cli {
            out.push(format!(
                "- {} uses {}, which this app cannot paint; it renders from the command line only",
                who(&c["node"]),
                c["why"].as_str().unwrap_or("an escape hatch")
            ));
        }
    }
    out.join("\n")
}

pub fn describe_instant(v: &serde_json::Value) -> String {
    let names = words::names(v);
    let mut out = vec![format!("At {:.2}s:", v["t"].as_f64().unwrap_or(0.0))];
    for n in v["nodes"].as_array().unwrap_or(&vec![]) {
        let props = n["props"].as_object();
        let mut bits: Vec<String> = Vec::new();
        if let Some(p) = props {
            for key in [
                "x", "y", "w", "h", "r", "opacity", "size", "rotation", "scale", "color", "text",
            ] {
                if let Some(val) = p.get(key) {
                    bits.push(format!(
                        "{} {}",
                        words::property(key).to_lowercase(),
                        brief(val)
                    ));
                }
            }
        }
        out.push(format!(
            "- {}: {}",
            words::name_of(&names, n["id"].as_str().unwrap_or("")),
            if bits.is_empty() {
                "nothing set".into()
            } else {
                bits.join(", ")
            }
        ));
    }
    out.join("\n")
}

fn brief(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => format!("\"{s}\""),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Null => "nothing".into(),
        other => other.to_string(),
    }
}

struct ChannelSurface {
    app: AppHandle,
    channel: Channel<serde_json::Value>,
}

impl agent::Surface for ChannelSurface {
    fn emit(&self, chunk: serde_json::Value) {
        let _ = self.channel.send(chunk);
    }

    fn ask(&self, ask: Ask) -> Decision {
        let studio = self.app.state::<Studio>();
        let id = {
            let mut n = studio.next_ask.lock().unwrap();
            *n += 1;
            *n
        };
        let (tx, rx) = std::sync::mpsc::channel::<Decision>();
        studio.pending.lock().unwrap().insert(id, tx);
        let _ = self.channel.send(serde_json::json!({
            "event": "ask",
            "id": id,
            "tool": ask.tool,
            "args": ask.args,
            "reason": ask.reason,
            "can_remember": ask.can_remember,
        }));
        // No timeout: a question with a deadline is a question that answers itself.
        match rx.recv() {
            Ok(d) => d,
            Err(_) => Decision {
                allow: false,
                reason: Some("nobody answered".into()),
                remember: None,
            },
        }
    }
}

#[tauri::command]
fn answer_ask(studio: State<Studio>, id: u64, decision: Decision) -> Result<(), String> {
    let tx = studio
        .pending
        .lock()
        .unwrap()
        .remove(&id)
        .ok_or("that question has already been answered")?;
    tx.send(decision).map_err(|_| "the turn has ended".into())
}

#[tauri::command]
fn stop_turn(studio: State<Studio>) {
    if let Some(c) = studio.turn.lock().unwrap().as_ref() {
        c.stop();
    }
    // Anything waiting at the gate is refused, so the loop ends rather than hangs.
    let pending: Vec<_> = studio.pending.lock().unwrap().drain().collect();
    for (_, tx) in pending {
        let _ = tx.send(Decision {
            allow: false,
            reason: Some("the run was stopped".into()),
            remember: None,
        });
    }
}

#[tauri::command]
fn ask_agent(
    app: AppHandle,
    variation: String,
    prompt: String,
    history: Vec<Said>,
    channel: Channel<serde_json::Value>,
) -> Result<(), String> {
    let root = engine::moonsplice_root().ok_or("the Moonsplice engine is not next to this app")?;
    let paths = agent::Paths::resolve(&root)?;
    let (scheme, key) = secrets::preferred()?;
    let cancel = Cancel::default();
    {
        let studio = app.state::<Studio>();
        *studio.turn.lock().unwrap() = Some(cancel.clone());
    }
    let bridge = Arc::new(Bridge {
        app: app.clone(),
        variation,
    });
    let surface = Arc::new(ChannelSurface {
        app: app.clone(),
        channel: channel.clone(),
    });
    std::thread::spawn(move || {
        let outcome = agent::run_turn(
            agent::Turn {
                paths: &paths,
                bridge,
                surface: surface.clone(),
                transport: Arc::new(agent::Http),
                scheme,
                key: &key,
                model: None,
                budget: None,
                cancel,
            },
            &prompt,
            &history,
        );
        let payload = match outcome {
            Ok(o) => serde_json::json!({
                "event": "answer",
                "stop": o.stop,
                "reason": o.reason,
                "answer": o.answer,
                "steps": o.steps,
                "notes": o.notes,
            }),
            Err(why) => serde_json::json!({ "event": "answer", "stop": "error", "reason": why }),
        };
        let _ = channel.send(payload);
        let studio = app.state::<Studio>();
        *studio.turn.lock().unwrap() = None;
    });
    Ok(())
}

// ----------------------------------------------------------------------------- the keys

#[tauri::command]
fn set_key(name: String, value: String) -> Result<(), String> {
    secrets::set(&name, &value)
}

#[tauri::command]
fn key_is_set(name: String) -> bool {
    secrets::resolve(&name).is_some()
}

// ------------------------------------------------------------------------------ the watcher

/// A composition changed on disk. There is one representation, so this is a re-read and not a
/// merge — the third writer needs no machinery of its own.
fn watch(app: AppHandle, root: PathBuf) {
    std::thread::spawn(move || {
        use notify::Watcher;
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watcher = match notify::recommended_watcher(move |res| {
            let _ = tx.send(res);
        }) {
            Ok(w) => w,
            Err(e) => {
                log::warn!("no file watcher: {e}");
                return;
            }
        };
        if watcher
            .watch(&root, notify::RecursiveMode::Recursive)
            .is_err()
        {
            return;
        }
        while let Ok(Ok(ev)) = rx.recv() {
            let touched: Vec<PathBuf> = ev
                .paths
                .into_iter()
                .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("lua"))
                .collect();
            if touched.is_empty() {
                continue;
            }
            // Settle: an editor writes through a temp file and renames, so the first event
            // can arrive before the bytes do.
            std::thread::sleep(std::time::Duration::from_millis(80));
            let studio = app.state::<Studio>();
            let mut open = studio.open.lock().unwrap();
            let names: Vec<String> = open.keys().cloned().collect();
            for name in names {
                let Some(o) = open.get_mut(&name) else { continue };
                if !touched.iter().any(|p| same_file(p, &o.doc.path)) {
                    continue;
                }
                match o.doc.adopt_from_disk() {
                    Ok(Some(applied)) => match o.refresh_outline() {
                        Ok(()) => {
                            broadcast(&app, &name, o, applied.what.clone());
                            // It loads again. Said out loud, because the window has been showing
                            // a picture it was told not to trust and needs telling that it can.
                            if o.trouble.take().is_some() {
                                let _ = app.emit(
                                    event::TROUBLE,
                                    Trouble { variation: name.clone(), why: None },
                                );
                            }
                        }
                        Err(e) => {
                            // The engine still holds the last version that worked, and the
                            // preview goes on painting it. That is the right thing to keep
                            // showing and the wrong thing to show silently: without this, the
                            // app and the file quietly stop being the same composition.
                            let why = crate::engine::in_words(&e);
                            let why = if why.is_empty() { e.clone() } else { why };
                            log::warn!("could not re-read {name}: {e}");
                            if o.trouble.as_deref() != Some(why.as_str()) {
                                o.trouble = Some(why.clone());
                                let _ = app.emit(
                                    event::TROUBLE,
                                    Trouble { variation: name.clone(), why: Some(why) },
                                );
                            }
                        }
                    },
                    Ok(None) => {}
                    Err(e) => log::warn!("could not re-read {name}: {e}"),
                }
            }
        }
    });
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => a == b,
    }
}

// -------------------------------------------------------------------------------- the frames

/// `cframe://localhost/<variation>/<hash>/<t_ms>/<w>x<h>.raw` — and `.jpg` for anything that
/// wants a picture rather than pixels.
///
/// Every part of the key is in the path, so the webview's own cache is correct and a changed
/// composition simply asks for a different URL. `?warm=1` says nobody is looking at this frame
/// yet, which is what lets the queue put the picture first.
fn frame_wanted(path: &str, query: Option<&str>) -> Result<(FrameKey, bool), String> {
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    if parts.len() < 4 {
        return Err("a frame is asked for as <variation>/<hash>/<ms>/<w>x<h>.raw".into());
    }
    let variation = urldecode(parts[0]);
    let hash = parts[1].to_string();
    let t_ms: u32 = parts[2].parse().map_err(|_| "that is not a time")?;
    let last = parts[3];
    let raw = !last.ends_with(".jpg");
    let size = last.trim_end_matches(".jpg").trim_end_matches(".raw");
    let (sw, sh) = size.split_once('x').ok_or("that is not a size")?;
    let w: u32 = sw.parse().map_err(|_| "that is not a width")?;
    let h: u32 = sh.parse().map_err(|_| "that is not a height")?;
    let warm = query.is_some_and(|q| q.split('&').any(|kv| kv == "warm=1"));
    Ok((
        FrameKey {
            variation,
            hash,
            t_ms,
            w,
            h,
            raw,
        },
        !warm,
    ))
}

/// Every response these two schemes make is cross-origin, and has to say so.
///
/// The window is `http://localhost:1420` while it is being developed and `tauri://localhost`
/// once it is built; the frames are `cframe://localhost` and the sounds are `casset://localhost`.
/// Different scheme, different origin, every single time -- so without this header the webview
/// refuses the response before the app sees a byte of it, and `fetch` says only "Load failed".
///
/// What that looked like: 569 frames rendered, served and thrown away, a preview showing the
/// checkerboard it shows when no frame has arrived, and no sound at all -- with nothing wrong
/// anywhere in the renderer, the queue or the cache, all of which were working perfectly and
/// measurably the whole time.
///
/// `*` and not the window's own origin because the origin is not one value: it changes between
/// development and a build, and the alternative is a list of origins to keep in step with the
/// two places that already know. Nothing outside this process can reach these schemes -- they
/// are registered on this webview and resolve nowhere else -- so there is no third party for a
/// wildcard to let in.
///
/// `range` is named among the allowed headers because a `<audio>` element asks for one, and a
/// request carrying `Range` is not a simple request: it is preflighted, and a preflight with no
/// answer fails the same silent way.
fn across_the_origin(b: tauri::http::response::Builder) -> tauri::http::response::Builder {
    b.header("access-control-allow-origin", "*")
        .header("access-control-allow-methods", "GET, HEAD, OPTIONS")
        .header("access-control-allow-headers", "range")
        .header("access-control-max-age", "86400")
}

/// A raw frame with its size on the front: width then height, 32 bits each, little-endian.
///
/// Eight bytes so the window never has to be told separately how big the picture is. See the
/// note on the headers in the scheme handler for why being told separately did not work.
pub fn stamped(frame: &Frame) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + frame.bytes.len());
    out.extend_from_slice(&frame.w.to_le_bytes());
    out.extend_from_slice(&frame.h.to_le_bytes());
    out.extend_from_slice(&frame.bytes);
    out
}

/// Make one frame: ask the engine, scale it to the pane, and record what each step cost.
///
/// Called on a frame worker, never on the webview's thread. `queued` is when the request
/// arrived, so the record can separate "the renderer is slow" from "we asked for more frames
/// than it can make".
fn make_frame(
    app: &AppHandle,
    key: &FrameKey,
    live: bool,
    queued: std::time::Instant,
) -> Result<Frame, String> {
    let studio = app.state::<Studio>();
    let queue_us = queued.elapsed().as_micros() as u64;

    // Asked for twice, warmed then wanted: the second one is a cache hit and costs nothing.
    if let Some(hit) = studio.cache.get(key) {
        studio.perf.record(perf::FrameSpan {
            t_ms: key.t_ms,
            w: hit.w,
            h: hit.h,
            live,
            hit: true,
            wait_us: queue_us,
            total_us: queue_us,
            bytes: hit.bytes.len(),
            ..Default::default()
        });
        return Ok(hit);
    }

    // The engine is taken out of the map and let go of before rendering: holding it across a
    // render would serialise every command in the app behind whatever frame the preview happens
    // to want, which is the difference between a scrub that feels live and one that fights the UI.
    let engine = {
        let open = studio.open.lock().unwrap();
        open.get(&key.variation)
            .ok_or("that composition is not open")?
            .engine
            .clone()
    };
    // The size the picture will actually be shown at, which is what the renderer is asked for.
    // `fit` is the same rule this side would have applied afterwards, so nothing about what
    // arrives changes -- only how much of it had to be drawn.
    let (want, _) = frames::fit(
        engine.meta.width.max(1),
        engine.meta.height.max(1),
        key.w.max(1),
        key.h.max(1),
    );
    let (rgba, sw, sh, cost) = engine
        .frame_measured(key.t_ms as f64 / 1000.0, Some(want))
        .map_err(|e| e.to_string())?;

    let encode = std::time::Instant::now();
    let (bytes, dw, dh) = if key.raw {
        frames::scale_rgba(&rgba, sw, sh, key.w, key.h).ok_or("that frame did not scale")?
    } else {
        let (w, h) = frames::fit(sw, sh, key.w.max(1), key.h.max(1));
        (
            frames::rgba_to_jpeg(&rgba, sw, sh, key.w, key.h, 82).ok_or("that frame did not encode")?,
            w,
            h,
        )
    };
    let encode_us = encode.elapsed().as_micros() as u64;
    let bytes_len = bytes.len();
    let frame = studio.cache.put(key.clone(), bytes, dw, dh);
    studio.perf.record(perf::FrameSpan {
        t_ms: key.t_ms,
        w: dw,
        h: dh,
        live,
        hit: false,
        wait_us: queue_us + cost.wait_us,
        render_us: cost.render_us,
        read_us: cost.read_us,
        encode_us,
        total_us: queue_us + cost.wait_us + cost.render_us + cost.read_us + encode_us,
        bytes: bytes_len,
    });
    Ok(frame)
}

/// The queue, started on first use. Two workers: the engine renders one frame at a time, so the
/// second worker exists to scale and hand over one frame while the next is being rendered.
fn frame_queue(app: &AppHandle) -> Arc<queue::FrameQueue> {
    let studio = app.state::<Studio>();
    studio
        .frames
        .get_or_init(|| {
            let handle = app.clone();
            queue::FrameQueue::start(
                2,
                Arc::new(move |key: &FrameKey, live: bool, queued: std::time::Instant| {
                    make_frame(&handle, key, live, queued)
                }),
            )
        })
        .clone()
}

/// A frame, straight from the cache if it is there. The synchronous path, for tests and for the
/// export preview -- the window goes through the queue instead.
pub fn frame_now(app: &AppHandle, path: &str) -> Result<Frame, String> {
    let (key, _) = frame_wanted(path, None)?;
    let studio = app.state::<Studio>();
    if let Some(hit) = studio.cache.get(&key) {
        return Ok(hit);
    }
    make_frame(app, &key, true, std::time::Instant::now())
}

fn urldecode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

// ---------------------------------------------------------------------------------- the app

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = env_logger::try_init();
    let serve_dir = std::env::temp_dir().join(format!("moonsplice-studio-{}", std::process::id()));

    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default();
    // A development build answers questions about itself. The socket is how an agent reads the
    // DOM, runs a line of JavaScript in the window and picks up what the console said -- which
    // is the difference between knowing the preview is blank and knowing why. Never in a
    // release: the gate is the whole safety argument.
    #[cfg(debug_assertions)]
    {
        use tauri_plugin_mcp::PluginConfig;
        builder = builder.plugin(tauri_plugin_mcp::init_with_config(
            PluginConfig::new("Moonsplice Studio".to_string())
                .start_socket_server(true)
                .socket_path(std::path::PathBuf::from("/private/tmp/moonsplice-studio-mcp.sock")),
        ));
    }

    builder
        .plugin(tauri_plugin_dialog::init())
        .manage(Studio::new(serve_dir))
        // Asynchronous on purpose. A scheme handler runs on the webview's thread, so answering
        // a frame there means the window stops moving for as long as the render takes.
        .register_asynchronous_uri_scheme_protocol("cframe", |ctx, request, responder| {
            let app = ctx.app_handle().clone();
            let path = request.uri().path().to_string();
            let query = request.uri().query().map(str::to_string);
            let (key, live) = match frame_wanted(&path, query.as_deref()) {
                Ok(v) => v,
                Err(why) => {
                    responder.respond(
                        across_the_origin(tauri::http::Response::builder())
                            .status(400)
                            .header("content-type", "text/plain")
                            .body(why.into_bytes())
                            .unwrap(),
                    );
                    return;
                }
            };
            let raw = key.raw;
            frame_queue(&app).want(
                key,
                live,
                Box::new(move |made| {
                    // A warmed frame is wanted in the cache, not in the window. Sending the two
                    // megabytes of it back for nobody to look at would undo the saving it exists
                    // to make, so the answer is that it is ready, and nothing else.
                    if !live {
                        responder.respond(
                            across_the_origin(tauri::http::Response::builder())
                                .status(if made.is_ok() { 204 } else { 404 })
                                .body(Vec::new())
                                .unwrap(),
                        );
                        return;
                    }
                    let response = match made {
                        Ok(frame) => across_the_origin(tauri::http::Response::builder())
                            .header(
                                "content-type",
                                if raw { "application/octet-stream" } else { "image/jpeg" },
                            )
                            // The real size, which `fit` decided: the pane asked for a box and
                            // the frame keeps its own proportions inside it.
                            //
                            // Said twice, and that is deliberate. A raw frame carries its size
                            // in its first eight bytes, because these headers do not survive the
                            // trip: the page is one scheme and the frames are another, so every
                            // fetch is cross-origin and script may only read the headers CORS
                            // safelists. The window read `null`, refused every frame as "not
                            // whole", and showed a checkerboard for a renderer that was working.
                            // The headers stay for the `.jpg` frames, which have nowhere to put
                            // eight bytes, and for anybody reading the traffic.
                            .header("x-frame-width", frame.w.to_string())
                            .header("x-frame-height", frame.h.to_string())
                            .header(
                                "access-control-expose-headers",
                                "x-frame-width, x-frame-height",
                            )
                            // Raw frames are held by the cache on this side. Letting the webview
                            // keep copies of two-megabyte bodies as well is memory spent twice.
                            .header(
                                "cache-control",
                                if raw { "no-store" } else { "public, max-age=31536000, immutable" },
                            )
                            .body(if raw { stamped(&frame) } else { frame.bytes.to_vec() })
                            .unwrap(),
                        Err(why) => across_the_origin(tauri::http::Response::builder())
                            .status(404)
                            .header("content-type", "text/plain")
                            .body(why.into_bytes())
                            .unwrap(),
                    };
                    responder.respond(response);
                }),
            );
        })
        .register_uri_scheme_protocol("casset", |ctx, request| {
            let app = ctx.app_handle().clone();
            // The preflight an `<audio>` element makes before it asks for a range. Answered with
            // the headers and nothing else, which is all a preflight is for.
            if request.method() == tauri::http::Method::OPTIONS {
                return across_the_origin(tauri::http::Response::builder())
                    .status(204)
                    .body(Vec::new())
                    .unwrap();
            }
            let path = request.uri().path().to_string();
            let range = request
                .headers()
                .get("range")
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);
            match serve_asset(&app, &path, range.as_deref()) {
                Ok((status, bytes, media, part)) => {
                    let mut b = across_the_origin(tauri::http::Response::builder())
                        .status(status)
                        .header("content-type", media)
                        .header("accept-ranges", "bytes")
                        .header("content-length", bytes.len().to_string())
                        // A player reads these to know how long the sound is and whether it may
                        // seek. Cross-origin, script sees only the safelisted headers unless the
                        // response says otherwise, and these three are not on the safelist.
                        .header(
                            "access-control-expose-headers",
                            "content-range, content-length, accept-ranges",
                        );
                    if let Some((start, end, total)) = part {
                        b = b.header("content-range", format!("bytes {start}-{end}/{total}"));
                    }
                    b.body(bytes).unwrap()
                }
                Err(why) => across_the_origin(tauri::http::Response::builder())
                    .status(404)
                    .header("content-type", "text/plain")
                    .body(why.into_bytes())
                    .unwrap(),
            }
        })
        .setup(|app| {
            let handle = app.handle().clone();
            if let Some(root) = remembered_path(&handle) {
                if let Ok(p) = Project::open(&root) {
                    let studio = handle.state::<Studio>();
                    *studio.project.lock().unwrap() = Some(p);
                    // Including when `MOONSPLICE_PROJECT` chose it. Opening a folder is opening a
                    // folder however the app was told to; without this the next launch, with no
                    // environment set, went back to the empty state -- which is how the
                    // remembering stayed unexercised for as long as it did.
                    remember_path(&handle, &root);
                    watch(handle.clone(), root);
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            open_project,
            project,
            open_variation,
            close_variation,
            frame_base,
            playback,
            report_playback,
            asset_base,
            asset_source,
            sound_shape,
            instant,
            apply_gesture,
            apply_edits,
            place_asset,
            undo,
            redo,
            add_composition,
            add_variation,
            add_folder,
            move_item,
            rename_folder,
            add_assets,
            drop_paths,
            export,
            ask_agent,
            answer_ask,
            stop_turn,
            set_key,
            key_is_set,
        ])
        .run(tauri::generate_context!())
        .expect("Moonsplice Studio could not start");
}

#[cfg(test)]
mod tests {
    /// A player asks for ranges, and a viewer that cannot answer them shows a clip that will not
    /// seek and sometimes will not start. So the answers are checked against real bytes.
    #[test]
    fn an_asset_is_served_whole_or_in_the_slice_a_player_asked_for() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("clip.mp4");
        std::fs::write(&file, (0u8..=255).collect::<Vec<u8>>()).unwrap();

        // No range: all of it, and what it is.
        let (status, bytes, media, part) = read_slice(&file, None).unwrap();
        assert_eq!((status, media.as_str(), part), (200, "video/mp4", None));
        assert_eq!(bytes.len(), 256);

        // A range: exactly those bytes, and where they sit in the whole.
        let (status, bytes, _, part) = read_slice(&file, Some("bytes=10-13")).unwrap();
        assert_eq!(status, 206);
        assert_eq!(bytes, vec![10, 11, 12, 13]);
        assert_eq!(part, Some((10, 13, 256)));

        // "From here on" is answered to the end.
        let (_, bytes, _, part) = read_slice(&file, Some("bytes=250-")).unwrap();
        assert_eq!(bytes, vec![250, 251, 252, 253, 254, 255]);
        assert_eq!(part, Some((250, 255, 256)));

        // Past the end is clamped rather than read past.
        let (_, bytes, _, part) = read_slice(&file, Some("bytes=200-9999")).unwrap();
        assert_eq!(bytes.len(), 56);
        assert_eq!(part, Some((200, 255, 256)));

        // Nonsense is no range at all, which is a whole answer rather than an error.
        let (status, bytes, _, _) = read_slice(&file, Some("pages=2")).unwrap();
        assert_eq!((status, bytes.len()), (200, 256));
        assert_eq!(parse_range("bytes=x-y"), None);
        assert_eq!(parse_range("bytes=4-"), Some((4, None)));
    }

    use super::*;

    fn outline_with_a_movement() -> serde_json::Value {
        serde_json::json!({
            "comp": { "title": "Hero", "duration": 2.0, "width": 1280, "height": 720, "fps": 30 },
            "nodes": [{ "id": "rect2", "kind": "rect", "label": null }],
            "tracks": [{
                "node": "rect2", "prop": "w",
                "segments": [{ "kind": "tween", "t0": 0.15, "t1": 0.55, "from": 0, "to": 640,
                               "ease": "expoOut", "manual": false }]
            }],
            "cues": [], "audio": [], "cli_only": []
        })
    }

    #[test]
    fn a_drag_becomes_two_span_rewrites() {
        let edits = gesture_to_edits(
            Gesture::Move {
                node: "rect2".into(),
                x: 12.345,
                y: 20.0,
            },
            &outline_with_a_movement(),
        )
        .unwrap();
        assert_eq!(edits.len(), 2);
        match &edits[0] {
            Edit::SetProp { key, value, .. } => {
                assert_eq!(key, "x");
                assert_eq!(value, &serde_json::json!(12.35));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn dragging_a_thing_the_timeline_moves_is_refused_with_the_reason() {
        let mut o = outline_with_a_movement();
        o["tracks"][0]["prop"] = serde_json::json!("x");
        let err = gesture_to_edits(
            Gesture::Move {
                node: "rect2".into(),
                x: 10.0,
                y: 10.0,
            },
            &o,
        )
        .unwrap_err();
        assert!(err.to_string().contains("change the movement instead"));
    }

    /// The last gesture that had no verb. It has one, and it is a difference rather than a time:
    /// when a movement begins is everything before it in the script added up.
    #[test]
    fn dragging_where_a_movement_starts_moves_it_by_the_difference() {
        let o = outline_with_a_movement();
        // The movement runs 0.15..0.55. Dragged to 0.4 it starts a quarter of a second later.
        let edits = gesture_to_edits(
            Gesture::MoveStart {
                node: "rect2".into(),
                t: 0.4,
                occurrence: 0,
            },
            &o,
        )
        .unwrap();
        match &edits[..] {
            [Edit::MoveTweenStart { delta, .. }] => assert!((delta - 0.25).abs() < 1e-9),
            other => panic!("{other:?}"),
        }

        // A movement that is not there is said in words, without an id in them.
        let err = gesture_to_edits(
            Gesture::MoveStart {
                node: "rect2".into(),
                t: 1.0,
                occurrence: 9,
            },
            &o,
        )
        .unwrap_err();
        let said = err.say(&words::names(&o));
        assert!(said.contains("no movement there"), "{said}");
        assert!(!said.contains("rect2"), "an id reached a person: {said}");
    }

    /// What paints over what is a verb now. What has no front or back still is not.
    #[test]
    fn restacking_a_picture_is_a_verb_and_restacking_sound_is_not() {
        let edits = gesture_to_edits(
            Gesture::Restack {
                node: "rect2".into(),
                over: None,
            },
            &outline_with_a_movement(),
        )
        .unwrap();
        assert!(matches!(&edits[..], [Edit::Restack { over: None, .. }]));

        let with_sound = serde_json::json!({
            "comp": { "title": "Hero", "duration": 2.0, "width": 1280, "height": 720, "fps": 30 },
            "nodes": [
                { "id": "rect2", "kind": "rect", "label": null },
                { "id": "tts3", "kind": "tts", "label": "Line one" }
            ],
            "tracks": [], "cues": [], "audio": [], "cli_only": []
        });
        let err = gesture_to_edits(
            Gesture::Restack {
                node: "tts3".into(),
                over: Some("rect2".into()),
            },
            &with_sound,
        )
        .unwrap_err();
        let said = err.say(&words::names(&with_sound));
        assert!(said.contains("no front or back"), "{said}");
        assert!(!said.contains("tts3"), "an id reached a person: {said}");
    }

    #[test]
    fn a_pin_inside_a_movement_is_marked_as_covered() {
        let o = outline_with_a_movement();
        assert!(moving_at(&o, "rect2", "w", 0.3));
        assert!(!moving_at(&o, "rect2", "w", 1.5));
        assert!(!moving_at(&o, "rect2", "x", 0.3));
        let edits = gesture_to_edits(
            Gesture::Pin {
                node: "rect2".into(),
                t: 0.3,
                key: "w".into(),
                value: serde_json::json!(100),
            },
            &o,
        )
        .unwrap();
        match &edits[0] {
            Edit::PinProp { covered, .. } => assert!(*covered),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_outline_reads_as_sentences_with_no_json_in_them() {
        let text = describe(&outline_with_a_movement());
        assert!(text.contains("Hero — 2.0s, 1280x720, 30 fps."), "{text}");
        assert!(
            text.contains("Block's width moves from 0 to 640 between 0.15s and 0.55s, arriving"),
            "{text}"
        );
        assert!(!text.contains('{'));
    }

    /// What the agent reads is what it says back. It read `rect4` and told someone who opened
    /// this app to avoid code that "rect4 is the teal bar" — so nothing it reads may be code.
    #[test]
    fn nothing_the_agent_reads_about_a_composition_is_code() {
        let o = outline_with_a_movement();
        let text = describe(&o);
        for code in ["rect2", "text1", "expoOut", "'s w ", "{", "}", ".lua"] {
            assert!(!text.contains(code), "describe said `{code}`:\n{text}");
        }
        let at = describe_instant(&serde_json::json!({
            "t": 0.5,
            "nodes": [{ "id": "rect2", "kind": "rect", "props": { "x": 80, "opacity": 1 } }]
        }));
        for code in ["rect2", "opacity", "\"x\""] {
            assert!(!at.contains(code), "the instant said `{code}`:\n{at}");
        }
        eprintln!("{text}\n---\n{at}");
    }

    #[test]
    fn an_empty_composition_says_so_rather_than_listing_nothing() {
        let mut o = outline_with_a_movement();
        o["nodes"] = serde_json::json!([]);
        o["tracks"] = serde_json::json!([]);
        assert!(describe(&o).contains("It is empty"));
    }

    #[test]
    fn a_pinned_value_reads_differently_from_a_movement() {
        let mut o = outline_with_a_movement();
        o["tracks"][0]["segments"][0] = serde_json::json!({
            "kind": "pin", "t0": 1.0, "t1": 1.0, "to": 0, "manual": true
        });
        let text = describe(&o);
        assert!(text.contains("was set by hand at 1.00s"), "{text}");
        assert!(!text.contains("moves from"));
    }

    #[test]
    fn a_frame_url_is_rejected_when_it_is_not_one() {
        // No app handle here, so only the parsing is under test; it must not panic.
        assert!(frame_wanted("hero", None).is_err());
        assert!(frame_wanted("hero/abc/soon/640x360.raw", None).is_err());
        assert!(frame_wanted("hero/abc/500/640.raw", None).is_err());

        let (key, live) = frame_wanted("hero%20wide/abc/500/640x360.raw", None).expect("a frame");
        assert_eq!(key.variation, "hero wide", "a name with a space survives the url");
        assert_eq!((key.hash.as_str(), key.t_ms, key.w, key.h), ("abc", 500, 640, 360));
        assert!(key.raw, "the preview asks for pixels");
        assert!(live, "and by default somebody is looking at them");

        // `.jpg` is the same frame as a picture, and a different cache entry.
        let (pic, _) = frame_wanted("hero/abc/500/640x360.jpg", None).expect("a picture");
        assert!(!pic.raw);
        assert_ne!(pic, key);

        // Warmed ahead: same frame, and the queue is told nobody is waiting on it.
        let (same, live) = frame_wanted("hero/abc/500/640x360.raw", Some("warm=1")).expect("warm");
        assert_eq!(same, frame_wanted("hero/abc/500/640x360.raw", None).unwrap().0);
        assert!(!live);
    }

    #[test]
    fn a_name_with_a_space_survives_the_url() {
        assert_eq!(urldecode("hero%20wide"), "hero wide");
    }

    /// The real stderr of a real failed export, which put a LÖVE stack frame in front of the
    /// person exporting. Whatever else it says, it says nothing that looks like code.
    #[test]
    fn a_failed_export_says_nothing_that_looks_like_code() {
        let real = "moonsplice error: scene.lua:43: moonsplice-scene: font not found: \
comps/assets/fonts/Roboto-Regular.ttf\nstack traceback:\n\tmain.lua:497: in function 'handler'\n\
\t[love \"boot.lua\"]:352: in function <[love \"boot.lua\"]:348>\n\t[C]: in function 'assert'\n\
\t[love \"boot.lua\"]:377: in function <[love \"boot.lua\"]:344>";
        let said = trouble(real);
        assert_eq!(said, "font not found");
        for code in [".lua", "boot", "traceback", "scene.lua", "/", "[C]", ":43", "moonsplice"] {
            assert!(!said.contains(code), "{said:?} still shows {code}");
        }
    }

    #[test]
    fn an_engine_failure_with_nothing_to_say_says_so() {
        assert_eq!(trouble(""), "the render did not finish");
        assert_eq!(
            trouble("stack traceback:\n\t[C]: in function 'assert'"),
            "the render did not finish"
        );
        // A path on its own is not a sentence, and a person is not owed it.
        assert_eq!(
            trouble("moonsplice error: /Users/someone/x/comps/hero.lua:12:"),
            "the render did not finish"
        );
    }

    #[test]
    fn a_plain_engine_message_reaches_the_person_unchanged() {
        assert_eq!(
            trouble("moonsplice error: main.lua:88: out of memory"),
            "out of memory"
        );
        assert_eq!(trouble("ffmpeg is not installed"), "ffmpeg is not installed");
    }

    #[test]
    fn a_word_with_a_directory_or_an_extension_in_it_is_not_a_word_a_person_chose() {
        for code in ["comps/assets/x.ttf", "scene.lua", "main.lua:497", "hero.mp4", "C:\\x\\y"] {
            assert!(looks_like_a_path(code), "{code} should read as code");
        }
        for word in ["font", "not", "found", "memory", "finish.", "ffmpeg"] {
            assert!(!looks_like_a_path(word), "{word} should read as a word");
        }
    }
}

#[cfg(test)]
mod sounds {
    use super::sound_asked_for;

    /// The scheme handler is the one place in this app a stranger's string arrives, so what it
    /// takes apart is taken apart here rather than trusted.
    #[test]
    fn a_sound_is_asked_for_by_name_and_nothing_else_is() {
        assert_eq!(
            sound_asked_for("sound/v1/tts3").unwrap(),
            Some(("v1".into(), "tts3".into()))
        );
        // Anything that is not one of these is somebody else's business.
        assert_eq!(sound_asked_for("some-asset-id").unwrap(), None);
        assert_eq!(sound_asked_for("").unwrap(), None);
        assert_eq!(sound_asked_for("sounds/v1/tts3").unwrap(), None);
        // And these are refusals, not paths.
        for bad in ["sound/v1", "sound//tts3", "sound/v1/", "sound/v1/a/b", "sound/v1/../x"] {
            let got = sound_asked_for(bad);
            assert!(
                got.is_err() || got.as_ref().unwrap().is_none() || !bad.contains(".."),
                "{bad} came back as {got:?}"
            );
            if let Ok(Some((_, node))) = got {
                assert!(!node.contains('/'), "{bad} gave a node with a path in it");
            }
        }
    }
}

/// The eight bytes on the front of a frame, which are the only thing telling the window how big
/// the picture is.
///
/// They are written here and read in `editor/src/player.ts`, and nothing between the two
/// checks that they agree -- so both sides assert the layout against a literal. If either one
/// ever changes, one of the two tests goes red instead of the preview quietly going blank, which
/// is what happened when the size travelled in a header the window was not allowed to read.
#[cfg(test)]
mod stamp {
    use super::stamped;
    use crate::frames::Frame;

    #[test]
    fn a_frame_says_how_big_it_is_in_its_first_eight_bytes() {
        let frame = Frame {
            bytes: std::sync::Arc::new(vec![9u8; 4]),
            w: 1920,
            h: 1080,
        };
        let out = stamped(&frame);
        // 1920 = 0x780, 1080 = 0x438, little-endian, four bytes each.
        assert_eq!(&out[..8], &[0x80, 0x07, 0x00, 0x00, 0x38, 0x04, 0x00, 0x00]);
        assert_eq!(&out[8..], &[9, 9, 9, 9]);
        assert_eq!(out.len(), 8 + 4);
    }

    #[test]
    fn a_frame_of_nothing_is_still_the_right_shape() {
        let frame = Frame {
            bytes: std::sync::Arc::new(Vec::new()),
            w: 0,
            h: 0,
        };
        // Zero is what the window reads as "this is not a frame", and it refuses it rather than
        // painting a guess -- so the shape has to survive even when there is nothing in it.
        assert_eq!(stamped(&frame), vec![0u8; 8]);
    }
}
