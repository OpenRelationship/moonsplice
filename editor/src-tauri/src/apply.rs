use super::*;

#[tauri::command]
pub(super) fn apply_edits(
    app: AppHandle,
    studio: State<Studio>,
    variation: String,
    edits: Vec<Edit>,
) -> Result<serde_json::Value, Refused> {
    let mut open = studio.open.lock().unwrap();
    let o = open.get_mut(&variation).ok_or_else(|| Refused {
        refused: true,
        why: "that composition is not open".into(),
        kind: EditRefusal::NoVerb {
            gesture: "change a composition that is not open".into(),
        },
    })?;
    let names = words::names(&o.outline);
    apply_now(&app, o, &variation, &edits).map_err(refusal(&names))
}

/// A refusal on its way to the corner of the window. `why` is the sentence a person reads, so
/// it goes through `say` and the names the timeline uses; `kind` keeps the structure, ids and
/// all, because that half is for the code.
pub(super) fn refusal(names: &std::collections::HashMap<String, String>) -> impl Fn(EditRefusal) -> Refused + '_ {
    move |r: EditRefusal| Refused {
        refused: true,
        why: r.say(names),
        kind: r,
    }
}

/// Read the composition back after it has been written to.
pub(super) fn reread(engine: &Engine, doc: &SourceDoc) -> Result<serde_json::Value, String> {
    engine.reload().map_err(|e| e.to_string())?;
    engine.outline(doc.hash()).map_err(|e| e.to_string())
}

/// Write the edits and have the engine read the result back.
///
/// The second half is the part worth naming. An edit is a write, so by the time the engine
/// refuses the composition the change is already on disk -- and a composition the app cannot
/// load is not a thing to leave a person holding. So the write is put back and the reason comes
/// out as a sentence. This is the one place both those decisions live, and it is out here rather
/// than inside the command so that it can be tested without a window.
pub fn write_and_reload(
    doc: &mut SourceDoc,
    engine: &Engine,
    edits: &[Edit],
    nodes: &[NodeRef],
    names: &HashMap<String, String>,
) -> Result<(source::Applied, serde_json::Value), EditRefusal> {
    let applied = doc.apply(edits, Some(nodes), names).map_err(|e| match e {
        source::SourceError::Refused(r) => r,
        other => EditRefusal::Conflict {
            detail: other.to_string(),
        },
    })?;
    match reread(engine, doc) {
        Ok(outline) => Ok((applied, outline)),
        Err(why) => {
            let _ = doc.undo();
            let _ = reread(engine, doc);
            Err(EditRefusal::Conflict {
                detail: unloadable(&why),
            })
        }
    }
}

/// Why a written composition could not be read back, said to the person who wrote it.
///
/// The one that happens in practice is the static duration: dragging a movement's right edge past
/// the end of the composition. `.robot/docs/design.robot` makes a composition's length fixed on purpose, so this
/// is a rule being enforced rather than a fault, and it should read like one.
pub(super) fn unloadable(why: &str) -> String {
    if why.contains("duration is static") {
        return "that would run past the end of the composition, and a composition's length is \
                fixed, so nothing was changed"
            .into();
    }
    let said = trouble(why);
    if said.is_empty() {
        "that left the composition unreadable, so nothing was changed".into()
    } else {
        format!("{said} — so nothing was changed")
    }
}

pub(super) fn apply_now(
    app: &AppHandle,
    o: &mut Open,
    variation: &str,
    edits: &[Edit],
) -> Result<serde_json::Value, EditRefusal> {
    let nodes = o.nodes.clone();
    let names = words::names(&o.outline);
    // The source changed, so the engine re-reads it. There is no delta to apply to a canvas:
    // a composition is a pure function of time and the preview re-seeks.
    let engine = o.engine.clone();
    let (applied, outline) = write_and_reload(&mut o.doc, &engine, edits, &nodes, &names)?;
    o.nodes = node_refs(&outline);
    o.outline = outline;
    o.media.clear();
    broadcast(app, variation, o, applied.what.clone());
    Ok(serde_json::json!({
        "hash": applied.hash,
        "what": applied.what,
        "undo": applied.undo_depth,
        "redo": applied.redo_depth,
    }))
}

#[tauri::command]
pub(super) async fn undo(app: AppHandle, variation: String) -> Result<String, String> {
    step_back_or_on(app, variation, true).await
}

#[tauri::command]
pub(super) async fn redo(app: AppHandle, variation: String) -> Result<String, String> {
    step_back_or_on(app, variation, false).await
}

pub(super) async fn step_back_or_on(app: AppHandle, variation: String, back: bool) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        step_history(&app, &studio, variation, back)
    })
    .await
    .map_err(|e| format!("that did not finish: {e}"))?
}

pub(super) fn step_history(
    app: &AppHandle,
    studio: &Studio,
    variation: String,
    back: bool,
) -> Result<String, String> {
    let mut open = studio.open.lock().unwrap();
    let o = open
        .get_mut(&variation)
        .ok_or("that composition is not open")?;
    let applied = if back { o.doc.undo() } else { o.doc.redo() }.map_err(|e| e.to_string())?;
    o.refresh_outline()?;
    broadcast(&app, &variation, o, applied.what.clone());
    Ok(applied.what.join("; "))
}
