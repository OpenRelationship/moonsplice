//! The engine: one long-lived renderer session per open composition, in this process.
//!
//! The protocol is `core/runtime/serve.lua`'s, and it is deliberately ignorant of what is on the
//! other end — a request names a time, a reply names where the bytes are. It was a child process
//! (`moonsplice serve`) talking over stdin and stdout with frames in mapped files; it is now a
//! `moonsplice_engine::Session`, the same runtime on a thread of this process, and the bytes are
//! handed over in memory (.robot/docs/engine.robot, phase 4). The protocol did not change, which is what
//! let the inside of the server change and very little here.
//!
//! One session, not one per frame. `.robot/docs/desktop.robot` §1 counts the cost of the opposite
//! choice: session load is seconds, and a scrub makes hundreds of requests.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use moonsplice_engine::{Session, SessionError};

use regex::Regex;
use serde::Serialize;

#[derive(Debug)]
pub enum EngineError {
    Spawn(String),
    Gone(String),
    Refused(String),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Spawn(m) => write!(f, "the renderer would not start: {m}"),
            EngineError::Gone(m) => write!(f, "the renderer stopped answering: {m}"),
            EngineError::Refused(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for EngineError {}

pub type EngineResult<T> = Result<T, EngineError>;

/// What the server said about the composition when it came up.
#[derive(Debug, Clone, Copy, Serialize)]
pub struct EngineMeta {
    pub width: u32,
    pub height: u32,
    pub duration: f64,
    pub fps: f64,
}

/// Microseconds spent on one frame, split where the cures differ.
#[derive(Debug, Clone, Copy, Default)]
pub struct FrameCost {
    /// Queued behind another frame in the same engine.
    pub wait_us: u64,
    /// The engine evaluating the composition and rasterising it: the whole round trip.
    pub render_us: u64,
    /// Reading the pixels back out of the ring.
    pub read_us: u64,
    /// The renderer's own account of the round trip: evaluating the composition at `t`, drawing
    /// it, and writing the frame where this side could read it. Zero from a server that does not
    /// say, which reads as "not measured" rather than "instant".
    pub evaluate_us: u64,
    pub draw_us: u64,
    pub write_us: u64,
}

enum Reply {
    Frame {
        bytes: Vec<u8>,
        w: u32,
        h: u32,
        /// What the renderer said it spent: evaluating, drawing, writing the frame out. Absent
        /// from an older server, and then zero, which reads as "it did not say".
        spent: (u64, u64, u64),
    },
    Json { text: Vec<u8> },
    Done,
}

struct Inner {
    session: Session,
    seq: u64,
}

pub struct Engine {
    inner: Mutex<Inner>,
    pub meta: EngineMeta,
    pub comp: PathBuf,
    #[allow(dead_code)]
    serve_dir: PathBuf,
}

/// The repo the app renders with. In development that is the checkout; a release resolves
/// its own bundled copy. `MOONSPLICE_ROOT` overrides both, which is what the tests use.
pub fn moonsplice_root() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("MOONSPLICE_ROOT") {
        let p = PathBuf::from(p);
        if p.join("moonsplice").is_file() {
            return Some(p);
        }
    }
    let mut starts: Vec<PathBuf> = Vec::new();
    if let Ok(cwd) = std::env::current_dir() {
        starts.push(cwd);
    }
    if let Ok(exe) = std::env::current_exe() {
        starts.push(exe);
    }
    for start in starts {
        let mut dir: Option<&Path> = Some(start.as_path());
        while let Some(d) = dir {
            if d.join("moonsplice").is_file() && d.join("core/moonsplice/init.lua").is_file() {
                return Some(d.to_path_buf());
            }
            dir = d.parent();
        }
    }
    None
}

impl Engine {
    /// Start a server on `comp`. `project_root` is the working directory the composition's
    /// relative asset paths resolve against.
    pub fn start(comp: &Path, project_root: &Path, serve_dir: &Path) -> EngineResult<Engine> {
        let root = moonsplice_root().ok_or_else(|| {
            EngineError::Spawn(
                "the Moonsplice engine is not next to this app (set MOONSPLICE_ROOT)".into(),
            )
        })?;
        std::fs::create_dir_all(serve_dir)
            .map_err(|e| EngineError::Spawn(format!("{}: {e}", serve_dir.display())))?;
        let rel = comp.strip_prefix(project_root).unwrap_or(comp);
        let session = Session::start(
            &root.join("core").join("runtime"),
            vec!["--serve".into(), rel.display().to_string()],
            vec![
                // What every relative path in the composition resolves against. The session's own,
                // not this process's working directory, which is shared by every open composition.
                ("MOONSPLICE_CWD".into(), project_root.display().to_string()),
                ("MOONSPLICE_SERVE_DIR".into(), serve_dir.display().to_string()),
                ("MOONSPLICE_HEADLESS".into(), "1".into()),
                // One thing that will not load takes itself off the air instead of taking the
                // composition with it. The app asks for this and the CLI does not: an export that
                // quietly ships a slate where footage was is a far worse failure than one that
                // stops, but an editor that will not open at all because a single file moved is no
                // use to anybody. `core/runtime/resolve.lua` has the rest of the reasoning.
                ("MOONSPLICE_OFFLINE_OK".into(), "1".into()),
            ],
        )
        .map_err(|e| EngineError::Spawn(e.to_string()))?;
        let mut inner = Inner { session, seq: 0 };
        let meta = read_ready(&mut inner).map_err(|e| match e {
            // The greeting never came, which means the composition did not load. What it said on
            // the way down is the only useful thing anybody has, so it is what the person gets.
            EngineError::Gone(_) => EngineError::Refused(why_it_would_not_open(&inner.session.said())),
            other => other,
        })?;
        Ok(Engine {
            inner: Mutex::new(inner),
            meta,
            comp: comp.to_path_buf(),
            serve_dir: serve_dir.to_path_buf(),
        })
    }

