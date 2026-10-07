use super::*;

/// One of the project's things by the name the person uses: where it is, relative to the
/// project, what kind it is, and its name.
pub(super) fn asset_rel(p: &Project, thing: &str) -> Result<(String, AssetKind, String), String> {
    let asset = asset_named(p, thing).ok_or_else(|| {
        let have: Vec<String> = p.view().assets.into_iter().map(|a| a.name).collect();
        format!(
            "there is nothing called {thing:?} in this project; it holds {}",
            if have.is_empty() { "nothing yet".to_string() } else { have.join(", ") }
        )
    })?;
    let path = p
        .asset_path(&asset.id)
        .ok_or("that is not one of this project's things")?;
    let rel = path
        .strip_prefix(&p.root)
        .unwrap_or(&path)
        .to_string_lossy()
        .to_string();
    Ok((rel, asset.kind, asset.name))
}

pub(crate) fn produce(
    p: &Project,
    o: &Open,
    tool: &str,
    args: &serde_json::Value,
) -> Result<Produced, String> {
    match tool {
        "transcript" => transcript(p, args).map(Produced::Said),
        "keep" => keep(p, o, args),
        "comp" => comp(args),
        "draw" => draw(p, o, args),
        "captions" => captions(p, o, args),
        other => Err(format!("there is no producer tool called {other:?}")),
    }
}

pub(super) fn num(v: &serde_json::Value, key: &str) -> Option<f64> {
    match &v[key] {
        serde_json::Value::Number(n) => n.as_f64(),
        serde_json::Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

pub(super) fn text(v: &serde_json::Value, key: &str) -> Option<String> {
    v[key].as_str().map(str::to_string).filter(|s| !s.trim().is_empty())
}

/// A field a model may have sent as an object or as a string of JSON (see `agent::loosen`).
pub(super) fn shape(v: &serde_json::Value, key: &str) -> serde_json::Value {
    match &v[key] {
        serde_json::Value::String(s) => serde_json::from_str(s).unwrap_or(serde_json::Value::Null),
        other => other.clone(),
    }
}

/// A length as a person says it: "3.4s" under a minute, "13:35" past one.
pub(super) fn secs(v: f64) -> String {
    if v < 60.0 {
        format!("{}s", r2(v))
    } else {
        let whole = v.round() as u64;
        format!("{}:{:02}", whole / 60, whole % 60)
    }
}

pub(super) fn r2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

pub(super) fn comp_size(o: &Open) -> (f64, f64, f64) {
    let c = &o.outline["comp"];
    (
        c["width"].as_f64().unwrap_or(1920.0),
        c["height"].as_f64().unwrap_or(1080.0),
        c["duration"].as_f64().unwrap_or(5.0),
    )
}

// ---------------------------------------------------------------------------------- media

/// What identifies a file's content cheaply: its length and the first and last mebibyte.
///
/// A whole-file hash of a 1.5 GB take is twenty seconds of reading to answer a question whose
/// answer almost never changes; a file that is edited in the middle and keeps its length and
/// both ends is not a thing a camera or an exporter makes.
pub fn media_key(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    use std::io::{Seek, SeekFrom};
    let mut f = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let len = f.metadata().map_err(|e| e.to_string())?.len();
    let mut h = Sha256::new();
    h.update(len.to_le_bytes());
    let mut buf = vec![0u8; 1 << 20];
    let n = f.read(&mut buf).map_err(|e| e.to_string())?;
    h.update(&buf[..n]);
    if len > (2 << 20) {
        f.seek(SeekFrom::End(-(1 << 20))).map_err(|e| e.to_string())?;
        let n = f.read(&mut buf).map_err(|e| e.to_string())?;
        h.update(&buf[..n]);
    }
    let digest = h.finalize();
    Ok(digest.iter().take(10).map(|b| format!("{b:02x}")).collect())
}

/// `~/.cache/moonsplice/<what>`, shared by every project on the machine: a transcript or a proxy of
/// the same take is the same whichever project asked for it.
pub fn shared_cache(what: &str) -> PathBuf {
    let base = std::env::var("MOONSPLICE_CACHE")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".cache/moonsplice")))
        .unwrap_or_else(|_| std::env::temp_dir().join("moonsplice-cache"));
    base.join(what)
}

/// How long a file is, by ffprobe.
pub fn media_duration(path: &Path) -> Result<f64, String> {
    let out = std::process::Command::new("ffprobe")
        .args(["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0"])
        .arg(path)
        .output()
        .map_err(|e| format!("ffprobe did not run ({e})"))?;
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse::<f64>()
        .map_err(|_| "could not tell how long that is".into())
}

