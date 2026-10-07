use super::*;

/// The edits that move everything after `from` by `delta`, or the reason nothing can.
///
/// A ripple is not a verb of its own. It is the same "set this to that" the inspector writes,
/// said of several things at once -- so it lowers through the path everything else lowers
/// through, undoes in one step, and there is still no eleventh verb.
///
/// Only one family moves: sound ripples sound, picture ripples picture. That is not a
/// simplification, it is the honest reading of what a person means. Closing a gap in narration
/// under a fixed picture is the commonest edit there is, and it would be wrong to slide the
/// pictures because a line was taken out of the voiceover.
pub(super) fn ripple(
    outline: &serde_json::Value,
    from: f64,
    delta: f64,
    sound: bool,
    except: &str,
) -> Result<Vec<Edit>, EditRefusal> {
    let names = words::names(outline);
    let whole = comp_duration(outline);
    let mut edits = Vec::new();
    for (id, span) in placed(outline) {
        if id == except || is_sound(outline, &id) != sound {
            continue;
        }
        // A note stays where it was put. It is about a moment in the edit rather than about the
        // clip that happens to be under it, and "the bit at four minutes is wrong" does not stop
        // being about four minutes because something earlier got shorter. Moving it silently
        // would be a guess about what somebody meant; leaving it is not a guess at all.
        if is_note(outline, &id) {
            continue;
        }
        if span.start < from - 1e-6 {
            continue;
        }
        if timed(outline, &id) {
            return Err(EditRefusal::Conflict {
                detail: format!(
                    "{} is moved by the timeline after that point, and closing the gap would \
                     leave the movement where it is -- take it out without closing the gap, or \
                     move what moves it first",
                    words::name_of(&names, &id)
                ),
            });
        }
        let now = round2(span.start + delta);
        if now < -1e-6 {
            return Err(EditRefusal::Conflict {
                detail: format!(
                    "that would put {} before the start of the composition",
                    words::name_of(&names, &id)
                ),
            });
        }
        if whole > 0.0 && now + span.duration > whole + 1e-6 {
            return Err(EditRefusal::Conflict {
                detail: format!(
                    "there is no room: {} would run past the end of a composition {}s long",
                    words::name_of(&names, &id),
                    crate::lower::fmt_num(whole)
                ),
            });
        }
        edits.push(Edit::SetProp {
            node: id,
            key: span.start_key.into(),
            value: serde_json::json!(now.max(0.0)),
        });
    }
    Ok(edits)
}

/// Does anything move `key` on `node` at all?
pub(super) fn moving_anywhere(outline: &serde_json::Value, node: &str, key: &str) -> bool {
    outline["tracks"]
        .as_array()
        .map(|tracks| {
            tracks.iter().any(|tr| {
                tr["node"].as_str() == Some(node)
                    && tr["prop"].as_str() == Some(key)
                    && tr["segments"]
                        .as_array()
                        .map(|segs| segs.iter().any(|s| !s["manual"].as_bool().unwrap_or(false)))
                        .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// Is a movement already deciding `key` on `node` at `t`? Read off the outline, which is the
/// only place that knows — and the reason `pin_prop` takes it as an argument rather than
/// guessing.
pub(super) fn moving_at(outline: &serde_json::Value, node: &str, key: &str, t: f64) -> bool {
    let Some(tracks) = outline["tracks"].as_array() else {
        return false;
    };
    tracks.iter().any(|tr| {
        tr["node"].as_str() == Some(node)
            && tr["prop"].as_str() == Some(key)
            && tr["segments"]
                .as_array()
                .map(|segs| {
                    segs.iter().any(|s| {
                        let t0 = s["t0"].as_f64().unwrap_or(0.0);
                        let t1 = s["t1"].as_f64().unwrap_or(0.0);
                        t1 > t0 && t >= t0 - 1e-6 && t <= t1 + 1e-6
                    })
                })
                .unwrap_or(false)
    })
}

#[derive(Debug, Clone, Serialize)]
pub struct Refused {
    pub refused: bool,
    pub why: String,
    pub kind: EditRefusal,
}

#[tauri::command]
pub(super) async fn apply_gesture(
    app: AppHandle,
    variation: String,
    gesture: Gesture,
) -> Result<serde_json::Value, Refused> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        apply_gesture_now(&app, &studio, variation, gesture)
    })
    .await
    .map_err(|e| Refused {
        refused: true,
        why: format!("that change did not finish: {e}"),
        kind: EditRefusal::NoVerb {
            gesture: "finish a change".into(),
        },
    })?
}

pub(super) fn apply_gesture_now(
    app: &AppHandle,
    studio: &Studio,
    variation: String,
    gesture: Gesture,
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
    let edits = gesture_to_edits(gesture, &o.outline).map_err(refusal(&names))?;
    apply_now(app, o, &variation, &edits).map_err(refusal(&names))
}

/// Put a thing from the project into the composition in front: a clip, a picture or a sound.
///
/// This is the gesture an editor is for, and it is the one the vocabulary could not express until
/// now — an asset could be dragged and nothing could take it. The decision about *what* a dropped
/// thing is (where it starts, what it is called) is made here, where the project is; the lowering
/// only writes the constructor.
#[tauri::command]
pub(super) async fn place_asset(
    app: AppHandle,
    variation: String,
    asset: String,
    t: Option<f64>,
) -> Result<serde_json::Value, Refused> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        place_asset_now(&app, &studio, variation, asset, t)
    })
    .await
    .map_err(|e| Refused {
        refused: true,
        why: format!("putting that in did not finish: {e}"),
        kind: EditRefusal::NoVerb {
            gesture: "put that in a composition".into(),
        },
    })?
}

