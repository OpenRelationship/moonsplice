use super::*;
use std::sync::Mutex;

pub(super) struct FakeApp {
    pub(super) changed: Mutex<Vec<Vec<Edit>>>,
    pub(super) undone: Mutex<u32>,
    pub(super) placed: Mutex<Vec<(String, Option<f64>)>>,
    pub(super) moved: Mutex<Vec<(String, Option<f64>, Option<String>, Option<f64>)>>,
    pub(super) cut: Mutex<Vec<(String, f64)>>,
}

impl FakeApp {
    pub(super) fn new() -> Arc<FakeApp> {
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

pub(super) struct Recorder {
    pub(super) chunks: Mutex<Vec<serde_json::Value>>,
    pub(super) asked: Mutex<Vec<Ask>>,
    pub(super) answer: bool,
}

impl Recorder {
    pub(super) fn new(answer: bool) -> Arc<Recorder> {
        Arc::new(Recorder {
            chunks: Mutex::new(Vec::new()),
            asked: Mutex::new(Vec::new()),
            answer,
        })
    }
    pub(super) fn events(&self) -> Vec<String> {
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
pub(super) struct Scripted {
    pub(super) replies: Mutex<std::collections::VecDeque<serde_json::Value>>,
    pub(super) seen: Mutex<Vec<serde_json::Value>>,
}

impl Scripted {
    pub(super) fn new(replies: Vec<serde_json::Value>) -> Arc<Scripted> {
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

pub(super) fn reply_calls(calls: &[(&str, serde_json::Value)]) -> serde_json::Value {
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

pub(super) fn reply_text(text: &str) -> serde_json::Value {
    serde_json::json!({
        "id": "cmpl",
        "choices": [{
            "index": 0,
            "finish_reason": "stop",
            "message": { "role": "assistant", "content": text }
        }]
    })
}

pub(super) fn paths() -> Paths {
    let root = crate::engine::moonsplice_root().expect("the checkout");
    Paths::resolve(&root).expect("the agent's files")
}

pub(super) fn run(
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
