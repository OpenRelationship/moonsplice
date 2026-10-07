use super::*;

/// Where preview frames come from. The URL carries the source hash, so the webview's own
/// cache is correct for free and a changed composition is a different URL.
#[tauri::command]
pub(super) fn frame_base() -> String {
    if cfg!(target_os = "windows") || cfg!(target_os = "android") {
        "http://cframe.localhost/".into()
    } else {
        "cframe://localhost/".into()
    }
}

/// What playback is costing, per stage, over the last little while.
///
/// The window asks for this while it is playing, so that "the preview is choppy" can be answered
/// with which of the four steps is eating the budget rather than with a shrug. `budget_ms` is the
/// composition's own frame interval, and `why` is the one sentence worth showing a person.
#[derive(Debug, Clone, Serialize)]
pub(super) struct PlaybackReport {
    #[serde(flatten)]
    pub(super) stats: perf::PlaybackStats,
    /// Frames the picture is still waiting for. More than a couple means the app is asking for
    /// more than the renderer can make.
    pub(super) waiting: usize,
    pub(super) why: Option<String>,
}

#[tauri::command]
pub(super) fn playback(app: AppHandle, budget_ms: Option<f64>, window: Option<usize>) -> PlaybackReport {
    let studio = app.state::<Studio>();
    let budget = budget_ms.unwrap_or(1000.0 / 30.0);
    PlaybackReport {
        stats: studio.perf.stats(window.unwrap_or(120)),
        waiting: studio
            .frames
            .get()
            .map(|q| q.live_waiting())
            .unwrap_or(0),
        why: studio.perf.diagnosis(budget),
    }
}

/// What the window measured: how long a frame took to arrive and paint, and the frames it could
/// not paint in time. Reported in batches so one trace covers the whole path rather than stopping
/// at the process boundary.
#[tauri::command]
pub(super) fn report_playback(app: AppHandle, spans: Vec<perf::UiSpan>) {
    app.state::<Studio>().perf.record_ui(&spans);
}

/// Where an asset's own bytes come from. Same trick as `cframe`: the window is handed an id, and
/// Rust serves the file behind it, so nothing with a dot in it reaches the UI.
#[tauri::command]
pub(super) fn asset_base() -> String {
    if cfg!(target_os = "windows") || cfg!(target_os = "android") {
        "http://casset.localhost/".into()
    } else {
        "casset://localhost/".into()
    }
}

/// One asset, ready to look at. This is what a double-click in the left pane asks for, the way an
/// editor loads footage into its source viewer.
#[derive(Debug, Clone, Serialize)]
pub struct Source {
    pub id: String,
    pub name: String,
    pub kind: AssetKind,
    /// The URL the window points a picture or a player at.
    pub url: String,
    /// What it is, so the window shows it, plays it, or says plainly that it cannot.
    pub media: String,
}

#[tauri::command]
pub(super) fn asset_source(studio: State<Studio>, asset: String) -> Result<Source, String> {
    let guard = studio.project.lock().unwrap();
    let p = guard.as_ref().ok_or("no project is open")?;
    let path = p
        .asset_path(&asset)
        .ok_or("that is not one of this project's things")?;
    if !path.is_file() {
        return Err("that is not there any more".into());
    }
    let view = p
        .view()
        .assets
        .into_iter()
        .find(|a| a.id == asset)
        .ok_or("that is not one of this project's things")?;
    Ok(Source {
        url: format!("{}{}", asset_base(), view.id),
        id: view.id,
        name: view.name,
        kind: view.kind,
        media: project::media_type(&path).to_string(),
    })
}

/// One asset's bytes, or the slice of them a player asked for.
///
/// A webview plays video by asking for ranges, so this answers them; without that, seeking in a
/// clip does nothing and a long one may not start at all.
pub(super) fn serve_asset(
    app: &AppHandle,
    path: &str,
    range: Option<&str>,
) -> Result<(u16, Vec<u8>, String, Option<(u64, u64, u64)>), String> {
    let id = urldecode(path.trim_start_matches('/'));
    if id.is_empty() {
        return Err("no asset was asked for".into());
    }
    let studio = app.state::<Studio>();

    // `sound/<variation>/<node>` is the composition's own sound rather than the project's: the
    // narration a `tts` node generated has no entry in the project at all, and a clip somebody
    // dropped in is the same file under two names. The composition already knows where each one
    // is (`Engine::media`), and that is the map used here -- so the window plays a sound by the
    // name the timeline calls it, and still never learns a path.
    if let Some((variation, node)) = sound_asked_for(&id)? {
        let file = sound_path(&studio, &variation, &node)?;
        return read_slice(&file, range);
    }

    let file = {
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or("no project is open")?;
        p.asset_path(&id).ok_or("no such thing in this project")?
    };
    read_slice(&file, range)
}

