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

// ------------------------------------------------------------------------------- commands

fn init(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let dir = a.words.first().ok_or("say where the project goes: moonsplice-agent init DIR")?;
    let footage: Vec<PathBuf> = a.all("--footage").into_iter().map(PathBuf::from).collect();
    let comp = a.get(&["--comp", "-c"]).unwrap_or_else(|| "Main".into());
    let size = match a.get(&["--size"]) {
        None => (1920, 1080),
        Some(s) => {
            let (w, h) = s.split_once(['x', 'X']).ok_or("--size is WIDTHxHEIGHT, like 1920x1080")?;
            (
                w.parse().map_err(|_| "--size is WIDTHxHEIGHT")?,
                h.parse().map_err(|_| "--size is WIDTHxHEIGHT")?,
            )
        }
    };
    let fps = a.num(&["--fps"])?.unwrap_or(30.0);
    let duration = a.num(&["--duration"])?.unwrap_or(10.0);
    let made = headless::init(Path::new(dir), &footage, &comp, size, fps, duration)?;
    println!("{}", serde_json::to_string_pretty(&made).unwrap());
    Ok(ExitCode::SUCCESS)
}

fn tools(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let list = agent::list_tools(&paths(&a)?)?;
    if a.has(&["--json"]) {
        println!("{}", serde_json::to_string_pretty(&list).unwrap());
        return Ok(ExitCode::SUCCESS);
    }
    println!(
        "{} — {} tools, {} steps a turn, model {}\n",
        list["agent"].as_str().unwrap_or("agent"),
        list["tools"].as_array().map(|t| t.len()).unwrap_or(0),
        list["budget"],
        list["model"].as_str().unwrap_or("?"),
    );
    for t in list["tools"].as_array().cloned().unwrap_or_default() {
        println!(
            "{}{}\n  {}",
            t["name"].as_str().unwrap_or(""),
            if t["asks_first"].as_bool().unwrap_or(false) { "  (changes the composition)" } else { "" },
            t["description"].as_str().unwrap_or("")
        );
        let req: Vec<String> = t["input_schema"]["required"]
            .as_array()
            .map(|r| r.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default();
        if let Some(props) = t["input_schema"]["properties"].as_object() {
            for (k, p) in props {
                println!(
                    "    {k}{} ({}) — {}",
                    if req.contains(k) { "" } else { "?" },
                    p["type"].as_str().unwrap_or(""),
                    p["description"].as_str().unwrap_or("").split_whitespace().collect::<Vec<_>>().join(" ")
                );
            }
        }
        println!();
    }
    Ok(ExitCode::SUCCESS)
}

fn call(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let tool = a.words.first().ok_or("say which tool: moonsplice-agent call TOOL '{...}' --project DIR")?;
    let args: serde_json::Value = match a.words.get(1) {
        None => serde_json::json!({}),
        Some(s) if s == "-" => {
            let mut text = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut text).map_err(|e| e.to_string())?;
            serde_json::from_str(&text).map_err(|e| format!("the arguments are not JSON ({e})"))?
        }
        Some(s) => serde_json::from_str(s).map_err(|e| format!("the arguments are not JSON ({e})"))?,
    };
    let paths = paths(&a)?;
    let s = Arc::new(session(&a)?);
    let out = agent::call_tool(&paths, s.clone(), tool, args);
    s.close();
    match out {
        Ok(text) => {
            println!("{text}");
            Ok(ExitCode::SUCCESS)
        }
        Err(why) => {
            println!("{why}");
            Ok(ExitCode::from(1))
        }
    }
}

