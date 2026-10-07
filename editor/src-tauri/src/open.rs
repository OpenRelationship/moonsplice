use super::*;

// -------------------------------------------------------------------------------- commands

#[derive(Debug, Clone, Serialize)]
pub struct Opened {
    pub variation: String,
    pub meta: EngineMeta,
    pub hash: String,
    pub outline: serde_json::Value,
}

/// Commands that wait for the renderer run off the main thread.
///
/// A synchronous Tauri command runs on the thread the window is drawn on. Every one of these
/// either starts a process, writes the file and has it re-read, or asks the renderer a question
/// -- hundreds of milliseconds at best, seconds on a long edit -- and for all of that time the
/// window is frozen and the pointer is a spinning wheel. The work is unchanged; what changes is
/// that the window keeps answering while it happens.
#[tauri::command]
pub(super) async fn open_project(app: AppHandle, path: String) -> Result<ProjectView, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        open_project_now(&app, &studio, path)
    })
    .await
    .map_err(|e| format!("opening that project did not finish: {e}"))?
}

pub(super) fn open_project_now(app: &AppHandle, studio: &Studio, path: String) -> Result<ProjectView, String> {
    let root = PathBuf::from(&path);
    if !root.is_dir() {
        return Err("that is not a folder".into());
    }
    let p = Project::open(&root).map_err(|e| e.to_string())?;
    let view = p.view();
    studio.open.lock().unwrap().clear();
    *studio.project.lock().unwrap() = Some(p);
    remember_path(&app, &root);
    watch(app.clone(), root);
    Ok(view)
}

/// The folder the app was last working in.
///
/// Reopening where you left off is the behaviour, and it is also what lets the app be started
/// straight into a project from a shell — `MOONSPLICE_PROJECT=… moonsplice-studio` — which is how the
/// screenshots and the manual passes are taken.
pub(super) fn remembered_path(app: &AppHandle) -> Option<PathBuf> {
    if let Ok(p) = std::env::var("MOONSPLICE_PROJECT") {
        let p = PathBuf::from(p);
        if p.is_dir() {
            return Some(p);
        }
    }
    let file = app.path().app_config_dir().ok()?.join("last-project");
    let text = std::fs::read_to_string(file).ok()?;
    let p = PathBuf::from(text.trim());
    p.is_dir().then_some(p)
}

/// At launch: open the remembered folder, if there is one and it still opens.
pub(super) fn reopen_remembered(handle: &AppHandle) {
    let Some(root) = remembered_path(handle) else { return };
    let Ok(p) = Project::open(&root) else { return };
    *handle.state::<Studio>().project.lock().unwrap() = Some(p);
    // Including when `MOONSPLICE_PROJECT` chose it. Opening a folder is opening a folder however
    // the app was told to; without this the next launch, with no environment set, went back to
    // the empty state -- which is how the remembering stayed unexercised for as long as it did.
    remember_path(handle, &root);
    watch(handle.clone(), root);
}

pub(super) fn remember_path(app: &AppHandle, root: &Path) {
    let Ok(dir) = app.path().app_config_dir() else { return };
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(dir.join("last-project"), root.to_string_lossy().as_bytes());
}

#[tauri::command]
pub(super) fn project(studio: State<Studio>) -> Result<ProjectView, String> {
    studio
        .project
        .lock()
        .unwrap()
        .as_ref()
        .map(|p| p.view())
        .ok_or_else(|| "no project is open".to_string())
}

/// Open a composition: start its renderer, read its outline, keep both.
///
/// Off the main thread, and that is not a detail. A synchronous Tauri command runs on the
/// thread the window is drawn on, so for as long as this takes -- starting a process, waiting
/// for it to read a ten minute edit and say hello -- nothing in the window moves and the
/// pointer turns into a spinning wheel. It was reported exactly that way: double-click a
/// composition, watch the rainbow wheel, and eventually it appears. The work is the same; what
/// changes is that the window keeps answering while it happens.
#[tauri::command]
pub(super) async fn open_variation(app: AppHandle, variation: String) -> Result<Opened, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        open_variation_now(&app, &studio, variation)
    })
    .await
    .map_err(|e| format!("opening that composition did not finish: {e}"))?
}

pub(super) fn open_variation_now(
    app: &AppHandle,
    studio: &Studio,
    variation: String,
) -> Result<Opened, String> {
    {
        let open = studio.open.lock().unwrap();
        if let Some(o) = open.get(&variation) {
            return Ok(Opened {
                variation,
                meta: o.engine.meta,
                hash: o.doc.hash().to_string(),
                outline: o.outline.clone(),
            });
        }
    }
    let (root, comp) = {
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or("no project is open")?;
        let c = p
            .source_of(&variation)
            .ok_or("that composition is not in this project")?;
        (p.root.clone(), c)
    };
    let doc = SourceDoc::open(&comp).map_err(|e| e.to_string())?;
    let dir = studio.serve_dir.join(&variation);
    let engine = Engine::start(&comp, &root, &dir).map_err(|e| e.to_string())?;
    let mut o = Open {
        engine: std::sync::Arc::new(engine),
        doc,
        outline: serde_json::Value::Null,
        nodes: Vec::new(),
        media: HashMap::new(),
        trouble: None,
    };
    let outline = o
        .engine
        .outline(o.doc.hash())
        .map_err(|e| e.to_string())?;
    o.nodes = node_refs(&outline);
    o.outline = outline;
    let opened = Opened {
        variation: variation.clone(),
        meta: o.engine.meta,
        hash: o.doc.hash().to_string(),
        outline: o.outline.clone(),
    };
    studio.open.lock().unwrap().insert(variation, o);
    let _ = app;
    Ok(opened)
}

#[tauri::command]
pub(super) fn close_variation(studio: State<Studio>, variation: String) {
    if let Some(o) = studio.open.lock().unwrap().remove(&variation) {
        studio.cache.forget(o.doc.hash());
        o.engine.stop();
    }
}
