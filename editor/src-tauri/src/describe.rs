use super::*;

/// What went wrong, in words, out of an engine failure that is written for a programmer.
///
/// The engine's stderr ends in a LÖVE traceback, so the last line of it is a stack frame: showing
/// it broke `app-shell` scenario 5 the moment an export failed, which is exactly when a person is
/// least able to ignore it. This reads the one line that carries a reason, strips the positions
/// and paths out of it, and says something plain when there is nothing worth passing on.
pub(super) fn trouble(stderr: &str) -> String {
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
pub(super) fn looks_like_a_path(w: &str) -> bool {
    let w = w.trim_matches(|c: char| !c.is_alphanumeric());
    w.contains('/')
        || w.contains('\\')
        || w.rsplit_once('.')
            .is_some_and(|(_, ext)| (1..=5).contains(&ext.len()) && ext.chars().all(|c| c.is_ascii_alphanumeric()))
        || w.split_once(':').is_some_and(|(_, n)| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
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

pub(super) fn brief(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => format!("\"{s}\""),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Null => "nothing".into(),
        other => other.to_string(),
    }
}

#[tauri::command]
pub(super) fn answer_ask(studio: State<Studio>, id: u64, decision: Decision) -> Result<(), String> {
    let tx = studio
        .pending
        .lock()
        .unwrap()
        .remove(&id)
        .ok_or("that question has already been answered")?;
    tx.send(decision).map_err(|_| "the turn has ended".into())
}

#[tauri::command]
pub(super) fn stop_turn(studio: State<Studio>) {
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

/// The person asked the agent for something: a Tablua run on the open composition (`run.rs`).
/// The conversation so far is the run's sheet, not the history the chat sends, so that is unused.
#[tauri::command]
pub(super) fn ask_agent(
    app: AppHandle,
    variation: String,
    prompt: String,
    #[allow(unused_variables)] history: Vec<Said>,
    channel: Channel<serde_json::Value>,
) -> Result<(), String> {
    let comp = {
        let studio = app.state::<Studio>();
        let open = studio.open.lock().unwrap();
        open.get(&variation).map(|o| o.doc.path.clone()).ok_or("open a composition first")?
    };
    let name: String = variation.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let work = app.path().app_cache_dir().map_err(|e| e.to_string())?.join("runs").join(name);
    let when = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let cancel = Cancel::default();
    {
        let studio = app.state::<Studio>();
        *studio.turn.lock().unwrap() = Some(cancel.clone());
    }
    let after = app.clone();
    crate::run::start(
        crate::run::Ask { comp, work, prompt, todo: format!("ask-{when}") },
        channel,
        cancel,
        move || {
            *after.state::<Studio>().turn.lock().unwrap() = None;
        },
    )
}

// ----------------------------------------------------------------------------- the keys

#[tauri::command]
pub(super) fn set_key(name: String, value: String) -> Result<(), String> {
    secrets::set(&name, &value)
}

#[tauri::command]
pub(super) fn key_is_set(name: String) -> bool {
    secrets::resolve(&name).is_some()
}
