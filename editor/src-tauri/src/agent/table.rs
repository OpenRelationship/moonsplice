use super::*;

/// The chat surface speaks the AI SDK's roles; `turn.run` takes `user`, `agent` or `tool`.
/// Translated in one place, so neither side has to know about the other's word.
pub(super) fn malleable_role(role: &str) -> &'static str {
    match role {
        "assistant" | "agent" | "model" => "agent",
        "tool" => "tool",
        _ => "user",
    }
}

/// The app, as the table a tool body reaches it through: `c.moonsplice.outline()`,
/// `c.moonsplice.change(edits, why)` and the rest. Built the same way for a turn and for a single
/// call from the shell (`call_tool`), so the two cannot reach different apps.
pub(super) fn app_table(
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
pub(super) fn declared(paths: &Paths) -> Result<(Lua, mlua::Table), String> {
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
pub(super) fn set_declaration_dir(lua: &Lua, paths: &Paths) -> Result<(), String> {
    let dir = paths
        .declaration
        .parent()
        .map(|d| d.to_string_lossy().to_string())
        .unwrap_or_default();
    lua.globals().set("DECLARATION_DIR", dir).map_err(err)
}
