//! `moonsplice-agent`: Moonsplice Studio's agent, from a shell.
//!
//! The same agent as the window's -- the declaration, the tool bodies, the lowering and the
//! engine are all the app's -- with no window. So a person can script it, an eval can measure
//! it, and another agent (Claude Code, anything that can run a command) can either hand it a goal
//! or call its tools one at a time.
//!
//!     moonsplice-agent init DIR --footage take.mov [--comp Main] [--size 1920x1080] [--fps 30] [--duration 300]
//!     moonsplice-agent tools [--json] [--declaration producer|editor]
//!     moonsplice-agent call TOOL ['{"json": "args"}'] --project DIR [--comp NAME]
//!     moonsplice-agent run --project DIR [--comp NAME] --goal TEXT [--model P:M] [--budget N]
//!                       [--turns N] [--yes] [--events FILE.ndjson] [--json]
//!     moonsplice-agent render --project DIR [--comp NAME] -o OUT.mp4 [--quality draft|standard|high] [--fps N]
//!
//! `call` runs one tool body with no model and no gate: it is how something outside uses the
//! exact surface the agent uses. `run` is the agent loop, unattended with `--yes`.

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use moonsplice_studio_lib::agent::{self, Ask, Decision, Said, Surface, Turn};
use moonsplice_studio_lib::engine;
use moonsplice_studio_lib::headless::{self, Session};
use moonsplice_studio_lib::secrets;

mod commands;
mod terminal;

use commands::*;
use terminal::*;

const USAGE: &str = "\
moonsplice-agent: Moonsplice Studio's agent, with no window.

  moonsplice-agent init DIR --footage FILE [--footage FILE]... [--comp NAME] [--size WxH] [--fps N] [--duration S]
      A project folder: footage linked into Footage/ (a phone take stored on its side gets an
      upright copy), typefaces in Fonts/, and an empty composition. Prints JSON.
  moonsplice-agent tools [--json] [--declaration producer|editor]
      Every tool, with what it is for and its arguments as JSON Schema.
  moonsplice-agent call TOOL [ARGS_JSON] --project DIR [--comp NAME]
      Run one tool against the composition on disk, no model and no approval. The answer is
      printed; exit 1 when the tool refused (the refusal is printed too).
  moonsplice-agent run --project DIR [--comp NAME] --goal TEXT [--model PROVIDER:MODEL] [--budget STEPS]
                    [--turns N] [--yes] [--events FILE.ndjson] [--json] [--declaration producer|editor]
      The agent loop. --yes approves every change; otherwise each is asked on the terminal.
      With --turns N it keeps going toward the goal until it says DONE or N turns have run.
  moonsplice-agent render --project DIR [--comp NAME] -o OUT.mp4 [--quality draft|standard|high] [--fps N]
      Render the composition to a video.

The key comes from OPENROUTER_API_KEY (or the keychain the app uses).";

fn main() -> ExitCode {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).try_init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first().cloned() else {
        eprintln!("{USAGE}");
        return ExitCode::from(2);
    };
    let rest = &args[1..];
    let result = match cmd.as_str() {
        "init" => init(rest),
        "tools" => tools(rest),
        "call" => call(rest),
        "run" => run(rest),
        "render" => render(rest),
        "-h" | "--help" | "help" => {
            println!("{USAGE}");
            Ok(ExitCode::SUCCESS)
        }
        other => Err(format!("there is no command {other:?}\n\n{USAGE}")),
    };
    match result {
        Ok(code) => code,
        Err(why) => {
            eprintln!("moonsplice-agent: {why}");
            ExitCode::FAILURE
        }
    }
}

// ------------------------------------------------------------------------------- arguments

/// Flags and the words between them. `--name value`, `--switch`, and positionals in order.
struct Args {
    flags: Vec<(String, Option<String>)>,
    words: Vec<String>,
}

const SWITCHES: &[&str] = &["--json", "--yes", "-y"];

impl Args {
    fn parse(raw: &[String]) -> Args {
        let mut flags = Vec::new();
        let mut words = Vec::new();
        let mut i = 0;
        while i < raw.len() {
            let a = &raw[i];
            if a.starts_with('-') && a.len() > 1 && a.parse::<f64>().is_err() {
                if let Some((k, v)) = a.split_once('=') {
                    flags.push((k.to_string(), Some(v.to_string())));
                } else if SWITCHES.contains(&a.as_str()) || i + 1 >= raw.len() {
                    flags.push((a.clone(), None));
                } else {
                    flags.push((a.clone(), Some(raw[i + 1].clone())));
                    i += 1;
                }
            } else {
                words.push(a.clone());
            }
            i += 1;
        }
        Args { flags, words }
    }
    fn get(&self, names: &[&str]) -> Option<String> {
        self.flags
            .iter()
            .rev()
            .find(|(k, _)| names.contains(&k.as_str()))
            .and_then(|(_, v)| v.clone())
    }
    fn all(&self, name: &str) -> Vec<String> {
        self.flags
            .iter()
            .filter(|(k, _)| k == name)
            .filter_map(|(_, v)| v.clone())
            .collect()
    }
    fn has(&self, names: &[&str]) -> bool {
        self.flags.iter().any(|(k, _)| names.contains(&k.as_str()))
    }
    fn num(&self, names: &[&str]) -> Result<Option<f64>, String> {
        match self.get(names) {
            None => Ok(None),
            Some(v) => v
                .parse::<f64>()
                .map(Some)
                .map_err(|_| format!("{} takes a number, not {v:?}", names[0])),
        }
    }
}

