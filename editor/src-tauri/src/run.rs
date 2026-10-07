//! The editor's agent: one Tablua run (`./moonsplice studio`) on the open composition per ask.
//!
//! The run is the same one a terminal or a script starts, so the app adds no agent of its own: the
//! model, its tools, connect (other people's apps, `.robot/docs/connect.robot`) and the rows it writes
//! are Tablua's. The run edits the composition's file through typed moves and the app's watcher
//! (`framing::watch`) re-reads it, so the person sees each change land. What the run waits on the
//! person for (a service to connect, a call to approve) is a row the connect sheet already shows.
//!
//! The run's log on stderr is its steps (`[step 3] look -> complete`); each becomes a tool part in
//! the chat. Its last line on stdout is the run as JSON: what the model said, and the asks.
//! The model key goes to the run in its environment, never as an argument, and is not logged.

use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tauri::ipc::Channel;

use crate::agent::Cancel;

/// One `[step N] tool -> outcome` line, or nothing.
pub(crate) fn step(line: &str) -> Option<(u32, String, String)> {
    let rest = line.strip_prefix("[step ")?;
    let (n, rest) = rest.split_once("] ")?;
    let (tool, outcome) = rest.split_once(" -> ")?;
    Some((n.trim().parse().ok()?, tool.trim().to_string(), outcome.trim().to_string()))
}

/// The run's JSON line, as the chat's last chunk.
/// `said` is the run's last line of log that was not a step: what it said when it could not start.
pub(crate) fn answer(stdout: &str, steps: u32, said: &str) -> Value {
    let last = stdout.lines().rev().find(|l| l.trim_start().starts_with('{'));
    let Some(run) = last.and_then(|l| serde_json::from_str::<Value>(l).ok()) else {
        let why = said.trim().strip_prefix("moonsplice studio: ").unwrap_or(said.trim());
        let why = if why.is_empty() { "the run ended without saying how" } else { why };
        return json!({ "event": "answer", "stop": "error", "reason": why, "steps": steps });
    };
    let said = run.get("said").and_then(Value::as_str).unwrap_or("").trim().to_string();
    let mut notes = Vec::new();
    if let Some(asks) = run.get("asks").and_then(Value::as_array) {
        for a in asks {
            if let Some(how) = a.get("how").and_then(Value::as_str) {
                notes.push(format!("Waiting on you: {how}."));
            }
        }
    }
    // The chat draws the answer's text, so what waits on the person goes there too, unless the
    // model already said it; the connect sheet is where they answer it.
    let mut text = said;
    for n in &notes {
        if !text.contains("moonsplice connect") {
            text = if text.is_empty() { n.clone() } else { format!("{text}\n\n{n}") };
        }
    }
    let done = run.get("status").and_then(Value::as_str) == Some("complete");
    json!({
        "event": "answer",
        "stop": if done { "answered" } else { "error" },
        "reason": if done { Value::Null } else { run.get("error").cloned().unwrap_or(Value::Null) },
        "answer": text,
        "steps": run.get("steps").and_then(Value::as_u64).unwrap_or(steps as u64),
        "notes": notes,
    })
}

pub(crate) struct Ask {
    pub comp: PathBuf,
    pub work: PathBuf,
    pub prompt: String,
    pub todo: String,
}

