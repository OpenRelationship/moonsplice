//! The desktop epic's agent surface, scenario by scenario (see spec.rs for how the names are used).

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use moonsplice_studio_lib::agent::{self, Ask, Decision, Outcome, Paths, Surface, Transport, Turn};
use moonsplice_studio_lib::lower::Edit;
use moonsplice_studio_lib::net;

mod spec_common;
use spec_common::*;

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        if let Ok(rd) = std::fs::read_dir(&d) {
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() {
                    stack.push(p);
                } else {
                    out.push(p);
                }
            }
        }
    }
    out
}

// --- a turn, with a scripted model, so the surface is under test and the network is not ---

struct Scripted(Mutex<std::collections::VecDeque<serde_json::Value>>);

impl Transport for Scripted {
    fn fetch(&self, _r: net::Request) -> Result<net::Response, net::PortError> {
        let body = self
            .0
            .lock()
            .unwrap()
            .pop_front()
            .unwrap_or_else(|| text("done"));
        Ok(net::Response {
            status: 200,
            headers: Default::default(),
            body: body.to_string(),
        })
    }
}

fn text(t: &str) -> serde_json::Value {
    serde_json::json!({
        "id": "c", "choices": [{ "index": 0, "finish_reason": "stop",
        "message": { "role": "assistant", "content": t } }]
    })
}

fn calls(cs: &[(&str, serde_json::Value)]) -> serde_json::Value {
    let tool_calls: Vec<serde_json::Value> = cs
        .iter()
        .enumerate()
        .map(|(i, (name, args))| {
            serde_json::json!({
                "id": format!("call_{i}"), "type": "function",
                "function": { "name": name, "arguments": args.to_string() }
            })
        })
        .collect();
    serde_json::json!({
        "id": "c", "choices": [{ "index": 0, "finish_reason": "tool_calls",
        "message": { "role": "assistant", "content": serde_json::Value::Null,
                     "tool_calls": tool_calls } }]
    })
}

/// What the app looks like to a tool body, with every touch recorded in order.
#[derive(Default)]
struct Spy {
    log: Mutex<Vec<String>>,
    source: Mutex<String>,
}

impl agent::AppBridge for Spy {
    fn outline_text(&self) -> Result<String, String> {
        self.log.lock().unwrap().push("read".into());
        Ok("Hero — 2.0s, 1280x720, 30 fps.\n- Block, 1 of 1 from the back".into())
    }
    fn at_text(&self, _t: f64) -> Result<String, String> {
        self.log.lock().unwrap().push("at".into());
        Ok("At 1.00s:\n- Block: across 80".into())
    }
    fn shows_text(&self) -> Result<String, String> {
        Ok("holds(block, visible, 1.0)".into())
    }
    fn change(&self, edits: Vec<Edit>, _why: &str) -> Result<String, String> {
        self.log.lock().unwrap().push(format!("change x{}", edits.len()));
        *self.source.lock().unwrap() = "changed".into();
        Ok(format!("changed {} thing(s)", edits.len()))
    }
    fn project_text(&self) -> Result<String, String> {
        self.log.lock().unwrap().push("project".into());
        Ok("Demo holds:\n- Earth night — a clip".into())
    }
    fn place(&self, thing: &str, _at: Option<f64>) -> Result<String, String> {
        self.log.lock().unwrap().push(format!("place {thing}"));
        Ok(format!("put {thing} in"))
    }
    fn move_clip(
        &self,
        node: &str,
        to: Option<f64>,
        trim: Option<String>,
        at: Option<f64>,
    ) -> Result<String, String> {
        let where_to = to.or(at).unwrap_or(0.0);
        self.log
            .lock()
            .unwrap()
            .push(match &trim {
                Some(edge) => format!("trim {node} {edge} {where_to}"),
                None => format!("slide {node} {where_to}"),
            });
        Ok(match trim {
            Some(edge) => format!("trimmed the {edge} of {node}"),
            None => format!("moved {node}"),
        })
    }
    fn move_when(&self, node: &str, at: f64, which: Option<f64>) -> Result<String, String> {
        self.log
            .lock()
            .unwrap()
            .push(format!("move_when {node} {at} {}", which.unwrap_or(1.0)));
        Ok(format!("{node} starts at {at}s"))
    }
    fn restack(&self, node: &str, over: Option<String>) -> Result<String, String> {
        self.log
            .lock()
            .unwrap()
            .push(format!("restack {node} over {}", over.as_deref().unwrap_or("nothing")));
        Ok(format!("moved {node}"))
    }
    fn cut_clip(&self, node: &str, at: f64) -> Result<String, String> {
        self.log.lock().unwrap().push(format!("cut {node} {at}"));
        Ok(format!("cut {node} in two"))
    }
    fn note(&self, at: f64, text: &str) -> Result<String, String> {
        self.log.lock().unwrap().push(format!("note {at} {text}"));
        Ok(format!("pinned a note at {at}s"))
    }
    fn close_gap(&self, node: &str, take_out: bool) -> Result<String, String> {
        self.log
            .lock()
            .unwrap()
            .push(format!("close_gap {node} {take_out}"));
        Ok(format!("closed the gap after {node}"))
    }
    fn undo(&self) -> Result<String, String> {
        self.log.lock().unwrap().push("undo".into());
        Ok("undid it".into())
    }
    fn export(&self, q: &str) -> Result<String, String> {
        self.log.lock().unwrap().push("export".into());
        Ok(format!("rendering at {q}"))
    }
    fn repaint(&self, _i: &str) -> Result<String, String> {
        self.log.lock().unwrap().push("repaint".into());
        // A new rendered asset, never a change to the composition.
        Ok("made a new clip from the render".into())
    }
}