/// `sound/<variation>/<node>`, taken apart. `None` for anything that is not one.
///
/// Its own function because it is the only parsing in the scheme handler and a scheme handler is
/// the one place in this app that a stranger's string could reach: a variation with a slash in
/// it, or an empty name, must come back as a refusal rather than as a path.
pub fn sound_asked_for(id: &str) -> Result<Option<(String, String)>, String> {
    let Some(rest) = id.strip_prefix("sound/") else {
        return Ok(None);
    };
    let (variation, node) = rest.split_once('/').ok_or("no sound was asked for")?;
    if variation.is_empty() || node.is_empty() || node.contains('/') {
        return Err("no sound was asked for".into());
    }
    Ok(Some((variation.to_string(), node.to_string())))
}

/// Where one of a composition's sounds is, asking the engine once and remembering.
pub(super) fn sound_path(studio: &Studio, variation: &str, node: &str) -> Result<PathBuf, String> {
    let (engine, known) = {
        let open = studio.open.lock().unwrap();
        let o = open.get(variation).ok_or("that composition is not open")?;
        (o.engine.clone(), o.media.get(node).cloned())
    };
    if let Some(p) = known {
        return Ok(p);
    }
    let media = engine.media().map_err(|e| e.to_string())?;
    let found = media.get(node).cloned();
    let mut open = studio.open.lock().unwrap();
    if let Some(o) = open.get_mut(variation) {
        o.media = media;
    }
    found.ok_or_else(|| "that is not a sound with a file behind it".into())
}

/// One file, or the slice of it a player asked for: `(status, bytes, what it is, the part)`.
pub fn read_slice(
    file: &Path,
    range: Option<&str>,
) -> Result<(u16, Vec<u8>, String, Option<(u64, u64, u64)>), String> {
    let media = project::media_type(file).to_string();
    let total = std::fs::metadata(file).map_err(|e| e.to_string())?.len();

    let Some(asked) = range.and_then(parse_range) else {
        let bytes = std::fs::read(file).map_err(|e| e.to_string())?;
        return Ok((200, bytes, media, None));
    };
    if total == 0 {
        return Ok((200, Vec::new(), media, None));
    }

    // At most this much in one answer. A player asking for "everything from here on" gets a
    // chunk and asks again, which is how a long clip starts playing without reading all of it.
    const CHUNK: u64 = 4 * 1024 * 1024;
    let start = asked.0.min(total - 1);
    let end = asked.1.unwrap_or(total - 1).min(total - 1).min(start + CHUNK - 1);
    let mut f = std::fs::File::open(file).map_err(|e| e.to_string())?;
    use std::io::{Read, Seek, SeekFrom};
    f.seek(SeekFrom::Start(start)).map_err(|e| e.to_string())?;
    let mut bytes = vec![0u8; (end - start + 1) as usize];
    f.read_exact(&mut bytes).map_err(|e| e.to_string())?;
    Ok((206, bytes, media, Some((start, end, total))))
}

/// `bytes=0-` or `bytes=1000-2000`. Anything else is no range at all.
pub(super) fn parse_range(header: &str) -> Option<(u64, Option<u64>)> {
    let spec = header.trim().strip_prefix("bytes=")?;
    let (a, b) = spec.split_once('-')?;
    let start: u64 = a.trim().parse().ok()?;
    let end = match b.trim() {
        "" => None,
        other => Some(other.parse().ok()?),
    };
    Some((start, end))
}

/// What a sound looks like, so a lane can draw it instead of a grey bar.
///
/// The peaks come back and the path does not. The window asks by the name the composition gave
/// the sound; the app looks the file up, reads it once, and keeps the shape — which is what lets
/// a ten minute edit with seventy sounds in it draw them all without reading anything twice.
#[tauri::command]
pub(super) async fn sound_shape(
    studio: State<'_, Studio>,
    variation: String,
    node: String,
) -> Result<Vec<u8>, String> {
    // The list of files is read once per composition and then only when the engine reloads,
    // because the answer changes exactly when the composition does.
    let path = sound_path(&studio, &variation, &node)?;
    // Off the async runtime: reading a sound waits on ffmpeg and on the four-at-a-time gate, and
    // seventy lanes all parked on that inside the runtime's own threads is a window that stops
    // answering anything at all.
    let shapes = studio.shapes.clone();
    tauri::async_runtime::spawn_blocking(move || shapes.of(&path).map(|p| p.as_ref().clone()))
        .await
        .map_err(|e| format!("the sound could not be read: {e}"))?
}

pub(super) fn urldecode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}
