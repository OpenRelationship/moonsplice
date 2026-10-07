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

/// A run in flight. Checked at the gate and inside every tool body, so a person can end a
/// turn without waiting for the model.
#[derive(Clone, Default)]
pub struct Cancel(Arc<AtomicBool>);

impl Cancel {
    pub fn stop(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn stopped(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

pub struct Turn<'a> {
    pub paths: &'a Paths,
    pub bridge: Arc<dyn AppBridge>,
    pub surface: Arc<dyn Surface>,
    pub transport: Arc<dyn Transport>,
    pub scheme: &'a str,
    pub key: &'a str,
    pub model: Option<&'a str>,
    /// Steps the turn may take, overriding the declaration's own budget. `None` keeps it.
    pub budget: Option<u32>,
    pub cancel: Cancel,
}

/// Run one turn, start to finish, on the calling thread.
pub fn run_turn(turn: Turn<'_>, prompt: &str, history: &[Said]) -> Result<Outcome, String> {
    let Turn {
        paths,
        bridge,
        surface,
        transport,
        scheme,
        key,
        model,
        budget,
        cancel,
    } = turn;

    let lua = Lua::new();
    let globals = lua.globals();

    // Malleable's own tree, and nothing else, on the path.
    let m = paths.malleable.display();
    let package: mlua::Table = globals.get("package").map_err(err)?;
    let existing: String = package.get("path").unwrap_or_default();
    package
        .set("path", format!("{m}/?.lua;{m}/src/?.lua;{existing}"))
        .map_err(err)?;

    let agent: mlua::Table = lua
        .load(r#"return require("agent")"#)
        .eval()
        .map_err(|e| format!("the agent harness would not load: {e}"))?;
    globals.set("agent", &agent).map_err(err)?;

    let wire = lua.create_table().map_err(err)?;
    wire.set("scheme", scheme).map_err(err)?;
    wire.set("key", key).map_err(err)?;
    wire.set("timeout", 120.0).map_err(err)?;
    if let Some(m) = model {
        wire.set("model", m).map_err(err)?;
    }
    if let Some(b) = budget {
        wire.set("budget", b).map_err(err)?;
    }

    // --------------------------------------------------------------------------- the ports

    wire.set(
        "fetch",
        lua.create_function(move |lua, req: Value| {
            let request: net::Request = match lua.from_value(req) {
                Ok(r) => r,
                Err(e) => {
                    return Ok((
                        Value::Nil,
                        lua.to_value(&net::PortError {
                            port: "net",
                            call: "fetch",
                            code: "malformed",
                            message: e.to_string(),
                        })?,
                    ))
                }
            };
            match transport.fetch(request) {
                Ok(res) => Ok((lua.to_value(&res)?, Value::Nil)),
                Err(e) => Ok((Value::Nil, lua.to_value(&e)?)),
            }
        })
        .map_err(err)?,
    )
    .map_err(err)?;

    let start = std::time::Instant::now();
    wire.set(
        "now",
        lua.create_function(|_, ()| {
            Ok(std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs_f64())
                .unwrap_or(0.0))
        })
        .map_err(err)?,
    )
    .map_err(err)?;
    wire.set(
        "mono",
        lua.create_function(move |_, ()| Ok(start.elapsed().as_secs_f64()))
            .map_err(err)?,
    )
    .map_err(err)?;
    wire.set(
        "log",
        lua.create_function(|_, (level, event): (String, String)| {
            log::debug!("agent[{level}] {event}");
            Ok(())
        })
        .map_err(err)?,
    )
    .map_err(err)?;

    // The gate. Blocks this thread, which is what an approval is.
    {
        let surface = surface.clone();
        let cancel = cancel.clone();
        wire.set(
            "ask",
            lua.create_function(move |lua, req: Value| {
                let d = lua.create_table()?;
                if cancel.stopped() {
                    d.set("allow", false)?;
                    d.set("reason", "the run was stopped")?;
                    return Ok(d);
                }
                #[derive(Deserialize, Default)]
                struct Raw {
                    #[serde(default)]
                    tool: String,
                    #[serde(default)]
                    args: Option<serde_json::Value>,
                    #[serde(default)]
                    reason: Option<String>,
                    #[serde(default)]
                    can_remember: bool,
                }
                let raw: Raw = lua.from_value(req).unwrap_or_default();
                let decision = surface.ask(Ask {
                    tool: raw.tool,
                    args: raw.args.unwrap_or(serde_json::Value::Null),
                    reason: raw.reason,
                    can_remember: raw.can_remember,
                });
                d.set("allow", decision.allow)?;
                if let Some(r) = decision.reason {
                    d.set("reason", r)?;
                }
                if let Some(r) = decision.remember {
                    d.set("remember", r)?;
                }
                Ok(d)
            })
            .map_err(err)?,
        )
        .map_err(err)?;
    }

    // Turn events, on their way to the chat surface. Rule 8 holds: names, counts and
    // decisions, never a prompt, a model's text or a tool's arguments.
    {
        let surface = surface.clone();
        wire.set(
            "event",
            lua.create_function(move |lua, (name, fields): (String, Value)| {
                let mut body: serde_json::Value =
                    lua.from_value(fields).unwrap_or(serde_json::Value::Null);
                if !body.is_object() {
                    body = serde_json::json!({});
                }
                body["event"] = serde_json::json!(name);
                surface.emit(body);
                Ok(())
            })
            .map_err(err)?,
        )
        .map_err(err)?;
    }

    // ---------------------------------------------------------------------------- the app

    let moonsplice = app_table(&lua, &bridge, &cancel)?;
    wire.set("moonsplice", moonsplice).map_err(err)?;

    // ------------------------------------------------------------------------------ run it

    // The declaration is loaded fresh every turn, so editing `editor.lua` takes effect
    // without restarting the app — and loading it runs nothing (malleable rule 2).
    set_declaration_dir(&lua, paths)?;
    let decl_src = std::fs::read_to_string(&paths.declaration)
        .map_err(|e| format!("{}: {e}", paths.declaration.display()))?;
    lua.load(&decl_src)
        .set_name(paths.declaration.to_string_lossy().to_string())
        .exec()
        .map_err(|e| format!("the agent declaration would not load: {e}"))?;

    let host_src = std::fs::read_to_string(&paths.host)
        .map_err(|e| format!("{}: {e}", paths.host.display()))?;
    let host: mlua::Table = lua
        .load(&host_src)
        .set_name(paths.host.to_string_lossy().to_string())
        .eval()
        .map_err(|e| format!("the agent host would not load: {e}"))?;

    let build: mlua::Function = host.get("build").map_err(err)?;
    let (run, why): (Value, Option<String>) = build
        .call((
            &wire,
            paths.declaration.to_string_lossy().to_string(),
            &agent,
        ))
        .map_err(|e| format!("the agent host would not wire up: {e}"))?;
    let run = match run {
        Value::Function(f) => f,
        _ => return Err(why.unwrap_or_else(|| "the agent host gave no reason".into())),
    };

    let hist = lua.create_table().map_err(err)?;
    for (i, said) in history.iter().enumerate() {
        let m = lua.create_table().map_err(err)?;
        m.set("role", malleable_role(&said.role)).map_err(err)?;
        m.set("text", said.text.as_str()).map_err(err)?;
        hist.set(i + 1, m).map_err(err)?;
    }

    let result: mlua::Table = run
        .call((prompt, hist))
        .map_err(|e| format!("the turn did not finish: {e}"))?;

    let notes: Vec<String> = match result.get::<Option<mlua::Table>>("notes").map_err(err)? {
        Some(t) => t
            .sequence_values::<String>()
            .filter_map(|v| v.ok())
            .collect(),
        None => Vec::new(),
    };

    let usage = match result.get::<Option<mlua::Table>>("usage").map_err(err)? {
        Some(u) => (
            u.get::<Option<u64>>("sent").ok().flatten().unwrap_or(0),
            u.get::<Option<u64>>("back").ok().flatten().unwrap_or(0),
        ),
        None => (0, 0),
    };
    Ok(Outcome {
        stop: result
            .get::<Option<String>>("stop")
            .map_err(err)?
            .unwrap_or_else(|| "error".into()),
        reason: result.get("reason").map_err(err)?,
        answer: result.get("answer").map_err(err)?,
        steps: result.get::<Option<u32>>("steps").map_err(err)?.unwrap_or(0),
        notes,
        tokens_in: usage.0,
        tokens_out: usage.1,
        tool_calls: result.get::<Option<u32>>("tool_calls").map_err(err)?.unwrap_or(0),
    })
}

/// The chat surface speaks the AI SDK's roles; `turn.run` takes `user`, `agent` or `tool`.
/// Translated in one place, so neither side has to know about the other's word.
fn malleable_role(role: &str) -> &'static str {
    match role {
        "assistant" | "agent" | "model" => "agent",
        "tool" => "tool",
        _ => "user",
    }
}

/// The app, as the table a tool body reaches it through: `c.moonsplice.outline()`,
/// `c.moonsplice.change(edits, why)` and the rest. Built the same way for a turn and for a single
/// call from the shell (`call_tool`), so the two cannot reach different apps.
fn app_table(
    lua: &Lua,
    bridge: &Arc<dyn AppBridge>,
    cancel: &Cancel,
) -> Result<mlua::Table, String> {
    let moonsplice = lua.create_table().map_err(err)?;

    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "outline",
                lua.create_function(move |_, ()| Ok(two(guard(&cancel, || bridge.outline_text()))))
                    .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "at",
                lua.create_function(move |_, t: Option<f64>| {
                    Ok(two(guard(&cancel, || bridge.at_text(t.unwrap_or(0.0)))))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "shows",
                lua.create_function(move |_, ()| Ok(two(guard(&cancel, || bridge.shows_text()))))
                    .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "change",
                lua.create_function(move |lua, (edits, why): (Value, Option<String>)| {
                    let parsed = lua
                        .from_value::<serde_json::Value>(edits)
                        .map_err(|e| e.to_string())
                        .and_then(|v| {
                            serde_json::from_value::<Vec<Edit>>(loosen(v))
                                .map_err(|e| e.to_string())
                        });
                    Ok(two(guard(&cancel, || match parsed {
                        Ok(list) if list.is_empty() => {
                            Err("no edits were given, so nothing changed".to_string())
                        }
                        Ok(list) => bridge.change(list, why.as_deref().unwrap_or("a change")),
                        Err(ref e) => Err(format!(
                            "that is not a list of edits this app can apply ({e})"
                        )),
                    })))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "project",
                lua.create_function(move |_, ()| Ok(two(guard(&cancel, || bridge.project_text()))))
                    .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "place",
                lua.create_function(move |_, (thing, at): (String, Option<f64>)| {
                    Ok(two(guard(&cancel, || bridge.place(&thing, at))))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "move_clip",
                lua.create_function(
                    move |_, (node, to, trim, at): (String, Option<f64>, Option<String>, Option<f64>)| {
                        Ok(two(guard(&cancel, || {
                            bridge.move_clip(&node, to, trim.clone(), at)
                        })))
                    },
                )
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "move_when",
                lua.create_function(move |_, (node, at, which): (String, f64, Option<f64>)| {
                    Ok(two(guard(&cancel, || bridge.move_when(&node, at, which))))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "restack",
                lua.create_function(move |_, (node, over): (String, Option<String>)| {
                    Ok(two(guard(&cancel, || bridge.restack(&node, over.clone()))))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "cut_clip",
                lua.create_function(move |_, (node, at): (String, f64)| {
                    Ok(two(guard(&cancel, || bridge.cut_clip(&node, at))))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "note",
                lua.create_function(move |_, (at, text): (f64, String)| {
                    Ok(two(guard(&cancel, || bridge.note(at, &text))))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "close_gap",
                lua.create_function(move |_, (node, take_out): (String, Option<bool>)| {
                    Ok(two(guard(&cancel, || {
                        bridge.close_gap(&node, take_out.unwrap_or(false))
                    })))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "undo",
                lua.create_function(move |_, ()| Ok(two(guard(&cancel, || bridge.undo()))))
                    .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "export",
                lua.create_function(move |_, quality: Option<String>| {
                    Ok(two(guard(&cancel, || {
                        bridge.export(quality.as_deref().unwrap_or("standard"))
                    })))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "repaint",
                lua.create_function(move |_, instruction: String| {
                    Ok(two(guard(&cancel, || bridge.repaint(&instruction))))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    {
        let bridge = bridge.clone();
        let cancel = cancel.clone();
        moonsplice
            .set(
                "produce",
                lua.create_function(move |lua, (tool, args): (String, Value)| {
                    let args: serde_json::Value =
                        lua.from_value(args).unwrap_or(serde_json::Value::Null);
                    Ok(two(guard(&cancel, || bridge.produce(&tool, args))))
                })
                .map_err(err)?,
            )
            .map_err(err)?;
    }
    Ok(moonsplice)
}

/// A Lua with Malleable on its path and the declaration loaded into it. Loading runs nothing.
fn declared(paths: &Paths) -> Result<(Lua, mlua::Table), String> {
    let lua = Lua::new();
    let globals = lua.globals();
    let m = paths.malleable.display();
    let package: mlua::Table = globals.get("package").map_err(err)?;
    let existing: String = package.get("path").unwrap_or_default();
    package
        .set("path", format!("{m}/?.lua;{m}/src/?.lua;{existing}"))
        .map_err(err)?;
    let agent: mlua::Table = lua
        .load(r#"return require("agent")"#)
        .eval()
        .map_err(|e| format!("the agent harness would not load: {e}"))?;
    globals.set("agent", &agent).map_err(err)?;
    set_declaration_dir(&lua, paths)?;
    let decl_src = std::fs::read_to_string(&paths.declaration)
        .map_err(|e| format!("{}: {e}", paths.declaration.display()))?;
    lua.load(&decl_src)
        .set_name(paths.declaration.to_string_lossy().to_string())
        .exec()
        .map_err(|e| format!("the agent declaration would not load: {e}"))?;
    drop(globals);
    Ok((lua, agent))
}

/// Where the declaration sits, as a global, so one declaration can build on another
/// (`producer.lua` starts from `editor.lua`'s tools) without guessing at a path.
fn set_declaration_dir(lua: &Lua, paths: &Paths) -> Result<(), String> {
    let dir = paths
        .declaration
        .parent()
        .map(|d| d.to_string_lossy().to_string())
        .unwrap_or_default();
    lua.globals().set("DECLARATION_DIR", dir).map_err(err)
}

/// Every tool the declaration has, as a JSON Schema a model or a person can read: name, what it
/// is for, whether it asks first, and its arguments. Read from the declaration, never copied out
/// of it, so the list cannot drift from what a turn offers.
pub fn list_tools(paths: &Paths) -> Result<serde_json::Value, String> {
    let (lua, agent) = declared(paths)?;
    let spec_fn: mlua::Function = agent.get("spec").map_err(err)?;
    let a: mlua::Table = spec_fn.call(()).map_err(err)?;
    let schema: mlua::Function = lua
        .load(r#"return function(a) local ok, m = pcall(require, "spec"); if not ok then m = require("src.spec") end; return m.schema(a) end"#)
        .eval()
        .map_err(err)?;
    let list: Value = schema.call(a.clone()).map_err(err)?;
    let list: serde_json::Value = lua.from_value(list).map_err(err)?;
    let mut out = Vec::new();
    for t in list.as_array().cloned().unwrap_or_default() {
        let mut props = serde_json::Map::new();
        let mut required = Vec::new();
        for arg in t["args"].as_array().cloned().unwrap_or_default() {
            let name = arg["name"].as_str().unwrap_or("").to_string();
            let kind = match arg["kind"].as_str().unwrap_or("string") {
                "list" => "array",
                "table" => "object",
                other => other,
            };
            let mut p = serde_json::json!({
                "type": kind,
                "description": arg["description"].as_str().unwrap_or(""),
            });
            if let Some(c) = arg.get("choices").filter(|c| c.is_array()) {
                p["enum"] = c.clone();
            }
            if arg["required"].as_bool().unwrap_or(false) {
                required.push(serde_json::json!(name));
            }
            props.insert(name, p);
        }
        out.push(serde_json::json!({
            "name": t["name"],
            "description": t["about"],
            "asks_first": t["ask"],
            "input_schema": {
                "type": "object",
                "properties": props,
                "required": required,
            },
        }));
    }
    let name: Option<String> = a.get("name").ok();
    let budget: Option<u32> = a.get("budget").ok();
    let model: Option<String> = a.get("model").ok();
    Ok(serde_json::json!({
        "agent": name,
        "model": model,
        "budget": budget,
        "tools": out,
    }))
}

/// Run one tool body against the real app, with no model and no gate: what a shell, a script or
/// another agent does when it wants exactly one thing done. The body is the declaration's own,
/// so a call from the shell and a call from a turn are the same code.
///
/// `Ok` is the tool's answer; `Err` is its refusal (or the reason it could not be called).
pub fn call_tool(
    paths: &Paths,
    bridge: Arc<dyn AppBridge>,
    tool: &str,
    args: serde_json::Value,
) -> Result<String, String> {
    let (lua, agent) = declared(paths)?;
    let spec_fn: mlua::Function = agent.get("spec").map_err(err)?;
    let a: mlua::Table = spec_fn.call(()).map_err(err)?;
    let tools: mlua::Table = a.get("tools").map_err(err)?;
    let t: Option<mlua::Table> = tools.get(tool).map_err(err)?;
    let t = t.ok_or_else(|| {
        let mut names: Vec<String> = tools
            .pairs::<String, Value>()
            .filter_map(|p| p.ok().map(|(k, _)| k))
            .collect();
        names.sort();
        format!("there is no tool called {tool:?}; there is {}", names.join(", "))
    })?;
    let run: mlua::Function = t.get("run").map_err(err)?;
    let cancel = Cancel::default();
    let moonsplice = app_table(&lua, &bridge, &cancel)?;
    let c = lua.create_table().map_err(err)?;
    let args = if args.is_null() { serde_json::json!({}) } else { args };
    c.set("args", lua.to_value(&args).map_err(err)?).map_err(err)?;
    c.set("moonsplice", moonsplice).map_err(err)?;
    c.set("note", lua.create_function(|_, _: Value| Ok(())).map_err(err)?)
        .map_err(err)?;
    let (out, why): (Value, Value) = run.call(c).map_err(|e| format!("{tool} failed: {e}"))?;
    match (out, why) {
        (Value::Nil, Value::Nil) => Err(format!("{tool} gave no answer")),
        (Value::Nil, w) => Err(w.to_string().unwrap_or_else(|_| format!("{w:?}"))),
        (Value::String(o), _) => Ok(o.to_string_lossy().to_string()),
        (o, _) => {
            let v: serde_json::Value = lua.from_value(o).map_err(err)?;
            Ok(v.to_string())
        }
    }
}

/// Run a tool body unless the person stopped the turn. A stop is a refusal, so the model
/// reads it and ends rather than being cut off mid-thought.
fn guard(cancel: &Cancel, f: impl FnOnce() -> Result<String, String>) -> Result<String, String> {
    if cancel.stopped() {
        return Err("the person stopped the run".into());
    }
    f()
}

/// `value | nil, message` — the one convention every port in Malleable follows.
fn two(r: Result<String, String>) -> (Option<String>, Option<String>) {
    match r {
        Ok(v) => (Some(v), None),
        Err(e) => (None, Some(e)),
    }
}

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct FakeApp {
        changed: Mutex<Vec<Vec<Edit>>>,
        undone: Mutex<u32>,
        placed: Mutex<Vec<(String, Option<f64>)>>,
        moved: Mutex<Vec<(String, Option<f64>, Option<String>, Option<f64>)>>,
        cut: Mutex<Vec<(String, f64)>>,
    }

    impl FakeApp {
        fn new() -> Arc<FakeApp> {
            Arc::new(FakeApp {
                changed: Mutex::new(Vec::new()),
                undone: Mutex::new(0),
                placed: Mutex::new(Vec::new()),
                moved: Mutex::new(Vec::new()),
                cut: Mutex::new(Vec::new()),
            })
        }
    }

    /// A live model sent every edit as a string of JSON. Three refusals later it gave up, and
    /// the person got nothing — so the boundary reads what was plainly meant.
    #[test]
    fn an_edit_sent_as_a_string_of_json_is_still_an_edit() {
        let sent = serde_json::json!([
            "{\"verb\": \"set_ease\", \"node\": \"Block 2\", \"ease\": \"Arriving\"}",
            { "verb": "set_prop", "node": "text1", "key": "x", "value": 8 }
        ]);
        let list: Vec<Edit> = serde_json::from_value(loosen(sent)).expect("both shapes read");
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].node(), "Block 2");
        assert_eq!(list[1].node(), "text1");

        // Anything that is not an edit is still refused rather than guessed at.
        let nonsense = serde_json::json!(["set_ease:Block 2:Arriving"]);
        assert!(serde_json::from_value::<Vec<Edit>>(loosen(nonsense)).is_err());
    }

    impl AppBridge for FakeApp {
        fn outline_text(&self) -> Result<String, String> {
            Ok("1 thing, 2s long.\n- text1 (text) — Hello".into())
        }
        fn at_text(&self, t: f64) -> Result<String, String> {
            Ok(format!("at {t}s: text1 is fully visible"))
        }
        fn shows_text(&self) -> Result<String, String> {
            Ok("holds(in_third(text1, left), 0, 2)".into())
        }
        fn project_text(&self) -> Result<String, String> {
            Ok("Earth night — footage".into())
        }
        fn change(&self, edits: Vec<Edit>, why: &str) -> Result<String, String> {
            if edits.iter().any(|e| e.node() == "ghost") {
                return Err("there is nothing called \"ghost\" in this composition".into());
            }
            let n = edits.len();
            self.changed.lock().unwrap().push(edits);
            Ok(format!("changed {n} thing(s): {why}"))
        }
        fn place(&self, thing: &str, at: Option<f64>) -> Result<String, String> {
            if thing == "nothing like that" {
                return Err("there is nothing called \"nothing like that\" in this project".into());
            }
            self.placed.lock().unwrap().push((thing.to_string(), at));
            Ok(format!("put {thing} in"))
        }
        fn move_clip(
            &self,
            node: &str,
            to: Option<f64>,
            trim: Option<String>,
            at: Option<f64>,
        ) -> Result<String, String> {
            self.moved
                .lock()
                .unwrap()
                .push((node.to_string(), to, trim.clone(), at));
            Ok(match trim {
                Some(edge) => format!("trimmed the {edge} of {node}"),
                None => format!("moved {node}"),
            })
        }
        fn cut_clip(&self, node: &str, at: f64) -> Result<String, String> {
            self.cut.lock().unwrap().push((node.to_string(), at));
            Ok(format!("cut {node} in two"))
        }
        fn note(&self, at: f64, text: &str) -> Result<String, String> {
            Ok(format!("pinned \"{text}\" at {at}s"))
        }
        fn close_gap(&self, node: &str, take_out: bool) -> Result<String, String> {
            Ok(if take_out {
                format!("took {node} out and closed the gap")
            } else {
                format!("closed the gap after {node}")
            })
        }
        fn move_when(&self, node: &str, at: f64, _which: Option<f64>) -> Result<String, String> {
            Ok(format!("{node} now starts at {at}s"))
        }
        fn restack(&self, node: &str, over: Option<String>) -> Result<String, String> {
            Ok(match over {
                Some(o) => format!("put {node} in front of {o}"),
                None => format!("sent {node} to the back"),
            })
        }
        fn undo(&self) -> Result<String, String> {
            *self.undone.lock().unwrap() += 1;
            Ok("put it back".into())
        }
        fn export(&self, q: &str) -> Result<String, String> {
            Ok(format!("rendered at {q}"))
        }
        fn repaint(&self, i: &str) -> Result<String, String> {
            Ok(format!("new footage: {i} — the composition is unchanged"))
        }
    }

    struct Recorder {
        chunks: Mutex<Vec<serde_json::Value>>,
        asked: Mutex<Vec<Ask>>,
        answer: bool,
    }

    impl Recorder {
        fn new(answer: bool) -> Arc<Recorder> {
            Arc::new(Recorder {
                chunks: Mutex::new(Vec::new()),
                asked: Mutex::new(Vec::new()),
                answer,
            })
        }
        fn events(&self) -> Vec<String> {
            self.chunks
                .lock()
                .unwrap()
                .iter()
                .map(|c| c["event"].as_str().unwrap_or("?").to_string())
                .collect()
        }
    }

    impl Surface for Recorder {
        fn emit(&self, chunk: serde_json::Value) {
            self.chunks.lock().unwrap().push(chunk);
        }
        fn ask(&self, ask: Ask) -> Decision {
            self.asked.lock().unwrap().push(ask);
            Decision {
                allow: self.answer,
                reason: None,
                remember: None,
            }
        }
    }

    /// A model that says exactly what a test tells it to, over the real chat-completions
    /// wire format. One reply per call, in order.
    struct Scripted {
        replies: Mutex<std::collections::VecDeque<serde_json::Value>>,
        seen: Mutex<Vec<serde_json::Value>>,
    }

    impl Scripted {
        fn new(replies: Vec<serde_json::Value>) -> Arc<Scripted> {
            Arc::new(Scripted {
                replies: Mutex::new(replies.into()),
                seen: Mutex::new(Vec::new()),
            })
        }
    }

    impl Transport for Scripted {
        fn fetch(&self, request: net::Request) -> Result<net::Response, net::PortError> {
            if let Some(body) = &request.body {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
                    self.seen.lock().unwrap().push(v);
                }
            }
            let next = self.replies.lock().unwrap().pop_front();
            match next {
                Some(v) => Ok(net::Response {
                    status: 200,
                    headers: Default::default(),
                    body: v.to_string(),
                }),
                None => Ok(net::Response {
                    status: 200,
                    headers: Default::default(),
                    body: reply_text("the script ran out").to_string(),
                }),
            }
        }
    }

    fn reply_calls(calls: &[(&str, serde_json::Value)]) -> serde_json::Value {
        let tool_calls: Vec<serde_json::Value> = calls
            .iter()
            .enumerate()
            .map(|(i, (name, args))| {
                serde_json::json!({
                    "id": format!("call_{i}"),
                    "type": "function",
                    "function": { "name": name, "arguments": args.to_string() }
                })
            })
            .collect();
        serde_json::json!({
            "id": "cmpl",
            "choices": [{
                "index": 0,
                "finish_reason": "tool_calls",
                "message": { "role": "assistant", "content": serde_json::Value::Null, "tool_calls": tool_calls }
            }]
        })
    }

    fn reply_text(text: &str) -> serde_json::Value {
        serde_json::json!({
            "id": "cmpl",
            "choices": [{
                "index": 0,
                "finish_reason": "stop",
                "message": { "role": "assistant", "content": text }
            }]
        })
    }

    fn paths() -> Paths {
        let root = crate::engine::moonsplice_root().expect("the checkout");
        Paths::resolve(&root).expect("the agent's files")
    }

    fn run(
        replies: Vec<serde_json::Value>,
        app: Arc<FakeApp>,
        rec: Arc<Recorder>,
        prompt: &str,
    ) -> Result<Outcome, String> {
        let p = paths();
        run_turn(
            Turn {
                paths: &p,
                bridge: app,
                surface: rec,
                transport: Scripted::new(replies),
                scheme: "openrouter",
                key: "sk-test",
                model: None,
                budget: None,
                cancel: Cancel::default(),
            },
            prompt,
            &[],
        )
    }

    #[test]
    fn a_whole_turn_runs_with_no_network_and_no_local_server() {
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        let out = run(
            vec![
                reply_calls(&[("holds", serde_json::json!({}))]),
                reply_text("There is one thing in it: a caption that says Hello."),
            ],
            app,
            rec.clone(),
            "what is in this composition",
        )
        .expect("the turn ran");
        assert_eq!(out.stop, "answered");
        assert!(out.answer.unwrap().contains("caption"));
        let events = rec.events();
        assert!(events.contains(&"start".to_string()));
        assert!(events.contains(&"call".to_string()));
        assert!(events.contains(&"result".to_string()));
        assert!(events.contains(&"stop".to_string()));
        assert!(rec.asked.lock().unwrap().is_empty(), "reading asks nobody");
    }

    #[test]
    fn a_change_is_put_to_the_person_before_the_body_runs() {
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        let out = run(
            vec![
                reply_calls(&[(
                    "change",
                    serde_json::json!({
                        "edits": [{"verb": "set_prop", "node": "text1", "key": "opacity", "value": 1}],
                        "why": "made the caption visible"
                    }),
                )]),
                reply_text("The caption shows now."),
            ],
            app.clone(),
            rec.clone(),
            "make the caption visible",
        )
        .unwrap();
        assert_eq!(out.stop, "answered");
        let asked = rec.asked.lock().unwrap();
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].tool, "change");
        assert_eq!(app.changed.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_refusal_is_a_result_the_model_reads_and_nothing_is_written() {
        let app = FakeApp::new();
        let rec = Recorder::new(false); // the person says no
        let out = run(
            vec![
                reply_calls(&[(
                    "change",
                    serde_json::json!({
                        "edits": [{"verb": "set_prop", "node": "text1", "key": "x", "value": 0}],
                        "why": "moved the caption"
                    }),
                )]),
                reply_text("You turned that down, so nothing moved."),
            ],
            app.clone(),
            rec.clone(),
            "put the caption on the left",
        )
        .unwrap();
        assert_eq!(out.stop, "answered", "a refusal is not an error");
        assert!(app.changed.lock().unwrap().is_empty(), "the body never ran");
        assert_eq!(rec.asked.lock().unwrap().len(), 1);
    }

    #[test]
    fn twelve_edits_for_one_intention_reach_the_app_as_one_call() {
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        let edits: Vec<serde_json::Value> = (0..12)
            .map(|i| serde_json::json!({"verb": "set_prop", "node": "text1", "key": "x", "value": i}))
            .collect();
        run(
            vec![
                reply_calls(&[(
                    "change",
                    serde_json::json!({ "edits": edits, "why": "lined everything up" }),
                )]),
                reply_text("Lined up."),
            ],
            app.clone(),
            rec,
            "line it all up",
        )
        .unwrap();
        let changed = app.changed.lock().unwrap();
        assert_eq!(changed.len(), 1, "one call, so one undo step");
        assert_eq!(changed[0].len(), 12);
    }

    #[test]
    fn an_edit_the_composition_cannot_express_comes_back_as_a_sentence() {
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        let out = run(
            vec![
                reply_calls(&[(
                    "change",
                    serde_json::json!({
                        "edits": [{"verb": "set_prop", "node": "ghost", "key": "x", "value": 0}],
                        "why": "moved a ghost"
                    }),
                )]),
                reply_text("There is nothing by that name."),
            ],
            app.clone(),
            rec,
            "move the ghost",
        )
        .unwrap();
        assert_eq!(out.stop, "answered");
        assert!(app.changed.lock().unwrap().is_empty());
    }

    #[test]
    fn the_pixel_model_never_reaches_the_composition() {
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        let out = run(
            vec![
                reply_calls(&[(
                    "repaint",
                    serde_json::json!({ "instruction": "remove the sign" }),
                )]),
                reply_text("That is new footage; the composition is unchanged."),
            ],
            app.clone(),
            rec,
            "take the sign out of the render",
        )
        .unwrap();
        assert_eq!(out.stop, "answered");
        assert!(app.changed.lock().unwrap().is_empty());
    }

    #[test]
    fn the_loop_always_ends_and_says_why() {
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        // A model that only ever asks to read: the budget is what stops it.
        let replies: Vec<serde_json::Value> = (0..40)
            .map(|_| reply_calls(&[("holds", serde_json::json!({}))]))
            .collect();
        let out = run(replies, app, rec, "keep going").unwrap();
        assert_eq!(out.stop, "budget");
        assert!(out.reason.unwrap_or_default().len() > 0);
    }

    #[test]
    fn stopping_a_turn_refuses_every_tool_from_then_on() {
        let p = paths();
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        let cancel = Cancel::default();
        cancel.stop();
        let out = run_turn(
            Turn {
                paths: &p,
                bridge: app.clone(),
                surface: rec,
                transport: Scripted::new(vec![
                    reply_calls(&[("holds", serde_json::json!({}))]),
                    reply_text("I was stopped."),
                ]),
                scheme: "openrouter",
                key: "sk-test",
                model: None,
                budget: None,
                cancel,
            },
            "look at it",
            &[],
        )
        .unwrap();
        assert_eq!(out.stop, "answered");
        assert!(app.changed.lock().unwrap().is_empty());
    }

    #[test]
    fn the_request_names_the_declaration_s_model_and_its_tools() {
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        let transport = Scripted::new(vec![reply_text("nothing to do")]);
        let p = paths();
        run_turn(
            Turn {
                paths: &p,
                bridge: app,
                surface: rec,
                transport: transport.clone(),
                scheme: "openrouter",
                key: "sk-test",
                model: None,
                budget: None,
                cancel: Cancel::default(),
            },
            "hello",
            &[],
        )
        .unwrap();
        let seen = transport.seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        let body = &seen[0];
        assert_eq!(body["model"], "minimax/minimax-m3");
        let names: Vec<&str> = body["tools"]
            .as_array()
            .expect("tools")
            .iter()
            .map(|t| t["function"]["name"].as_str().unwrap_or(""))
            .collect();
        for expected in ["holds", "at", "shows", "change", "undo", "export", "repaint"] {
            assert!(names.contains(&expected), "{expected} is missing from {names:?}");
        }
    }

    #[test]
    fn the_history_the_ui_holds_is_what_the_model_is_shown() {
        let app = FakeApp::new();
        let rec = Recorder::new(true);
        let transport = Scripted::new(vec![reply_text("still here")]);
        let p = paths();
        run_turn(
            Turn {
                paths: &p,
                bridge: app,
                surface: rec,
                transport: transport.clone(),
                scheme: "openrouter",
                key: "sk-test",
                model: None,
                budget: None,
                cancel: Cancel::default(),
            },
            "and now",
            &[
                Said {
                    role: "user".into(),
                    text: "make it blue".into(),
                },
                Said {
                    role: "assistant".into(),
                    text: "done".into(),
                },
            ],
        )
        .unwrap();
        let seen = transport.seen.lock().unwrap();
        let text = seen[0]["messages"].to_string();
        assert!(text.contains("make it blue"));
        assert!(text.contains("and now"));
    }

    #[test]
    fn the_chat_surface_s_roles_become_the_harness_s() {
        assert_eq!(malleable_role("assistant"), "agent");
        assert_eq!(malleable_role("user"), "user");
        assert_eq!(malleable_role("system"), "user", "nothing else may be a role");
    }

    #[test]
    fn two_is_the_port_convention_in_both_directions() {
        assert_eq!(two(Ok("ok".into())), (Some("ok".into()), None));
        assert_eq!(two(Err("no".into())), (None, Some("no".into())));
    }
}