fn render(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let project = a.get(&["--project", "-p"]).ok_or("say which project with --project DIR")?;
    let root_dir = Path::new(&project).canonicalize().map_err(|e| format!("{project}: {e}"))?;
    let p = moonsplice_studio_lib::project::Project::open(&root_dir).map_err(|e| e.to_string())?;
    let variation = headless::pick_variation(&p, a.get(&["--comp", "-c"]).as_deref())?;
    let comp = p.source_of(&variation).ok_or("that composition is not in this project")?;
    let rel = comp.strip_prefix(&root_dir).unwrap_or(&comp).to_path_buf();
    let out = match a.get(&["-o", "--out"]) {
        Some(o) => {
            let o = PathBuf::from(o);
            if o.is_absolute() { o } else { std::env::current_dir().map_err(|e| e.to_string())?.join(o) }
        }
        None => root_dir.join("exports").join(format!("{variation}.mp4")),
    };
    if let Some(d) = out.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let quality = a.get(&["--quality", "-q"]).unwrap_or_else(|| "standard".into());
    let mut cmd = std::process::Command::new(root()?.join("moonsplice"));
    cmd.arg("render").arg(&rel).arg("-o").arg(&out).current_dir(&root_dir).env("MOONSPLICE_QUALITY", &quality);
    if let Some(f) = a.get(&["--fps"]) {
        cmd.arg("--fps").arg(f);
    }
    let started = Instant::now();
    let status = cmd.status().map_err(|e| format!("the renderer did not start ({e})"))?;
    if !status.success() {
        return Err("the render failed (the renderer's own message is above)".into());
    }
    let summary = serde_json::json!({
        "out": out,
        "comp": variation,
        "quality": quality,
        "elapsed_s": (started.elapsed().as_secs_f64() * 10.0).round() / 10.0,
        "duration_s": headless::media_duration(&out).ok(),
    });
    println!("{}", serde_json::to_string_pretty(&summary).unwrap());
    Ok(ExitCode::SUCCESS)
}

// ------------------------------------------------------------------------------------ run

/// The terminal, as a chat surface: events to a file (and a line each to stderr), approvals
/// either given in advance or asked on the terminal.
struct Terminal {
    yes: bool,
    quiet: bool,
    events: Option<Mutex<std::fs::File>>,
    started: Instant,
    turn: Mutex<u32>,
}

impl Terminal {
    fn write(&self, mut v: serde_json::Value) {
        v["t"] = serde_json::json!((self.started.elapsed().as_secs_f64() * 100.0).round() / 100.0);
        v["turn"] = serde_json::json!(*self.turn.lock().unwrap());
        if let Some(f) = &self.events {
            let mut f = f.lock().unwrap();
            let _ = writeln!(f, "{v}");
            let _ = f.flush();
        }
    }
}

impl Surface for Terminal {
    fn emit(&self, chunk: serde_json::Value) {
        if !self.quiet {
            match chunk["event"].as_str().unwrap_or("") {
                "call" => eprintln!("  · {}", chunk["tool"].as_str().unwrap_or("?")),
                "result" if chunk["refused"].as_bool() == Some(true) || chunk["ok"].as_bool() == Some(false) => {
                    eprintln!("    refused: {}", chunk["tool"].as_str().unwrap_or("?"))
                }
                "stop" => eprintln!(
                    "  stop: {} after {} step(s)",
                    chunk["stop"].as_str().unwrap_or("?"),
                    chunk["steps"]
                ),
                _ => {}
            }
        }
        self.write(chunk);
    }

    fn ask(&self, ask: Ask) -> Decision {
        self.write(serde_json::json!({ "event": "ask", "tool": ask.tool, "auto": self.yes }));
        if self.yes {
            return Decision { allow: true, reason: None, remember: None };
        }
        eprint!("{} wants to {} — allow? [y/N/a(lways)] ", "the agent", ask.tool);
        let _ = std::io::stderr().flush();
        let mut line = String::new();
        let _ = std::io::stdin().lock().read_line(&mut line);
        match line.trim() {
            "y" | "Y" | "yes" => Decision { allow: true, reason: None, remember: None },
            "a" | "A" | "always" => Decision { allow: true, reason: None, remember: Some("tool".into()) },
            _ => Decision { allow: false, reason: Some("the person said no".into()), remember: None },
        }
    }
}

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