    /// What one request cost, in microseconds: how long the engine was busy with somebody
    /// else's frame, how long it took over this one, and how long the frame took to come back
    /// across the boundary. Three numbers rather than one because they have three different
    /// cures.
    fn call_measured(&self, req: serde_json::Value) -> EngineResult<(Reply, u64, u64)> {
        let queued = std::time::Instant::now();
        let mut inner = self.inner.lock().expect("engine lock");
        let waited = queued.elapsed().as_micros() as u64;
        let started = std::time::Instant::now();
        inner.seq += 1;
        let seq = inner.seq;
        let mut req = req;
        req["seq"] = serde_json::json!(seq);
        inner.session.send(&req.to_string()).map_err(gone)?;
        let reply = read_reply(&mut inner)?;
        Ok((reply, waited, started.elapsed().as_micros() as u64))
    }

    fn call(&self, req: serde_json::Value) -> EngineResult<Reply> {
        let mut inner = self.inner.lock().expect("engine lock");
        inner.seq += 1;
        let seq = inner.seq;
        let mut req = req;
        req["seq"] = serde_json::json!(seq);
        inner.session.send(&req.to_string()).map_err(gone)?;
        read_reply(&mut inner)
    }

    /// One frame, as raw premultiplied RGBA at the composition's own size.
    pub fn frame(&self, t: f64) -> EngineResult<(Vec<u8>, u32, u32)> {
        let (rgba, w, h, _) = self.frame_measured(t, None)?;
        Ok((rgba, w, h))
    }