pub(super) fn place_asset_now(
    app: &AppHandle,
    studio: &Studio,
    variation: String,
    asset: String,
    t: Option<f64>,
) -> Result<serde_json::Value, Refused> {
    let said = |why: &str| Refused {
        refused: true,
        why: why.to_string(),
        kind: EditRefusal::NoVerb {
            gesture: "put that in a composition".into(),
        },
    };
    let (rel, kind, name) = {
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or_else(|| said("no project is open"))?;
        let view = p
            .view()
            .assets
            .into_iter()
            .find(|a| a.id == asset)
            .ok_or_else(|| said("that is not one of this project's things"))?;
        let path = p
            .asset_path(&asset)
            .ok_or_else(|| said("that is not one of this project's things"))?;
        (
            path.strip_prefix(&p.root)
                .unwrap_or(&path)
                .to_string_lossy()
                .to_string(),
            view.kind,
            view.name,
        )
    };

    let edit = place_edit(&rel, kind, &name, t.unwrap_or(0.0)).map_err(|w| said(&w))?;

    let mut open = studio.open.lock().unwrap();
    let o = open
        .get_mut(&variation)
        .ok_or_else(|| said("that composition is not open"))?;
    let names = words::names(&o.outline);
    apply_now(&app, o, &variation, &[edit]).map_err(refusal(&names))
}

/// What a dropped thing becomes in the composition, or why it cannot become anything.
///
/// The decision lives here rather than in the lowering because it is about the project: a clip
/// starts where it was dropped, a picture fills the frame, a sound is heard from that moment, and
/// a typeface is not a thing you put in a composition at all.
pub(super) fn place_edit(rel: &str, kind: AssetKind, name: &str, t: f64) -> Result<Edit, String> {
    let at = round2(t.max(0.0));
    let src = lower::escape_lua(rel);
    let fields: Vec<(String, String)> = match kind {
        // A clip and a picture fill the frame by default, which is what the engine does with a
        // video or an image that says nothing about its size.
        AssetKind::Footage => vec![
            ("src".into(), format!("\"{src}\"")),
            ("from".into(), lower::fmt_num(at)),
        ],
        AssetKind::Image => vec![("src".into(), format!("\"{src}\""))],
        AssetKind::Audio => vec![
            ("src".into(), format!("\"{src}\"")),
            ("at".into(), lower::fmt_num(at)),
        ],
        AssetKind::Font => {
            return Err("type is something a piece of writing is set in, not something that \
                        goes in a composition on its own"
                .into())
        }
        AssetKind::Data | AssetKind::Other => {
            return Err("there is nothing to show or hear in that one".into())
        }
    };
    Ok(Edit::Place {
        kind: match kind {
            AssetKind::Footage => "video".into(),
            AssetKind::Image => "image".into(),
            _ => "audio".into(),
        },
        fields,
        what: name.to_string(),
    })
}
