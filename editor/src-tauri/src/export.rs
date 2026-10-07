use super::*;

/// Everything an export needs to know before anything renders. Read under the project lock and
/// then let go of it: a render takes seconds and the window must stay live.
#[derive(Debug, Clone)]
pub struct ExportPlan {
    /// The project directory, which is also the renderer's working directory. The one export bug
    /// that reached a person was here: a composition that names its fonts relative to the
    /// checkout renders to a 262-byte stub from anywhere else.
    pub root: PathBuf,
    /// The composition, relative to the project.
    pub rel: PathBuf,
    /// Where the video lands, absolute.
    pub out: PathBuf,
    /// And relative, which is what enters the project as an asset.
    pub into: String,
    /// What to call it out loud.
    pub title: String,
}

/// What to render, or why it cannot be.
pub fn plan_export(p: &Project, variation: &str) -> Result<ExportPlan, String> {
    let comp = p
        .source_of(variation)
        .ok_or("that composition is not in this project")?;
    let title = p
        .title_of(variation)
        .ok_or("that composition is not in this project")?;
    let out = p.root.join("exports").join(format!("{variation}.mp4"));
    std::fs::create_dir_all(out.parent().unwrap()).map_err(|e| e.to_string())?;
    Ok(ExportPlan {
        rel: comp.strip_prefix(&p.root).unwrap_or(&comp).to_path_buf(),
        into: out
            .strip_prefix(&p.root)
            .unwrap_or(&out)
            .to_string_lossy()
            .to_string(),
        out,
        root: p.root.clone(),
        title,
    })
}

/// Render it. `Err` is already a sentence for a person, not a traceback.
pub fn run_export(plan: &ExportPlan, quality: &str) -> Result<(), String> {
    let engine_root = engine::moonsplice_root().ok_or("the Moonsplice engine is not next to this app")?;
    // In this process, on a thread of its own, like the preview (engine.rs): the same runtime
    // `moonsplice render` runs, with the project as its working directory.
    let result = moonsplice_engine::Session::run(
        &engine_root.join("core").join("runtime"),
        vec![
            "--render".into(),
            plan.rel.display().to_string(),
            "-o".into(),
            plan.out.display().to_string(),
        ],
        vec![
            ("MOONSPLICE_CWD".into(), plan.root.display().to_string()),
            ("MOONSPLICE_HEADLESS".into(), "1".into()),
            ("MOONSPLICE_QUALITY".into(), quality.to_string()),
        ],
    );
    match result {
        Ok((0, _)) => Ok(()),
        Ok((_, said)) => Err(trouble(&said.join("\n"))),
        Err(_) => Err("the engine did not start".into()),
    }
}

#[tauri::command]
pub(super) async fn export(
    app: AppHandle,
    variation: String,
    quality: Option<String>,
) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let studio = app.state::<Studio>();
        export_now(app.clone(), &studio, variation, quality)
    })
    .await
    .map_err(|e| format!("the render did not finish: {e}"))?
}

pub(super) fn export_now(
    app: AppHandle,
    studio: &Studio,
    variation: String,
    quality: Option<String>,
) -> Result<String, String> {
    let plan = {
        let guard = studio.project.lock().unwrap();
        let p = guard.as_ref().ok_or("no project is open")?;
        plan_export(p, &variation)?
    };
    let quality = quality.unwrap_or_else(|| "standard".into());
    let name = variation.clone();
    let shown = plan.title.clone();
    let title = plan.title.clone();
    let project = studio.project.clone();
    std::thread::spawn(move || {
        let _ = app.emit(
            event::EXPORT,
            serde_json::json!({ "variation": name, "state": "running", "title": shown }),
        );
        let payload = match run_export(&plan, &quality) {
            Ok(()) => {
                // `app-shell` decided that an export's result enters the project. The left pane
                // is where a person looks for a finished video, and a path they never saw is no
                // answer to "where did it go".
                let mut guard = project.lock().unwrap();
                if let Some(p) = guard.as_mut() {
                    if p.add_export(&plan.into, &shown).is_ok() {
                        let _ = app.emit(event::PROJECT, p.view());
                    }
                }
                serde_json::json!({ "variation": name, "state": "done", "title": shown })
            }
            Err(why) => serde_json::json!({
                "variation": name, "state": "failed", "title": shown, "why": why,
            }),
        };
        let _ = app.emit(event::EXPORT, payload);
    });
    Ok(title)
}
