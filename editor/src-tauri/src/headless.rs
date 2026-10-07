//! The app with no window: a project, one composition open in it, and every tool the agent has.
//!
//! `moonsplice agent` is the door. It exists because the agent was only reachable from inside
//! the app, and a thing that can only be driven by a person clicking is a thing nobody can
//! measure, script, or hand to another agent. So this is the same agent -- the same declaration,
//! the same tool bodies, the same lowering and the same engine -- with a terminal where the
//! window was.
//!
//! Two halves:
//!
//! - `Session`, the headless `AppBridge`. It owns what `Studio` owns for one composition: the
//!   project, the engine and the source. Every gesture goes down the road the window's goes
//!   down (`gesture_to_edits`, `place_edit`, `write_and_reload`), so there is no second
//!   implementation of a cut or a trim to drift from the first.
//! - The producer's tools -- `transcript`, `keep`, `comp`, `draw`, `captions` -- which turn
//!   footage into a piece rather than adjust a piece that exists. They are written here as
//!   functions of a project and an open composition, returning edits, so the window's `Bridge`
//!   and this one apply the very same edits.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use crate::agent::AppBridge;
use crate::engine::{self, Engine};
use crate::lower::{self, Edit};
use crate::project::{AssetKind, Project};
use crate::source::SourceDoc;
use crate::{
    asset_named, describe, describe_instant, gesture_to_edits, node_refs, place_edit,
    write_and_reload, words, Edge, Gesture, Open,
};

mod draw;
mod produce;
mod session;
mod transcript;

use draw::*;
pub use produce::*;
pub use session::*;
pub use transcript::*;

// ------------------------------------------------------------------------ the producer's tools

/// What a producer tool came back with: words to say, or edits to apply and words to say once
/// they have landed.
pub(crate) enum Produced {
    Said(String),
    Edits(Vec<Edit>, String),
}

// ------------------------------------------------------------------------------- a new project

/// What `init` made.
#[derive(Debug, serde::Serialize)]
pub struct Made {
    pub project: PathBuf,
    pub comp: String,
    pub comp_file: PathBuf,
    pub footage: Vec<serde_json::Value>,
}

/// Which way up a file says it is meant to be shown, from its display matrix. Phones store a
/// portrait take as landscape pixels and a rotation, and the renderer's decoder paints the
/// pixels.
pub fn rotation_of(path: &Path) -> i64 {
    let out = std::process::Command::new("ffprobe")
        .args([
            "-v", "error", "-select_streams", "v:0", "-show_entries",
            "stream_side_data=rotation", "-of", "csv=p=0",
        ])
        .arg(path)
        .output();
    out.ok()
        .and_then(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .find_map(|l| l.trim().trim_matches(',').parse::<f64>().ok())
        })
        .map(|r| r.round() as i64)
        .unwrap_or(0)
}

/// An upright copy of a take that is stored on its side, made once per machine.
///
/// The renderer's decoder reads the pixels as they are stored and ignores the rotation a phone
/// writes beside them, so an iPhone portrait take paints lying down. Teaching the decoder is
/// the right fix and a renderer change (goldens and all); until then the take is turned upright
/// once, here, on the hardware encoder, and the project uses the copy. The sound is copied, not
/// re-encoded, so a transcript of either is the same transcript.
pub fn upright(path: &Path) -> Result<PathBuf, String> {
    let key = media_key(path)?;
    let dir = shared_cache("upright");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let out = dir.join(format!("{key}.mp4"));
    if out.is_file() && media_duration(&out).is_ok() {
        return Ok(out);
    }
    let tmp = dir.join(format!("{key}.part.mp4"));
    let venc: &[&str] = if cfg!(target_os = "macos") {
        &["-c:v", "h264_videotoolbox", "-b:v", "10M"]
    } else {
        &["-c:v", "libx264", "-preset", "veryfast", "-crf", "18"]
    };
    let status = std::process::Command::new("ffmpeg")
        .args(["-v", "error", "-y", "-i"])
        .arg(path)
        .args(["-map", "0:v:0", "-map", "0:a:0?"])
        .args(venc)
        .args(["-pix_fmt", "yuv420p", "-c:a", "copy", "-movflags", "+faststart"])
        .arg(&tmp)
        .status()
        .map_err(|e| format!("ffmpeg did not start ({e})"))?;
    if !status.success() {
        let _ = std::fs::remove_file(&tmp);
        return Err("could not turn that take upright".into());
    }
    std::fs::rename(&tmp, &out).map_err(|e| e.to_string())?;
    Ok(out)
}

