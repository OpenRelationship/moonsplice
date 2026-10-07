//! The agent host: Malleable in `mlua`, inside this binary.
//!
//! `.robot/docs/desktop.robot` §6 draws the three layers, and this file is the middle one:
//!
//! ```text
//! React  — AI SDK UI (useChat), a custom ChatTransport over a Tauri channel
//! Rust   — this file: the mlua host, the HTTP port, the tool bodies
//! Lua    — Malleable: the declaration, the turn loop, the approval gate
//! ```
//!
//! There is no local HTTP server. A turn runs on its own thread, the chunks it produces go
//! back over a channel, and the approval gate blocks that thread until the person answers —
//! which is exactly what an approval is.
//!
//! What this file does *not* do is decide anything. The loop, the budget, the gate and the
//! wire format are Lua's. Three traits are the whole of what it needs: the app, the chat
//! surface, and a transport — and the transport being a trait is what lets the test below run
//! the real harness, the real declaration and the real tool bodies with no network.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use mlua::{Lua, LuaSerdeExt, Value};
use serde::{Deserialize, Serialize};

use crate::lower::Edit;
use crate::net;

mod table;
mod tools;
mod turn;

use table::*;
pub use tools::*;
pub use turn::*;

/// Everything a tool body needs from the app. The same calls the UI makes, so a change from
/// the agent and a change from a drag go down one path.
pub trait AppBridge: Send + Sync + 'static {
    fn outline_text(&self) -> Result<String, String>;
    fn at_text(&self, t: f64) -> Result<String, String>;
    fn shows_text(&self) -> Result<String, String>;
    /// What the project holds that could go into a composition. Without this there is no way to
    /// know a clip exists: `outline_text` is what is *in* the composition, which is a different
    /// question, and a model asked to add footage answered that it could not see any.
    fn project_text(&self) -> Result<String, String>;
    fn change(&self, edits: Vec<Edit>, why: &str) -> Result<String, String>;
    /// Put one of the project's things — a clip, a picture, a sound — into the composition.
    fn place(&self, thing: &str, at: Option<f64>) -> Result<String, String>;
    /// Move a clip or a sound along the timeline, or trim one of its ends.
    fn move_clip(
        &self,
        node: &str,
        to: Option<f64>,
        trim: Option<String>,
        at: Option<f64>,
    ) -> Result<String, String>;
    fn cut_clip(&self, node: &str, at: f64) -> Result<String, String>;
    /// Close the hole after a clip, with or without taking the clip out first. The ripple.
    fn close_gap(&self, node: &str, take_out: bool) -> Result<String, String>;
    /// Pin a note to a moment. Neither in the picture nor in the mix -- a note about the edit.
    fn note(&self, at: f64, text: &str) -> Result<String, String>;
    fn restack(&self, node: &str, over: Option<String>) -> Result<String, String>;
    fn move_when(&self, node: &str, at: f64, which: Option<f64>) -> Result<String, String>;
    fn undo(&self) -> Result<String, String>;
    fn export(&self, quality: &str) -> Result<String, String>;
    fn repaint(&self, instruction: &str) -> Result<String, String>;
    /// The producer's tools -- `transcript`, `keep`, `draw`, `captions`, `frame` -- which make a
    /// piece out of footage rather than adjust one that exists. One door with the tool's name on
    /// it, because their arguments are shapes (ranges, a box, a list of props) that are clearer
    /// passed whole than spelled out as a dozen positional parameters. See `crate::headless`.
    ///
    /// The app's own window does not offer them yet, and says so rather than pretending.
    fn produce(&self, tool: &str, _args: serde_json::Value) -> Result<String, String> {
        Err(format!("{tool} is not available in this build"))
    }
}

/// An edit list as a model actually sent it, made into one this app can read.
///
/// A live model, given a schema that says "array", sent `["{\"verb\": \"set_ease\", ...}"]` --
/// each edit as a *string of JSON* rather than an object. Three calls in a row were refused and
/// the intention was lost, which is a worse outcome than reading what was plainly meant. So an
/// item that is a string of JSON is parsed; anything else is passed through and refused as before,
/// because guessing at a shape nobody wrote is how an edit lands on the wrong thing.
fn loosen(v: serde_json::Value) -> serde_json::Value {
    let serde_json::Value::Array(items) = v else {
        return v;
    };
    serde_json::Value::Array(
        items
            .into_iter()
            .map(|item| match &item {
                serde_json::Value::String(s) => serde_json::from_str(s).unwrap_or(item),
                _ => item,
            })
            .collect(),
    )
}

/// What the person is being asked, and what they said. A refusal is an answer.
#[derive(Debug, Clone, Serialize)]
pub struct Ask {
    pub tool: String,
    /// The arguments as a shape the UI can draw. Never a Lua value.
    pub args: serde_json::Value,
    pub reason: Option<String>,
    pub can_remember: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Decision {
    pub allow: bool,
    #[serde(default)]
    pub reason: Option<String>,
    /// "tool" keeps the answer for every later call of that tool.
    #[serde(default)]
    pub remember: Option<String>,
}

/// Where a turn's chunks go, and where an approval comes from.
pub trait Surface: Send + Sync + 'static {
    fn emit(&self, chunk: serde_json::Value);
    fn ask(&self, ask: Ask) -> Decision;
}

/// The model's transport. One call, no retry, no streaming: `src/provider.lua` owns those.
pub trait Transport: Send + Sync + 'static {
    fn fetch(&self, request: net::Request) -> Result<net::Response, net::PortError>;
}

pub struct Http;

impl Transport for Http {
    fn fetch(&self, request: net::Request) -> Result<net::Response, net::PortError> {
        net::fetch(request)
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Outcome {
    /// One of `answered`, `budget`, `refused`, `error`.
    pub stop: String,
    pub reason: Option<String>,
    pub answer: Option<String>,
    pub steps: u32,
    pub notes: Vec<String>,
    /// Tokens sent and received over the whole turn, as the provider counted them. Zero when the
    /// provider did not say.
    #[serde(default)]
    pub tokens_in: u64,
    #[serde(default)]
    pub tokens_out: u64,
    /// How many tools were called, refusals included.
    #[serde(default)]
    pub tool_calls: u32,
}

/// One message of the conversation so far, in the shape `turn.run` takes as `history`.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Said {
    pub role: String,
    pub text: String,
}

pub struct Paths {
    pub malleable: PathBuf,
    pub declaration: PathBuf,
    pub host: PathBuf,
}

impl Paths {
    /// Everything lives in the checkout in development and beside the binary in a release;
    /// both are found by the walk `engine::moonsplice_root` does.
    pub fn resolve(root: &Path) -> Result<Paths, String> {
        Paths::resolve_as(root, "editor")
    }

    /// The same, with another declaration from `editor/core/host/`: `editor` is the app's,
    /// `producer` is the one that builds a piece from footage (`moonsplice agent`'s default).
    pub fn resolve_as(root: &Path, declaration: &str) -> Result<Paths, String> {
        let malleable = root.join("packages/malleable");
        let declaration = if declaration.ends_with(".lua") {
            PathBuf::from(declaration)
        } else {
            root.join(format!("editor/core/host/{declaration}.lua"))
        };
        let host = root.join("editor/core/host/host.lua");
        for p in [&malleable, &declaration, &host] {
            if !p.exists() {
                return Err(format!("{} is not where the app expected it", p.display()));
            }
        }
        Ok(Paths {
            malleable,
            declaration,
            host,
        })
    }
}

#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_more;
