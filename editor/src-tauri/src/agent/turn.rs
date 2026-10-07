use super::*;

/// A run in flight. Checked at the gate and inside every tool body, so a person can end a
/// turn without waiting for the model.
#[derive(Clone, Default)]
pub struct Cancel(pub(super) Arc<AtomicBool>);

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