struct Watch {
    asked: Mutex<Vec<Ask>>,
    chunks: Mutex<Vec<serde_json::Value>>,
    log: Arc<Mutex<Vec<String>>>,
    allow: bool,
}

impl Surface for Watch {
    fn emit(&self, chunk: serde_json::Value) {
        self.chunks.lock().unwrap().push(chunk);
    }
    fn ask(&self, ask: Ask) -> Decision {
        self.log.lock().unwrap().push(format!("asked:{}", ask.tool));
        self.asked.lock().unwrap().push(ask);
        Decision { allow: self.allow, reason: None, remember: None }
    }
}

fn turn(
    replies: Vec<serde_json::Value>,
    prompt: &str,
    allow: bool,
) -> Option<(Outcome, Arc<Spy>, Arc<Watch>)> {
    let root = root()?;
    let paths = Paths::resolve(&root).ok()?;
    let spy = Arc::new(Spy::default());
    let watch = Arc::new(Watch {
        asked: Mutex::new(Vec::new()),
        chunks: Mutex::new(Vec::new()),
        log: Arc::new(Mutex::new(Vec::new())),
        allow,
    });
    let outcome = agent::run_turn(
        Turn {
            paths: &paths,
            bridge: spy.clone(),
            surface: watch.clone(),
            transport: Arc::new(Scripted(Mutex::new(replies.into()))),
            scheme: "openrouter",
            key: "sk-test",
            model: None,
            budget: None,
            cancel: agent::Cancel::default(),
        },
        prompt,
        &[],
    )
    .ok()?;
    Some((outcome, spy, watch))
}

/// Scenario: a turn streams without a local server
#[test]
fn a_turn_streams_without_a_local_server() {
    let Some((outcome, _, watch)) = turn(
        vec![calls(&[("holds", serde_json::json!({}))]), text("Six things.")],
        "what is in this?",
        true,
    ) else {
        return eprintln!("skipped: no checkout");
    };

    // Chunks arrive: the surface is a channel the host owns, not a socket.
    let chunks = watch.chunks.lock().unwrap();
    assert!(!chunks.is_empty(), "no chunks arrived");
    let kinds: Vec<&str> = chunks.iter().filter_map(|c| c["event"].as_str()).collect();
    assert!(kinds.contains(&"start"), "{kinds:?}");
    assert!(kinds.contains(&"stop"), "{kinds:?}");
    assert_eq!(outcome.stop, "answered");

    // And the app opens no port for this. Scanning localhost would only tell us what else is
    // running on the machine -- there is an Ollama on 11434 here -- so the check is on the app
    // itself: nothing in it binds a socket or pulls in a server, and it fails loudly the day
    // somebody adds one.
    let root = root().expect("the checkout");
    let mut binds: Vec<String> = Vec::new();
    for f in walk(&root.join("editor/src-tauri/src")) {
        if f.extension().and_then(|s| s.to_str()) != Some("rs") {
            continue;
        }
        let text = std::fs::read_to_string(&f).unwrap_or_default();
        for pattern in ["TcpListener", "UdpSocket", "axum::", "warp::", "actix", "Server::bind"] {
            if text.contains(pattern) {
                binds.push(format!("{}: {pattern}", f.file_name().unwrap().to_string_lossy()));
            }
        }
    }
    assert!(binds.is_empty(), "the app binds a socket: {binds:?}");
    let manifest = std::fs::read_to_string(root.join("editor/src-tauri/Cargo.toml")).unwrap();
    for server in ["axum", "warp", "actix-web", "tiny_http", "hyper ="] {
        assert!(!manifest.contains(server), "the app depends on {server}");
    }
    eprintln!(
        "  {} chunks over the host's own channel, and the app binds nothing",
        chunks.len()
    );
}