    /// The same frame, with the three costs it took. The app serves preview frames through this
    /// so that "playback is choppy" has an answer with a number in it.
    /// `want_w` is the width the picture will be shown at. Asking for less than the composition
    /// has is what every editor calls playback resolution: the renderer draws the preview at the
    /// size of the pane instead of rasterising pixels nobody is going to see. It never upscales,
    /// so asking for more is the same as asking for nothing.
    pub fn frame_measured(
        &self,
        t: f64,
        want_w: Option<u32>,
    ) -> EngineResult<(Vec<u8>, u32, u32, FrameCost)> {
        let (reply, waited, rendered) =
            self.call_measured(serde_json::json!({ "op": "frame", "t": t, "w": want_w }))?;
        match reply {
            Reply::Frame { bytes, w, h, spent } => {
                let read = std::time::Instant::now();
                Ok((
                    bytes,
                    w,
                    h,
                    FrameCost {
                        wait_us: waited,
                        render_us: rendered,
                        read_us: read.elapsed().as_micros() as u64,
                        evaluate_us: spent.0,
                        draw_us: spent.1,
                        write_us: spent.2,
                    },
                ))
            }
            _ => Err(EngineError::Gone("expected a frame".into())),
        }
    }

    /// The composition as the UI knows it: nodes, movements, lines, audio. No Lua, no
    /// byte offsets, no filenames.
    pub fn outline(&self, source_hash: &str) -> EngineResult<serde_json::Value> {
        match self.call(serde_json::json!({ "op": "outline", "source_hash": source_hash }))? {
            Reply::Json { text } => {
                serde_json::from_slice(&text)
                    .map_err(|e| EngineError::Gone(format!("the outline did not parse: {e}")))
            }
            _ => Err(EngineError::Gone("expected an outline".into())),
        }
    }

    /// Where each thing's file is, by node. The one reply that carries paths.
    ///
    /// It stops here. The host needs them — to read a waveform off a sound, to hand bytes to a
    /// viewer — and the window must never see one, which is why this is its own call and not a
    /// field on the outline: the outline goes to the window and so cannot be allowed to grow a
    /// path by accident.
    pub fn media(&self) -> EngineResult<std::collections::HashMap<String, PathBuf>> {
        match self.call(serde_json::json!({ "op": "media" }))? {
            Reply::Json { text } => {
                serde_json::from_slice(&text)
                    .map_err(|e| EngineError::Gone(format!("the media list did not parse: {e}")))
            }
            _ => Err(EngineError::Gone("expected a media list".into())),
        }
    }

    /// What every property actually is at one instant. Values, not curves — the numbers the
    /// renderer painted with.
    pub fn at(&self, t: f64) -> EngineResult<serde_json::Value> {
        match self.call(serde_json::json!({ "op": "at", "t": t }))? {
            Reply::Json { text } => {
                serde_json::from_slice(&text)
                    .map_err(|e| EngineError::Gone(format!("the instant did not parse: {e}")))
            }
            _ => Err(EngineError::Gone("expected an instant".into())),
        }
    }

    /// Re-read the composition from disk. The single representation means this is the whole
    /// of "apply an edit to the engine".
    pub fn reload(&self) -> EngineResult<()> {
        self.call(serde_json::json!({ "op": "reload" })).map(|_| ())
    }