/// `keep`: lay chosen stretches of a clip end to end. Each stretch becomes a piece of picture and
/// the matching piece of its sound, because a video in Moonsplice is silent -- the encode hears only
/// sound nodes (`core/runtime/main.lua`) -- and a talking head with no voice is no use to anybody.
pub(super) fn keep(p: &Project, o: &Open, args: &serde_json::Value) -> Result<Produced, String> {
    let thing = text(args, "thing").ok_or("say which clip to keep parts of")?;
    let (rel, kind, name) = asset_rel(p, &thing)?;
    if !matches!(kind, AssetKind::Footage | AssetKind::Audio) {
        return Err(format!("{name} is not footage or sound, so there is nothing to keep"));
    }
    let length = media_duration(&p.root.join(&rel))?;
    let ranges = match shape(args, "ranges") {
        serde_json::Value::Array(a) => a,
        _ => return Err("ranges are a list of [start, end] pairs, in seconds of the clip".into()),
    };
    let mut kept: Vec<(f64, f64)> = Vec::new();
    for (i, r) in ranges.iter().enumerate() {
        let pair = match r {
            serde_json::Value::Array(a) if a.len() == 2 => (a[0].as_f64(), a[1].as_f64()),
            serde_json::Value::Object(_) => (num(r, "start").or(num(r, "from")), num(r, "end").or(num(r, "to"))),
            _ => (None, None),
        };
        let (a, b) = match pair {
            (Some(a), Some(b)) => (a, b),
            _ => return Err(format!("range {} is not a [start, end] pair of seconds", i + 1)),
        };
        if !(b > a) || a < 0.0 {
            return Err(format!("range {} ({a}–{b}) does not run forwards from zero or later", i + 1));
        }
        if a >= length {
            return Err(format!(
                "range {} starts at {a}s, after {name} has ended ({}s long)",
                i + 1,
                r2(length)
            ));
        }
        kept.push((r2(a), r2(b.min(length))));
    }
    if kept.is_empty() {
        return Err("no ranges were given, so nothing was kept".into());
    }
    let mut sorted = kept.clone();
    sorted.sort_by(|x, y| x.0.partial_cmp(&y.0).unwrap());
    for w in sorted.windows(2) {
        if w[1].0 < w[0].1 - 0.01 {
            return Err(format!(
                "{}–{} and {}–{} overlap, so the same words would be heard twice",
                w[0].0, w[0].1, w[1].0, w[1].1
            ));
        }
    }

    let (cw, ch, cdur) = comp_size(o);
    let at0 = num(args, "at").unwrap_or(0.0).max(0.0);
    let sound = args["sound"].as_bool().unwrap_or(true);
    let picture = kind == AssetKind::Footage && args["picture"].as_bool().unwrap_or(true);
    let volume = num(args, "volume");
    let bx = shape(args, "box");
    let src = format!("\"{}\"", lower::escape_lua(&rel));

    let mut edits = Vec::new();
    let mut t = at0;
    let mut lines = Vec::new();
    for (i, (a, b)) in kept.iter().enumerate() {
        let d = r2(b - a);
        let label = format!("\"{} {}\"", lower::escape_lua(&name), i + 1);
        if picture {
            let mut fields = vec![
                ("src".to_string(), src.clone()),
                ("label".to_string(), label.clone()),
                ("from".to_string(), lower::fmt_num(r2(t))),
                ("duration".to_string(), lower::fmt_num(d)),
                ("media_start".to_string(), lower::fmt_num(*a)),
            ];
            for k in ["x", "y", "w", "h"] {
                if let Some(v) = num(&bx, k) {
                    fields.push((k.to_string(), lower::fmt_num(r2(v))));
                }
            }
            if bx["anchor"].is_string() {
                fields.push(("anchor".into(), format!("\"{}\"", lower::escape_lua(bx["anchor"].as_str().unwrap()))));
            }
            edits.push(Edit::Place {
                kind: "video".into(),
                fields,
                what: format!("{name} {}", i + 1),
            });
        }
        if sound {
            let mut fields = vec![
                ("src".to_string(), src.clone()),
                ("label".to_string(), format!("\"{} {} sound\"", lower::escape_lua(&name), i + 1)),
                ("at".to_string(), lower::fmt_num(r2(t))),
                ("duration".to_string(), lower::fmt_num(d)),
                ("media_start".to_string(), lower::fmt_num(*a)),
                // A cut in the middle of a waveform clicks; three hundredths of a second is
                // under anything a listener hears as a fade.
                ("fade_in".to_string(), "0.03".into()),
                ("fade_out".to_string(), "0.03".into()),
            ];
            if let Some(v) = volume {
                fields.push(("volume".into(), lower::fmt_num(v)));
            }
            edits.push(Edit::Place {
                kind: "audio".into(),
                fields,
                what: format!("{name} {} sound", i + 1),
            });
        }
        lines.push(format!("- {} {}: {}s–{}s of the piece, from {a}s–{b}s of {name}", name, i + 1, r2(t), r2(t + d)));
        t = r2(t + d);
    }
    let mut said = format!(
        "kept {} piece(s) of {name}, {} in all, laid end to end from {}s to {}s{}.",
        kept.len(),
        secs(t - at0),
        r2(at0),
        r2(t),
        if picture && bx.is_null() {
            format!(", filling the {cw}x{ch} frame")
        } else {
            String::new()
        }
    );
    if t > cdur {
        // The composition's length is fixed (.robot/docs/design.robot), and a piece that runs past it is cut
        // off at the encode without a word. Longer is what was meant; say so and do it.
        edits.insert(
            0,
            Edit::SetComp {
                width: None,
                height: None,
                duration: Some(r2(t)),
                fps: None,
                background: None,
            },
        );
        said.push_str(&format!(" The composition was {}s long, so it is now {}s.", r2(cdur), r2(t)));
    }
    said.push('\n');
    said.push_str(&lines.join("\n"));
    Ok(Produced::Edits(edits, said))
}

/// `comp`: the composition's own frame.
pub(super) fn comp(args: &serde_json::Value) -> Result<Produced, String> {
    let e = Edit::SetComp {
        width: num(args, "width").map(|v| v.round() as u32),
        height: num(args, "height").map(|v| v.round() as u32),
        duration: num(args, "duration").map(r2),
        fps: num(args, "fps"),
        background: text(args, "background"),
    };
    let said = e.describe(&HashMap::new());
    Ok(Produced::Edits(vec![e], said))
}
