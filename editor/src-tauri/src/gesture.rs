use super::*;

/// What every property actually is at one instant. The inspector shows these, and the preview
/// draws its handles from them — a thing you can grab has to be where the renderer put it.
#[tauri::command]
pub(super) async fn instant(
    app: AppHandle,
    variation: String,
    t: f64,
) -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        instant_now(&studio, variation, t)
    })
    .await
    .map_err(|e| format!("that did not finish: {e}"))?
}

pub(super) fn instant_now(studio: &Studio, variation: String, t: f64) -> Result<serde_json::Value, String> {
    let open = studio.open.lock().unwrap();
    let o = open
        .get(&variation)
        .ok_or("that composition is not open")?;
    o.engine.at(t).map_err(|e| e.to_string())
}

/// A gesture the UI made. Each one either maps to a lowering verb or is refused — there is
/// no third path, which is the whole of `project-sync`'s "no second edit path".
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "gesture", rename_all = "snake_case")]
pub enum Gesture {
    /// Dragging a thing in the preview.
    Move {
        node: String,
        x: f64,
        y: f64,
    },
    /// Typing a value in the inspector.
    SetValue {
        node: String,
        key: String,
        value: serde_json::Value,
    },
    /// Picking a curve for a movement.
    Curve {
        node: String,
        ease: String,
        #[serde(default)]
        occurrence: usize,
    },
    /// Dragging a movement's right edge.
    Lengthen {
        node: String,
        seconds: f64,
        #[serde(default)]
        occurrence: usize,
    },
    /// Dragging a spoken line, or retyping it.
    Line {
        node: String,
        index: usize,
        #[serde(default)]
        t0: Option<f64>,
        #[serde(default)]
        t1: Option<f64>,
        #[serde(default)]
        text: Option<String>,
    },
    /// Pinning a value by hand at a time.
    Pin {
        node: String,
        t: f64,
        key: String,
        value: serde_json::Value,
    },
    /// Taking a thing out, with the key a person reaches for.
    Remove { node: String },
    /// Dragging a clip or a sound along the timeline: it begins at `t` now.
    Slide { node: String, t: f64 },
    /// Dragging a clip's edge. `edge` is where the drag was: the front of it or the back.
    Trim {
        node: String,
        edge: Edge,
        t: f64,
    },
    /// The razor: cut a clip in two where the playhead is.
    Split { node: String, t: f64 },
    /// Dragging a movement's *left* edge: it begins at `t` now. Which movement, when a thing has
    /// several, is `occurrence` -- the same numbering the curve and the length take.
    MoveStart {
        node: String,
        t: f64,
        #[serde(default)]
        occurrence: usize,
    },
    /// Reordering things in the stack: `node` now paints over `over`. `None` sends it to the
    /// very back. On the timeline that is a lane dragged above or below another one.
    Restack {
        node: String,
        #[serde(default)]
        over: Option<String>,
    },
    /// Taking a thing out *and closing the hole it leaves*: everything of its own kind that
    /// came after it moves up by its length. The ripple every editor has, on the key every
    /// editor puts it on.
    TakeOutAndClose { node: String },
    /// Closing the empty stretch that follows `after`, without taking anything out. On the
    /// timeline it is the gap itself, clicked.
    CloseGap { after: String },
    /// Pinning a note to a moment. The one thing you put in a composition that is not in the
    /// picture and not in the mix.
    Mark { t: f64, text: String },
}

/// Which end of a clip a drag had hold of.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Edge {
    /// Where it starts playing from. Moving it changes when it begins *and* where in the
    /// footage it begins, which is what a person means by trimming the head off a shot.
    In,
    /// Where it stops. Only its length changes.
    Out,
}

/// What a thing with a length is: when it starts, how long it runs, and how far into its own
/// footage it begins. A clip says `from`; a sound says `at`; both say the other two.
pub(super) struct Span {
    pub(super) start_key: &'static str,
    pub(super) start: f64,
    pub(super) duration: f64,
    pub(super) media_start: f64,
}

/// The clip or sound `node` is, read off the outline. `None` for anything that has no length of
/// its own -- a rectangle is on screen whenever the composition says so, and there is nothing to
/// take hold of.
pub(super) fn span_of(outline: &serde_json::Value, node: &str) -> Option<Span> {
    let n = outline["nodes"]
        .as_array()?
        .iter()
        .find(|n| n["id"].as_str() == Some(node))?;
    let props = &n["props"];
    let num = |k: &str| props[k].as_f64();
    let start_key = if props.get("from").is_some() {
        "from"
    } else if props.get("at").is_some() {
        "at"
    } else {
        return None;
    };
    Some(Span {
        start_key,
        start: num(start_key).unwrap_or(0.0),
        duration: num("duration").unwrap_or(0.0),
        media_start: num("media_start").unwrap_or(0.0),
    })
}

/// One frame of the composition, or a thirtieth of a second if it does not say. The shortest a
/// clip is allowed to get: a clip of no length is a clip nobody can find again.
pub(super) fn one_frame(outline: &serde_json::Value) -> f64 {
    let fps = outline["comp"]["fps"].as_f64().unwrap_or(30.0);
    if fps > 0.0 {
        1.0 / fps
    } else {
        1.0 / 30.0
    }
}

pub(super) fn comp_duration(outline: &serde_json::Value) -> f64 {
    outline["comp"]["duration"].as_f64().unwrap_or(0.0)
}

/// When a thing's `occurrence`-th movement begins, as the engine measured it.
///
/// The numbering is the outline's own: every movement of that thing, across every property, in
/// the order the timeline draws them. That is what the curve and the length already take, so a
/// drag on a bar means the same movement to all three.
pub(super) fn tween_start(outline: &serde_json::Value, node: &str, occurrence: usize) -> Option<f64> {
    let mut starts: Vec<f64> = Vec::new();
    for track in outline["tracks"].as_array()? {
        if track["node"].as_str() != Some(node) {
            continue;
        }
        for seg in track["segments"].as_array()? {
            if seg["kind"] == "tween" && seg["manual"] != true {
                starts.push(seg["t0"].as_f64()?);
            }
        }
    }
    starts.sort_by(|a, b| a.partial_cmp(b).unwrap());
    starts.get(occurrence).copied()
}

/// A note pinned to a moment: in the edit, in neither the picture nor the mix.
pub(super) fn is_note(outline: &serde_json::Value, node: &str) -> bool {
    outline["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .any(|n| n["id"].as_str() == Some(node) && n["kind"].as_str() == Some("marker"))
        })
        .unwrap_or(false)
}

/// Sound, as the composition reports it: a kind the mix owns rather than the picture.
pub(super) fn is_sound(outline: &serde_json::Value, node: &str) -> bool {
    outline["nodes"]
        .as_array()
        .and_then(|ns| ns.iter().find(|n| n["id"].as_str() == Some(node)))
        .and_then(|n| n["kind"].as_str())
        .is_some_and(|k| matches!(k, "audio" | "tts" | "sfx" | "music"))
}

/// A refusal for a thing that has no length to take hold of.
pub(super) fn not_a_clip(outline: &serde_json::Value, node: &str) -> EditRefusal {
    let who = words::name_of(&words::names(outline), node);
    EditRefusal::Conflict {
        detail: format!(
            "{who} has no length of its own to drag -- it is on screen for as long as the \
             composition says, so what moves it is a movement"
        ),
    }
}