/// Start the run and stream it to `channel`; returns once it has started.
pub(crate) fn start(ask: Ask, channel: Channel<Value>, cancel: Cancel, done: impl FnOnce() + Send + 'static) -> Result<(), String> {
    let root = crate::engine::moonsplice_root().ok_or("the Moonsplice engine is not next to this app")?;
    std::fs::create_dir_all(&ask.work).map_err(|e| format!("no room for the run ({e})"))?;
    let mut cmd = Command::new(root.join("moonsplice"));
    cmd.arg("studio")
        .arg("--comp").arg(&ask.comp)
        .arg("--ask").arg(&ask.prompt)
        .arg("--work").arg(&ask.work)
        .arg("--sheet").arg(ask.work.join("runs.sqlite"))
        .arg("--todo").arg(&ask.todo)
        .current_dir(&root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(key) = crate::secrets::resolve("openrouter") {
        cmd.env("OPENROUTER_API_KEY", key);
    }
    let mut child = cmd.spawn().map_err(|e| format!("the run did not start ({e})"))?;
    let stderr = child.stderr.take().ok_or("the run has no log")?;
    let mut stdout = child.stdout.take().ok_or("the run has no output")?;
    let child: Arc<Mutex<Child>> = Arc::new(Mutex::new(child));
    let _ = channel.send(json!({ "event": "start", "budget": 0 }));

    // Stop: the person pressed stop, so the run is killed; its moves so far stay, each was checked.
    {
        let child = child.clone();
        let cancel = cancel.clone();
        std::thread::spawn(move || loop {
            if cancel.stopped() {
                let _ = child.lock().unwrap().kill();
                return;
            }
            if matches!(child.lock().unwrap().try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(Duration::from_millis(200));
        });
    }

    let steps = Arc::new(Mutex::new(0u32));
    let said = Arc::new(Mutex::new(String::new()));
    let log = {
        let channel = channel.clone();
        let steps = steps.clone();
        let said = said.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                let Some((n, tool, outcome)) = step(&line) else {
                    if !line.trim().is_empty() && !line.starts_with('[') {
                        *said.lock().unwrap() = line;
                    }
                    continue;
                };
                *steps.lock().unwrap() = n;
                let call = format!("s{n}");
                let _ = channel.send(json!({ "event": "call", "step": n, "call": call, "tool": tool, "ask": false }));
                let _ = channel.send(json!({
                    "event": "result", "call": call, "tool": tool,
                    "ok": outcome != "broken", "refused": false, "size": 0,
                }));
            }
        })
    };

    std::thread::spawn(move || {
        let mut out = String::new();
        let _ = stdout.read_to_string(&mut out);
        let _ = log.join();
        let _ = child.lock().unwrap().wait();
        let n = *steps.lock().unwrap();
        let payload = if cancel.stopped() {
            json!({ "event": "answer", "stop": "stopped", "reason": "you stopped the run", "steps": n })
        } else {
            answer(&out, n, &said.lock().unwrap())
        };
        let _ = channel.send(payload);
        done();
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_step_line_reads_as_its_tool_and_outcome() {
        assert_eq!(step("[step 12] look -> complete"), Some((12, "look".into(), "complete".into())));
        assert_eq!(step("[ask] connect github: the person connects GitHub"), None);
        assert_eq!(step("[done] stop, complete"), None);
    }

    #[test]
    fn the_runs_json_becomes_the_answer_with_what_waits_on_the_person() {
        let out = "noise\n{\"status\":\"complete\",\"steps\":21,\"said\":\"Handing in.\",\"asks\":[{\"how\":\"the person connects GitHub in the Moonsplice app (Connections)\",\"kind\":\"connect\",\"service\":\"github\"}]}\n";
        let a = answer(out, 3, "");
        assert_eq!(a["stop"], "answered");
        assert!(a["answer"].as_str().unwrap().starts_with("Handing in.\n\nWaiting on you: the person connects GitHub"));
        assert_eq!(a["steps"], 21);
        assert_eq!(a["notes"][0], "Waiting on you: the person connects GitHub in the Moonsplice app (Connections).");
    }

    #[test]
    fn a_run_that_failed_says_why_and_one_that_said_nothing_is_an_error() {
        let a = answer("{\"status\":\"error\",\"steps\":2,\"error\":\"the model timed out\",\"asks\":{}}", 0, "");
        assert_eq!(a["stop"], "error");
        assert_eq!(a["reason"], "the model timed out");
        assert_eq!(answer("", 4, "")["reason"], "the run ended without saying how");
        let a = answer("", 0, "moonsplice studio: no OPENROUTER_API_KEY; run `./moonsplice connect openrouter`");
        assert_eq!(a["reason"], "no OPENROUTER_API_KEY; run `./moonsplice connect openrouter`");
    }
}