/// A project folder with footage in it and an empty composition, ready for an agent.
pub fn init(
    dir: &Path,
    footage: &[PathBuf],
    comp: &str,
    size: (u32, u32),
    fps: f64,
    duration: f64,
) -> Result<Made, String> {
    std::fs::create_dir_all(dir.join("Footage")).map_err(|e| format!("{}: {e}", dir.display()))?;
    let root = dir.canonicalize().map_err(|e| e.to_string())?;
    let mut made_footage = Vec::new();
    for f in footage {
        let f = f.canonicalize().map_err(|e| format!("{}: {e}", f.display()))?;
        let rot = rotation_of(&f);
        let stem = f.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "clip".into());
        let (target, name, note) = if rot % 360 != 0 {
            let up = upright(&f)?;
            (up, format!("{stem}.mp4"), Some(format!("stored turned {rot}°; the project uses an upright copy")))
        } else {
            (f.clone(), f.file_name().unwrap().to_string_lossy().to_string(), None)
        };
        let link = root.join("Footage").join(&name);
        let _ = std::fs::remove_file(&link);
        link_or_copy(&target, &link)?;
        made_footage.push(serde_json::json!({
            "source": f,
            "path": link.strip_prefix(&root).unwrap_or(&link),
            "upright_copy": note.is_some(),
            "note": note,
            "duration": media_duration(&target).ok(),
        }));
    }
    // Typefaces from the checkout, so writing can be set in something better than the default
    // and a composition outside the checkout can still find them.
    if let Some(engine_root) = engine::moonsplice_root() {
        let fonts = engine_root.join("comps/assets/fonts");
        if let Ok(rd) = std::fs::read_dir(&fonts) {
            let into = root.join("Fonts");
            let _ = std::fs::create_dir_all(&into);
            for e in rd.flatten() {
                let to = into.join(e.file_name());
                if !to.exists() {
                    let _ = link_or_copy(&e.path(), &to);
                }
            }
        }
    }
    let mut project = Project::open(&root).map_err(|e| e.to_string())?;
    let id = match pick_variation(&project, Some(comp)) {
        Ok(id) => id,
        Err(_) => project
            .add_composition(comp, size.0, size.1, "")
            .map_err(|e| e.to_string())?,
    };
    let file = project.source_of(&id).ok_or("the composition was not made")?;
    let text = std::fs::read_to_string(&file).map_err(|e| e.to_string())?;
    let text = lower::set_comp(&text, Some(size.0), Some(size.1), Some(duration), Some(fps), None)
        .map_err(|e| e.to_string())?;
    std::fs::write(&file, text).map_err(|e| e.to_string())?;
    Ok(Made {
        project: root,
        comp: id,
        comp_file: file,
        footage: made_footage,
    })
}

fn link_or_copy(from: &Path, to: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        if std::os::unix::fs::symlink(from, to).is_ok() {
            return Ok(());
        }
    }
    std::fs::copy(from, to)
        .map(|_| ())
        .map_err(|e| format!("{}: {e}", to.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(word: &str, start: f64, end: f64) -> Word {
        Word { word: word.into(), start, end }
    }

    #[test]
    fn phrases_break_at_pauses_and_full_stops() {
        let ws = vec![
            w("So", 0.0, 0.2),
            w("here", 0.25, 0.4),
            w("is", 0.45, 0.5),
            w("the", 0.55, 0.6),
            w("thing.", 0.65, 0.9),
            w("Next", 1.0, 1.2),
            w("one", 2.5, 2.7),
        ];
        let ph = phrases(&ws, 16, 0.55);
        assert_eq!(ph.len(), 3);
        assert_eq!(ph[0].2, "So here is the thing.");
        assert_eq!(ph[1].2, "Next");
        assert!((ph[2].0 - 2.5).abs() < 1e-9);
    }

    #[test]
    fn a_comp_frame_is_rewritten_in_the_head_only() {
        let src = "local e = require(\"moonsplice\")\nreturn e.comp {\n  width = 1280, height = 720, duration = 5, fps = 30,\n  scene = function(s)\n    s:rect { x = 0, width = 9 }\n  end,\n}\n";
        let out = lower::set_comp(src, Some(1920), Some(1080), Some(300.0), None, Some("#101010")).unwrap();
        assert!(out.contains("width = 1920, height = 1080, duration = 300"));
        assert!(out.contains("s:rect { x = 0, width = 9 }"));
        assert!(out.contains("background = \"#101010\""));
    }
}
