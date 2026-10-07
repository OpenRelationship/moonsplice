use super::*;

/// How deep the pane will look. Deeper than anyone organises, shallow enough that opening a folder
/// with a checkout in it does not walk the whole thing.
pub(super) const MAX_DEPTH: usize = 6;

/// Directories that are not part of a project however they got there.
pub(super) fn skipped(name: &str) -> bool {
    name.starts_with('.')
        || matches!(name, "node_modules" | "target" | "dist" | "__pycache__" | "build")
}

/// The folder a file is in, relative to the project. `""` for one at the top.
pub fn folder_of(rel: &str) -> String {
    match rel.rsplit_once('/') {
        Some((dir, _)) => dir.to_string(),
        None => String::new(),
    }
}

/// The same file, in another folder.
pub(super) fn rehome(rel: &str, into: &str) -> String {
    let base = rel.rsplit_once('/').map(|(_, f)| f).unwrap_or(rel);
    if into.is_empty() {
        base.to_string()
    } else {
        format!("{into}/{base}")
    }
}

/// A folder path with nothing surprising in it: no leading slash, no `..`, no trailing slash.
pub(super) fn clean_folder(at: &str) -> String {
    at.split('/')
        .map(str::trim)
        .filter(|p| !p.is_empty() && *p != "." && *p != "..")
        .collect::<Vec<_>>()
        .join("/")
}

/// One folder name, as a directory can actually be called.
pub(super) fn folder_name(name: &str) -> String {
    name.trim()
        .chars()
        .filter(|c| !matches!(c, '/' | '\\' | ':' | '\0'))
        .collect::<String>()
        .trim_matches('.')
        .trim()
        .to_string()
}

/// A directory name as the pane says it. A folder a person named keeps their capitals and their
/// spaces; `my-footage` reads as "My footage" the same way everything else here does.
pub(super) fn humanise_folder(name: &str) -> String {
    if name.chars().any(|c| c == ' ' || c.is_uppercase()) {
        name.to_string()
    } else {
        humanise(name)
    }
}

/// A composition with nothing in it. Cheap enough to do on every listing, and it means the
/// UI never has to start an engine to find out whether to draw an empty state.
pub(super) fn looks_empty(path: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else {
        return true;
    };
    let ctor = regex::Regex::new(r"\bs\s*:\s*\w+\s*\{").unwrap();
    !ctor.is_match(&text)
}

/// Every composition in the project, wherever it is, relative to the root.
pub(super) fn comps_under(root: &Path, at: &str, depth: usize, out: &mut Vec<String>) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(rd) = std::fs::read_dir(root.join(at)) else {
        return;
    };
    for e in rd.flatten() {
        let Some(name) = e.file_name().to_str().map(str::to_string) else {
            continue;
        };
        let rel = if at.is_empty() {
            name.clone()
        } else {
            format!("{at}/{name}")
        };
        if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            if !skipped(&name) {
                comps_under(root, &rel, depth + 1, out);
            }
        } else if name.ends_with(".lua") {
            out.push(rel);
        }
    }
}

/// A file the project can use. Anything else in the folder -- a readme, a script, a stray
/// `.DS_Store` -- is somebody's business and not the app's.
pub(super) fn is_media(path: &Path) -> bool {
    !matches!(AssetKind::of(path), AssetKind::Other)
}

pub(super) fn walk(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    if depth > MAX_DEPTH {
        return;
    }
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            if p.is_dir() {
                if skipped(&name) {
                    continue;
                }
                walk(&p, out, depth + 1);
            } else if !p
                .file_name()
                .and_then(|s| s.to_str())
                .is_some_and(|n| n.starts_with('.'))
            {
                out.push(p);
            }
        }
    }
}

/// `width = 1280, height = 720` read off the text. Cheap, and wrong only for a comp that
/// computes its own size — in which case the engine corrects it the moment it opens.
pub fn declared_size(path: &Path) -> Option<(u32, u32)> {
    let text = std::fs::read_to_string(path).ok()?;
    let re = regex::Regex::new(r"width\s*=\s*(\d+)\s*,\s*height\s*=\s*(\d+)").unwrap();
    let c = re.captures(&text)?;
    Some((c[1].parse().ok()?, c[2].parse().ok()?))
}

pub(super) fn retarget(text: &str, w: u32, h: u32) -> String {
    let re = regex::Regex::new(r"width\s*=\s*\d+\s*,\s*height\s*=\s*\d+").unwrap();
    re.replace(text, format!("width = {w}, height = {h}").as_str())
        .to_string()
}

pub fn blank_comp(title: &str, w: u32, h: u32) -> String {
    format!(
        "-- {title}\nlocal e = require(\"moonsplice\")\n\nreturn e.comp {{\n  \
         width = {w}, height = {h}, duration = 5, fps = 30,\n  background = \"#0b0d12\",\n\n  \
         scene = function(s)\n  end,\n}}\n"
    )
}