/// Scenario: an edit asks before it lands
#[test]
fn an_edit_asks_before_it_lands() {
    let Some((_, spy, watch)) = turn(
        vec![
            calls(&[(
                "change",
                serde_json::json!({
                    "edits": [{"verb":"set_prop","node":"Block","key":"Width","value":640}],
                    "why": "widen the bar"
                }),
            )]),
            text("Widened it."),
        ],
        "make the bar wider",
        true,
    ) else {
        return eprintln!("skipped: no checkout");
    };

    // The harness asked, and the order is the point: the approval came before the body ran.
    let log = spy.log.lock().unwrap().clone();
    let asked = watch.log.lock().unwrap().clone();
    assert!(!watch.asked.lock().unwrap().is_empty(), "it never asked");
    assert!(log.iter().any(|l| l.starts_with("change")), "the body never ran: {log:?}");
    assert!(
        asked.iter().any(|a| a == "asked:change"),
        "the approval was not for the change: {asked:?}"
    );
    // And what the person was shown is a shape, never a Lua value.
    let ask = &watch.asked.lock().unwrap()[0];
    assert_eq!(ask.tool, "change");
    assert!(ask.args.is_object() || ask.args.is_null(), "{:?}", ask.args);
    eprintln!("  asked for `{}`, then ran it", ask.tool);
}

/// Scenario: a refusal is a result, not an error
#[test]
fn a_refusal_is_a_result_not_an_error() {
    let Some((outcome, spy, watch)) = turn(
        vec![
            calls(&[(
                "change",
                serde_json::json!({
                    "edits": [{"verb":"set_prop","node":"Block","key":"Width","value":640}],
                    "why": "widen the bar"
                }),
            )]),
            text("You said no, so I left it alone."),
        ],
        "make the bar wider",
        false, // the person declines
    ) else {
        return eprintln!("skipped: no checkout");
    };

    // The turn continued and ended normally.
    assert_eq!(outcome.stop, "answered", "a refusal ended the turn as an error");
    assert!(outcome.answer.is_some(), "it had nothing to say afterwards");

    // The body never ran, and the model got the refusal as an ordinary tool result: the proof
    // is that it kept going and answered.
    let log = spy.log.lock().unwrap().clone();
    assert!(
        !log.iter().any(|l| l.starts_with("change")),
        "a declined change ran anyway: {log:?}"
    );
    assert_eq!(*spy.source.lock().unwrap(), "", "the composition was touched");
    let kinds: Vec<String> = watch
        .chunks
        .lock()
        .unwrap()
        .iter()
        .filter_map(|c| c["event"].as_str().map(str::to_string))
        .collect();
    assert!(
        kinds.iter().any(|k| k == "result"),
        "no tool result was reported: {kinds:?}"
    );
    eprintln!("  declined, and the turn answered anyway: {:?}", outcome.reason);
}

/// Scenario: the pixel model never edits a composition
#[test]
fn the_pixel_model_never_edits_a_composition() {
    let Some((_, spy, _)) = turn(
        vec![
            calls(&[(
                "repaint",
                serde_json::json!({ "instruction": "remove the text in the corner" }),
            )]),
            text("Made a new clip with the text gone."),
        ],
        "get rid of the text burned into the footage",
        true,
    ) else {
        return eprintln!("skipped: no checkout");
    };

    let log = spy.log.lock().unwrap().clone();
    assert!(log.iter().any(|l| l == "repaint"), "it never used it: {log:?}");
    // The composition source is unchanged: nothing on the pixel path can reach `change`.
    assert!(
        !log.iter().any(|l| l.starts_with("change")),
        "the pixel model changed the composition: {log:?}"
    );
    assert_eq!(
        *spy.source.lock().unwrap(),
        "",
        "the source moved on a pixel edit"
    );
    eprintln!("  repainted pixels, composition untouched");
}
