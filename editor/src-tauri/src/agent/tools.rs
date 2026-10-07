use super::*;

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
pub(super) fn guard(cancel: &Cancel, f: impl FnOnce() -> Result<String, String>) -> Result<String, String> {
    if cancel.stopped() {
        return Err("the person stopped the run".into());
    }
    f()
}

/// `value | nil, message` — the one convention every port in Malleable follows.
pub(super) fn two(r: Result<String, String>) -> (Option<String>, Option<String>) {
    match r {
        Ok(v) => (Some(v), None),
        Err(e) => (None, Some(e)),
    }
}

pub(super) fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}