fn root() -> Result<PathBuf, String> {
    engine::moonsplice_root().ok_or_else(|| {
        "the Moonsplice checkout is not here; run from inside it or set MOONSPLICE_ROOT".into()
    })
}

fn paths(a: &Args) -> Result<agent::Paths, String> {
    let decl = a.get(&["--declaration"]).unwrap_or_else(|| "producer".into());
    agent::Paths::resolve_as(&root()?, &decl)
}

fn serve_dir() -> PathBuf {
    std::env::temp_dir().join(format!("moonsplice-agent-{}", std::process::id()))
}

fn session(a: &Args) -> Result<Session, String> {
    let project = a
        .get(&["--project", "-p"])
        .ok_or("say which project with --project DIR")?;
    let comp = a.get(&["--comp", "-c"]);
    Session::open(Path::new(&project), comp.as_deref(), &serve_dir())
}

// ------------------------------------------------------------------------------------ run

fn run(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let goal = a.get(&["--goal", "-g"]).ok_or("say what to do with --goal TEXT")?;
    let turns = a.num(&["--turns"])?.unwrap_or(1.0).max(1.0) as u32;
    let budget = a.num(&["--budget"])?.map(|b| b.max(1.0) as u32);
    let model = a.get(&["--model", "-m"]);
    let json = a.has(&["--json"]);
    let (scheme, key) = match std::env::var("OPENROUTER_API_KEY").ok().filter(|k| !k.is_empty()) {
        Some(k) => ("openrouter".to_string(), k),
        None => {
            let (s, k) = secrets::preferred()?;
            (s.to_string(), k)
        }
    };
    let paths = paths(&a)?;
    let s = Arc::new(session(&a)?);
    let events = match a.get(&["--events"]) {
        Some(f) => Some(Mutex::new(
            std::fs::File::create(&f).map_err(|e| format!("{f}: {e}"))?,
        )),
        None => None,
    };
    let term = Arc::new(Terminal {
        yes: a.has(&["--yes", "-y"]),
        quiet: json,
        events,
        started: Instant::now(),
        turn: Mutex::new(0),
    });
    term.write(serde_json::json!({
        "event": "begin",
        "goal": goal,
        "project": s.root(),
        "comp": s.variation,
        "model": model,
        "budget": budget,
        "turns": turns,
    }));

    let mut history: Vec<Said> = Vec::new();
    let mut prompt = goal.clone();
    let (mut steps, mut calls, mut tin, mut tout) = (0u32, 0u32, 0u64, 0u64);
    let mut last: Option<agent::Outcome> = None;
    let mut ran = 0;
    let mut done = false;
    let mut failure: Option<String> = None;
    for n in 1..=turns {
        *term.turn.lock().unwrap() = n;
        if !json {
            eprintln!("turn {n}/{turns}");
        }
        let outcome = agent::run_turn(
            Turn {
                paths: &paths,
                bridge: s.clone(),
                surface: term.clone(),
                transport: Arc::new(agent::Http),
                scheme: &scheme,
                key: &key,
                model: model.as_deref(),
                budget,
                cancel: agent::Cancel::default(),
            },
            &prompt,
            &history,
        );
        ran = n;
        let o = match outcome {
            Ok(o) => o,
            Err(e) => {
                term.write(serde_json::json!({ "event": "error", "why": e }));
                failure = Some(e);
                break;
            }
        };
        steps += o.steps;
        calls += o.tool_calls;
        tin += o.tokens_in;
        tout += o.tokens_out;
        term.write(serde_json::json!({
            "event": "turn",
            "stop": o.stop,
            "reason": o.reason,
            "answer": o.answer,
            "steps": o.steps,
            "tool_calls": o.tool_calls,
            "tokens_in": o.tokens_in,
            "tokens_out": o.tokens_out,
        }));
        if !json {
            if let Some(ans) = &o.answer {
                eprintln!("\n{ans}\n");
            }
        }
        history.push(Said { role: "user".into(), text: prompt.clone() });
        if let Some(ans) = &o.answer {
            history.push(Said { role: "agent".into(), text: ans.clone() });
        }
        let said_done = o
            .answer
            .as_deref()
            .map(|t| t.contains("DONE"))
            .unwrap_or(false);
        let stop = o.stop.clone();
        last = Some(o);
        if said_done || stop == "error" || stop == "refused" {
            done = said_done;
            break;
        }
        prompt = format!(
            "Continue toward the goal: {goal}\nCheck what the composition holds now, do the next \
             most important part of the work, and when the goal is fully met say DONE."
        );
    }
    s.close();
    let summary = serde_json::json!({
        "stop": last.as_ref().map(|o| o.stop.clone()).unwrap_or_else(|| "error".into()),
        "reason": failure.or_else(|| last.as_ref().and_then(|o| o.reason.clone())),
        "done": done,
        "turns": ran,
        "steps": steps,
        "tool_calls": calls,
        "answer": last.as_ref().and_then(|o| o.answer.clone()),
        "elapsed_s": (term.started.elapsed().as_secs_f64() * 10.0).round() / 10.0,
        "tokens_in": tin,
        "tokens_out": tout,
        "cost_usd_if_known": serde_json::Value::Null,
        "model": model,
        "comp_file": s.comp_path(),
    });
    term.write(serde_json::json!({ "event": "end", "summary": summary }));
    if json {
        println!("{}", serde_json::to_string_pretty(&summary).unwrap());
    } else {
        eprintln!(
            "{} turn(s), {} step(s), {} tool call(s), {}s",
            ran, steps, calls, summary["elapsed_s"]
        );
    }
    Ok(if summary["stop"] == "error" { ExitCode::FAILURE } else { ExitCode::SUCCESS })
}
