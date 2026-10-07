use super::*;

#[tauri::command]
pub(super) fn add_composition(
    studio: State<Studio>,
    title: String,
    width: u32,
    height: u32,
    into: Option<String>,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.add_composition(&title, width, height, into.as_deref().unwrap_or(""))
        .map_err(|e| e.to_string())?;
    Ok(p.view())
}

/// A new folder in the project. It is a directory, so the pane and the folder say the same thing.
#[tauri::command]
pub(super) fn add_folder(
    app: AppHandle,
    studio: State<Studio>,
    parent: Option<String>,
    name: String,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.add_folder(parent.as_deref().unwrap_or(""), &name)
        .map_err(|e| e.to_string())?;
    let view = p.view();
    let _ = app.emit(event::PROJECT, view.clone());
    Ok(view)
}

/// Drag a thing into a folder. The file moves with it.
#[tauri::command]
pub(super) fn move_item(
    app: AppHandle,
    studio: State<Studio>,
    id: String,
    into: Option<String>,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.move_item(&id, into.as_deref().unwrap_or(""))
        .map_err(|e| e.to_string())?;
    let view = p.view();
    let _ = app.emit(event::PROJECT, view.clone());
    Ok(view)
}

#[tauri::command]
pub(super) fn rename_folder(
    app: AppHandle,
    studio: State<Studio>,
    at: String,
    name: String,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.rename_folder(&at, &name).map_err(|e| e.to_string())?;
    let view = p.view();
    let _ = app.emit(event::PROJECT, view.clone());
    Ok(view)
}

#[tauri::command]
pub(super) fn add_variation(
    studio: State<Studio>,
    composition: String,
    width: u32,
    height: u32,
) -> Result<ProjectView, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    p.add_variation(&composition, width, height)
        .map_err(|e| e.to_string())?;
    Ok(p.view())
}

#[tauri::command]
pub(super) fn add_assets(
    app: AppHandle,
    studio: State<Studio>,
    paths: Vec<String>,
    into: Option<String>,
) -> Result<Vec<AssetView>, String> {
    let mut guard = studio.project.lock().unwrap();
    let p = guard.as_mut().ok_or("no project is open")?;
    let into = into.unwrap_or_default();
    let mut out = Vec::new();
    for path in paths {
        let from = PathBuf::from(&path);
        if !from.is_file() {
            continue;
        }
        out.push(p.add_asset(&from, &into).map_err(|e| e.to_string())?);
    }
    let _ = app.emit(event::PROJECT, p.view());
    Ok(out)
}

/// Files dropped on the window. Tauri intercepts the webview's own drag and drop, so the paths
/// arrive here rather than in the DOM — which is just as well, because a browser `File` has no
/// path and the project needs one.
#[tauri::command]
pub(super) fn drop_paths(
    app: AppHandle,
    studio: State<Studio>,
    paths: Vec<String>,
    into: Option<String>,
) -> Result<Vec<AssetView>, String> {
    add_assets(app, studio, paths, into)
}
