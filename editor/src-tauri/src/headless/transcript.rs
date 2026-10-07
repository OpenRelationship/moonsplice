use super::*;

/// What the project holds, in the words `project` answers with.
pub(crate) fn project_words(p: &Project) -> String {
    let view = p.view();
    if view.assets.is_empty() {
        return format!("{} holds no footage, pictures or sound yet.", view.name);
    }
    let mut out = format!("{} holds:", view.name);
    for a in view.assets {
        let kind = match a.kind {
            AssetKind::Footage => "a clip",
            AssetKind::Image => "a picture",
            AssetKind::Audio => "a sound",
            AssetKind::Font => "a typeface",
            AssetKind::Data => "some notes",
            AssetKind::Other => "a file of its own kind",
        };
        out.push_str(&format!("\n- {} — {kind}", a.name));
    }
    out.push_str("\n\nAny of the first three kinds can be put into the composition.");
    out
}

/// The words in a file, with their times. Cached in the project (`.moonsplice/transcripts/`) and on
/// the machine, so a fourteen minute take is listened to once.
pub fn words_of(root: &Path, path: &Path) -> Result<serde_json::Value, String> {
    let key = media_key(path)?;
    let local = root.join(".moonsplice/transcripts").join(format!("{key}.json"));
    let shared = shared_cache("transcripts").join(format!("{key}.json"));
    for p in [&local, &shared] {
        if let Ok(t) = std::fs::read_to_string(p) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&t) {
                if v["words"].is_array() {
                    if p == &shared {
                        let _ = std::fs::create_dir_all(local.parent().unwrap());
                        let _ = std::fs::write(&local, &t);
                    }
                    return Ok(v);
                }
            }
        }
    }
    let engine_root = engine::moonsplice_root().ok_or("the Moonsplice engine is not here")?;
    let out = std::process::Command::new(engine_root.join("bin/moonsplice-transcribe"))
        .arg(path)
        .output()
        .map_err(|e| format!("the transcriber did not start ({e})"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!(
            "the transcriber could not hear it: {}",
            err.lines().last().unwrap_or("no reason given")
        ));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("the transcript did not parse ({e})"))?;
    let text = v.to_string();
    for p in [&local, &shared] {
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        let _ = std::fs::write(p, &text);
    }
    Ok(v)
}

#[derive(Debug, Clone)]
pub struct Word {
    pub word: String,
    pub start: f64,
    pub end: f64,
}

pub(super) fn word_list(v: &serde_json::Value) -> Vec<Word> {
    v["words"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|w| {
                    Some(Word {
                        word: w["word"].as_str()?.trim().to_string(),
                        start: w["start"].as_f64()?,
                        end: w["end"].as_f64()?,
                    })
                })
                .filter(|w| !w.word.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// Words into phrases, at the pauses and the full stops: the unit somebody cutting a talking
/// head actually chooses between.
pub fn phrases(ws: &[Word], max_words: usize, gap: f64) -> Vec<(f64, f64, String)> {
    let mut out: Vec<(f64, f64, Vec<&str>)> = Vec::new();
    for (i, w) in ws.iter().enumerate() {
        let start_new = match out.last() {
            None => true,
            Some((_, end, said)) => {
                let prev = &ws[i - 1].word;
                w.start - end > gap
                    || said.len() >= max_words
                    || (said.len() >= 4 && prev.ends_with(['.', '?', '!']))
            }
        };
        if start_new {
            out.push((w.start, w.end, vec![w.word.as_str()]));
        } else {
            let last = out.last_mut().unwrap();
            last.1 = w.end;
            last.2.push(w.word.as_str());
        }
    }
    out.into_iter()
        .map(|(a, b, said)| (a, b, said.join(" ")))
        .collect()
}

/// `transcript`: what is said in a clip or a sound, a phrase a line, in the clip's own seconds.
pub(super) fn transcript(p: &Project, args: &serde_json::Value) -> Result<String, String> {
    let thing = text(args, "thing").ok_or("say which clip or sound to listen to")?;
    let (rel, kind, name) = asset_rel(p, &thing)?;
    if !matches!(kind, AssetKind::Footage | AssetKind::Audio) {
        return Err(format!("{name} has nothing to listen to"));
    }
    let path = p.root.join(&rel);
    let v = words_of(&p.root, &path)?;
    let ws = word_list(&v);
    let from = num(args, "from").unwrap_or(0.0);
    let to = num(args, "to").unwrap_or(f64::INFINITY);
    let picked: Vec<Word> = ws
        .into_iter()
        .filter(|w| w.end > from && w.start < to)
        .collect();
    let total = v["duration"].as_f64().unwrap_or(0.0);
    let mut out = format!(
        "{name}: {} long, {} words heard{}. Times are seconds in {name}'s own time -- what `keep` \
         takes. One phrase a line, broken at pauses.",
        secs(total),
        picked.len(),
        if from > 0.0 || to.is_finite() {
            format!(" between {}s and {}s", r2(from), if to.is_finite() { r2(to).to_string() } else { "the end".into() })
        } else {
            String::new()
        },
    );
    for (a, b, said) in phrases(&picked, 16, 0.55) {
        out.push_str(&format!("\n[{:.2}–{:.2}] {said}", a, b));
    }
    if picked.is_empty() {
        out.push_str("\nNothing is said there.");
    }
    Ok(out)
}