    pub fn stop(&self) {
        let mut inner = self.inner.lock().expect("engine lock");
        let _ = inner.session.send("{\"op\":\"quit\"}");
        inner.session.stop();
    }
}

fn gone(e: SessionError) -> EngineError {
    EngineError::Gone(e.to_string())
}

/// The next reply. Lines that are not ours never reach here: the session passes on only `CS`
/// lines, so a native helper printing a warning cannot corrupt the stream.
fn next_cs_line(inner: &mut Inner) -> EngineResult<String> {
    inner.session.recv().map_err(gone)
}

/// The bytes a reply names, taken from the session while the engine is still held, so the next
/// request cannot reuse the slot first.
fn payload(inner: &mut Inner, path: &str) -> EngineResult<Vec<u8>> {
    inner
        .session
        .take(path)
        .ok_or_else(|| EngineError::Gone(format!("no payload at {path}")))
}

/// One line of the renderer's own words, with the code taken out of it.
///
/// A Lua error is `path/to/comp.lua:59: Incorrect number of parameters`, and both halves of that
/// are code: the path is a file name, which this app never shows, and the line number is a line
/// of a language the person has not been told exists. What is left is the sentence, which is the
/// only part anybody can act on.
///
/// Shared by the two places a composition can refuse: when it will not open at all, and when it
/// was open and a save stopped it reloading. They said the same thing differently until this
/// was one function.
pub fn in_words(said: &str) -> String {
    let sentence = Regex::new(r"(?:^|\s)(?:[\w./-]+):\d+:\s*")
        .ok()
        .and_then(|re| re.find_iter(said).last().map(|m| said[m.end()..].to_string()))
        .unwrap_or_else(|| said.to_string());
    // The engine names itself in its own errors. A person editing a video did not ask which part
    // of the renderer was speaking.
    let mut sentence = sentence.trim().to_string();
    for prefix in [
        "moonsplice error:",
        "moonsplice resolve:",
        "moonsplice-decode:",
        "moonsplice-engine:",
        "moonsplice:",
    ] {
        sentence = sentence.trim().trim_start_matches(prefix).to_string();
    }
    sentence.trim().to_string()
}

/// The renderer's own words about why a composition would not open, in one line.
///
/// Its stack traceback is dropped: it names Lua files inside the engine, which is code about code
/// and no help at all to somebody who opened a video. What is kept is the line that says what
/// went wrong, without the path it happened in.
fn why_it_would_not_open(lines: &[String]) -> String {
    let first = lines
        .iter()
        .map(|l| l.trim())
        .find(|l| !l.is_empty() && !l.starts_with("stack traceback") && !l.starts_with('['))
        .unwrap_or("");
    if first.is_empty() {
        return "that composition would not open, and the renderer said nothing about why".into();
    }
    // "moonsplice error: physics_bake.lua:59: Incorrect number of parameters" -> the part after the
    // last "file:line:", which is the sentence somebody can act on.
    let sentence = in_words(first);
    let sentence = sentence.trim();
    if sentence.is_empty() {
        format!("that composition would not open: {first}")
    } else {
        format!("that composition would not open: {sentence}")
    }
}

fn read_ready(inner: &mut Inner) -> EngineResult<EngineMeta> {
    let line = next_cs_line(inner)?;
    let mut it = line.split_whitespace();
    match it.next() {
        Some("ready") => {
            let mut next = || it.next().unwrap_or("0");
            let width = next().parse().unwrap_or(0);
            let height = next().parse().unwrap_or(0);
            let duration = next().parse().unwrap_or(0.0);
            let fps = next().parse().unwrap_or(30.0);
            Ok(EngineMeta {
                width,
                height,
                duration,
                fps,
            })
        }
        Some("err") => Err(EngineError::Refused(tail(&line, 2))),
        _ => Err(EngineError::Gone(format!("unexpected greeting: {line}"))),
    }
}

fn read_reply(inner: &mut Inner) -> EngineResult<Reply> {
    let line = next_cs_line(inner)?;
    let parts: Vec<&str> = line.split_whitespace().collect();
    match parts.first().copied() {
        Some("frame") if parts.len() >= 5 => {
            let us = |i: usize| parts.get(i).and_then(|v| v.parse().ok()).unwrap_or(0);
            Ok(Reply::Frame {
                bytes: payload(inner, parts[1])?,
                w: parts[2].parse().unwrap_or(0),
                h: parts[3].parse().unwrap_or(0),
                spent: (us(5), us(6), us(7)),
            })
        }
        Some("json") if parts.len() >= 3 => Ok(Reply::Json {
            text: payload(inner, parts[1])?,
        }),
        Some("ok") => Ok(Reply::Done),
        Some("err") => Err(EngineError::Refused(tail(&line, 2))),
        _ => Err(EngineError::Gone(format!("unexpected reply: {line}"))),
    }
}

/// Everything after the first `skip` whitespace-separated words.
fn tail(line: &str, skip: usize) -> String {
    line.split_whitespace()
        .skip(skip)
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tail_keeps_the_sentence() {
        assert_eq!(tail("err 3 no node called hat", 2), "no node called hat");
    }

    #[test]
    fn the_root_is_found_from_the_working_directory() {
        // The test binary runs inside the checkout, so the walk up must find moonsplice.
        assert!(moonsplice_root().is_some(), "moonsplice root not found from tests");
    }
}
