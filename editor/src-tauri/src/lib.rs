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

// The app's commands and their bodies, by what they act on.
mod apply;
mod assets;
mod bridge;
mod connections;
mod describe;
mod edit;
mod export;
mod framing;
mod gesture;
mod gesture_edits;
mod library;
mod open;

pub use apply::*;
pub use assets::*;
use bridge::*;
pub use connections::*;
pub use describe::*;
pub use edit::*;
pub use export::*;
pub use framing::*;
pub use gesture::*;
pub use gesture_edits::*;
use library::*;
pub use open::*;

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
            reopen_remembered(app.handle());
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
            connect_asks,
            connect_list,
            connect_needs,
            connect_find,
            connect_save,
            connect_answer,
            connect_forget,
            connect_logo,
            connect_docs,
        ])
        .run(tauri::generate_context!())
        .expect("Moonsplice Studio could not start");
}

#[cfg(test)]
mod tests;
#[cfg(test)]
mod sounds;
#[cfg(test)]
mod stamp;
