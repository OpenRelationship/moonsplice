use super::*;

pub(super) const DRAWABLE: &[&str] = &["text", "rect", "circle", "image", "surface"];

/// Keys a drawn thing may be given. The rest of what the renderer knows is reachable by writing
/// a composition by hand; this is the part a model gets right without reading the renderer.
pub(super) const DRAW_KEYS: &[&str] = &[
    "x", "y", "w", "h", "r", "rx", "text", "size", "color", "font", "anchor", "wrap", "leading",
    "align", "tracking", "opacity", "rotation", "scale", "src", "fit", "stroke", "stroke_width",
    "shadow", "blend", "weight",
];

/// `draw`: a title card, a label, a block, a picture -- on for a stretch, with a way in and a way
/// out. The block of Lua is written here, from these arguments and nothing else.
pub(super) fn draw(p: &Project, o: &Open, args: &serde_json::Value) -> Result<Produced, String> {
    let kind = text(args, "kind").ok_or("say what kind of thing to draw: text, rect, circle or image")?;
    if !DRAWABLE.contains(&kind.as_str()) {
        return Err(format!("{kind} is not something draw makes; it makes {}", DRAWABLE.join(", ")));
    }
    let what = text(args, "what").unwrap_or_else(|| kind.clone());
    let props = shape(args, "props");
    let props = props.as_object().cloned().unwrap_or_default();
    let (_, _, cdur) = comp_size(o);
    let from = num(args, "from").unwrap_or(0.0).max(0.0);
    let to = num(args, "to").unwrap_or(cdur).min(cdur);
    if !(to > from) {
        return Err(format!(
            "it would be on screen from {from}s to {to}s, which is no time at all (the composition is {}s long)",
            r2(cdur)
        ));
    }
    let span = to - from;
    let enter = text(args, "enter").unwrap_or_else(|| "fade".into());
    let exit = text(args, "exit").unwrap_or_else(|| "fade".into());
    let over = num(args, "over").unwrap_or(0.45).clamp(0.05, 3.0).min(span / 2.0);

    let mut fields: Vec<(String, String)> = Vec::new();
    let mut target_opacity = 1.0;
    let mut y = None;
    let mut w = None;
    let mut scale = 1.0;
    for (k, v) in &props {
        if !DRAW_KEYS.contains(&k.as_str()) {
            return Err(format!(
                "{k} is not something draw can set; it sets {}",
                DRAW_KEYS.join(", ")
            ));
        }
        let lit = match (k.as_str(), v) {
            ("font", serde_json::Value::String(f)) => {
                let (rel, fkind, _) = asset_rel(p, f)?;
                if fkind != AssetKind::Font {
                    return Err(format!("{f} is not a typeface"));
                }
                format!("\"{}\"", lower::escape_lua(&rel))
            }
            ("src", serde_json::Value::String(f)) => {
                let (rel, fkind, _) = asset_rel(p, f)?;
                if fkind != AssetKind::Image {
                    return Err(format!("{f} is not a picture"));
                }
                format!("\"{}\"", lower::escape_lua(&rel))
            }
            ("shadow", serde_json::Value::Object(_)) | ("stroke", serde_json::Value::Object(_)) => {
                lua_table(v).ok_or_else(|| format!("{k} has something in it that is not a number or a word"))?
            }
            _ => lower::lua_literal(v)
                .ok_or_else(|| format!("{k} should be a number, a word or a switch"))?,
        };
        match k.as_str() {
            "opacity" => {
                target_opacity = v.as_f64().unwrap_or(1.0);
                continue;
            }
            "y" => y = v.as_f64(),
            "w" => w = v.as_f64(),
            "scale" => scale = v.as_f64().unwrap_or(1.0),
            _ => {}
        }
        fields.push((k.clone(), lit));
    }
    if kind == "image" && !props.contains_key("src") {
        return Err("a picture needs src: the name of one of the project's pictures".into());
    }
    if kind == "text" && !props.contains_key("text") {
        return Err("writing needs text".into());
    }
    fields.push(("label".into(), format!("\"{}\"", lower::escape_lua(&what))));

    // Where it starts from, for the way in.
    let mut start = vec![("opacity".to_string(), "0".to_string())];
    let mut arrive = vec![("opacity".to_string(), lower::fmt_num(target_opacity))];
    match enter.as_str() {
        "none" | "cut" | "fade" => {}
        "rise" => {
            let y = y.ok_or("rise needs a y to rise to")?;
            start.push(("y".into(), lower::fmt_num(r2(y + 36.0))));
            arrive.push(("y".into(), lower::fmt_num(y)));
        }
        "pop" => {
            start.push(("scale".into(), lower::fmt_num(r2(scale * 0.82))));
            arrive.push(("scale".into(), lower::fmt_num(scale)));
        }
        "wipe" => {
            let w = w.ok_or("wipe needs a w to grow to")?;
            start.push(("w".into(), "0".into()));
            arrive.push(("w".into(), lower::fmt_num(w)));
        }
        "type" => {
            if kind != "text" {
                return Err("only writing can be typed on".into());
            }
            start.push(("reveal".into(), "0".into()));
            arrive.push(("reveal".into(), "1".into()));
        }
        other => {
            return Err(format!(
                "{other} is not a way in; there is fade, rise, pop, wipe, type and none"
            ))
        }
    }
    for (k, v) in &start {
        if let Some(f) = fields.iter_mut().find(|(fk, _)| fk == k) {
            f.1 = v.clone();
        } else {
            fields.push((k.clone(), v.clone()));
        }
    }
    let leave: Vec<(String, String)> = match exit.as_str() {
        "none" | "cut" | "fade" => vec![("opacity".into(), "0".into())],
        "drop" => {
            let mut v = vec![("opacity".to_string(), "0".to_string())];
            if let Some(y) = y {
                v.push(("y".into(), lower::fmt_num(r2(y + 24.0))));
            }
            v
        }
        other => return Err(format!("{other} is not a way out; there is fade, drop and none")),
    };
    let table = |kv: &[(String, String)]| {
        kv.iter()
            .map(|(k, v)| format!("{k} = {v}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let cut_in = matches!(enter.as_str(), "none" | "cut");
    let cut_out = matches!(exit.as_str(), "none" | "cut") || to >= cdur - 1e-6;
    let mut script = vec![format!("    t:at({})", lower::fmt_num(r2(from)))];
    if cut_in {
        script.push(format!("    t:set(n, {{ {} }})", table(&arrive)));
    } else {
        let ease = if enter == "pop" { "backOut" } else if enter == "type" { "linear" } else { "expoOut" };
        let dur = if enter == "type" { (span * 0.5).min(0.04 * props.get("text").and_then(|t| t.as_str()).map(|t| t.len() as f64).unwrap_or(20.0)).max(over) } else { over };
        script.push(format!("    t:tween(n, {}, {{ {} }}, \"{ease}\")", lower::fmt_num(r2(dur)), table(&arrive)));
    }
    if !(to >= cdur - 1e-6 && exit != "none") || !cut_out {
        if cut_out {
            script.push(format!("    t:at({})", lower::fmt_num(r2(to))));
            script.push(format!("    t:set(n, {{ {} }})", table(&leave)));
        } else {
            script.push(format!("    t:at({})", lower::fmt_num(r2(to - over))));
            script.push(format!("    t:tween(n, {}, {{ {} }}, \"sineIn\")", lower::fmt_num(r2(over)), table(&leave)));
        }
    }
    let lua = format!(
        "do -- {}\n  local n = s:{kind} {{ {} }}\n  s:script(function(t)\n{}\n  end)\nend\n",
        what.replace('\n', " "),
        table(&fields),
        script.join("\n").replace("\n    ", "\n    "),
    );
    let said = format!(
        "drew {what}: on from {}s to {}s, in by {enter}, out by {exit}",
        r2(from),
        r2(to)
    );
    Ok(Produced::Edits(vec![Edit::Insert { lua, what }], said))
}

/// A flat JSON object as a Lua table literal, or `None` if anything in it is not a plain value.
pub(super) fn lua_table(v: &serde_json::Value) -> Option<String> {
    let o = v.as_object()?;
    let mut parts = Vec::new();
    for (k, v) in o {
        if !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            return None;
        }
        parts.push(format!("{k} = {}", lower::lua_literal(v)?));
    }
    Some(format!("{{ {} }}", parts.join(", ")))
}

/// `captions`: the words of a clip, on screen while they are heard, wherever its pieces landed.
///
/// Read off the composition as it stands -- which stretches of the clip are where -- so captions
/// made after `keep`, a trim or a cut follow the edit rather than the raw take.
pub(super) fn captions(p: &Project, o: &Open, args: &serde_json::Value) -> Result<Produced, String> {
    let thing = text(args, "thing").ok_or("say whose words to caption")?;
    let (rel, _, name) = asset_rel(p, &thing)?;
    let file = p.root.join(&rel);
    let want = file.canonicalize().unwrap_or(file.clone());
    let media = o.engine.media().map_err(|e| e.to_string())?;
    let is_it = |id: &str| {
        media
            .get(id)
            .map(|f| {
                let f = if f.is_absolute() { f.clone() } else { p.root.join(f) };
                f.canonicalize().unwrap_or(f) == want
            })
            .unwrap_or(false)
    };
    // Where each heard stretch of it sits: (composition time, clip time, length).
    let mut pieces: Vec<(f64, f64, f64)> = Vec::new();
    for a in o.outline["audio"].as_array().cloned().unwrap_or_default() {
        if is_it(a["id"].as_str().unwrap_or("")) {
            pieces.push((
                a["at"].as_f64().unwrap_or(0.0),
                a["media_start"].as_f64().unwrap_or(0.0),
                a["duration"].as_f64().unwrap_or(0.0),
            ));
        }
    }
    if pieces.is_empty() {
        return Err(format!(
            "none of {name} is heard in the composition yet, so there is nothing to caption (keep some of it first)"
        ));
    }
    pieces.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
    let ws = word_list(&words_of(&p.root, &file)?);
    let per = num(args, "words").unwrap_or(5.0).clamp(1.0, 14.0) as usize;
    let mut cues: Vec<(f64, f64, String)> = Vec::new();
    for (at, ms, d) in &pieces {
        let inside: Vec<Word> = ws
            .iter()
            .filter(|w| w.start >= ms - 0.05 && w.end <= ms + d + 0.08)
            .map(|w| Word {
                word: w.word.clone(),
                start: at + (w.start - ms).max(0.0),
                end: (at + (w.end - ms)).min(at + d),
            })
            .collect();
        let ph = phrases(&inside, per, 0.45);
        for (i, (a, b, said)) in ph.iter().enumerate() {
            let next = ph.get(i + 1).map(|n| n.0).unwrap_or(at + d);
            let end = (b + 0.35).min(next).min(at + d);
            cues.push((r2(*a), r2(end.max(a + 0.2)), said.clone()));
        }
    }
    if cues.is_empty() {
        return Err(format!("nothing is said in the parts of {name} that are heard"));
    }
    let (cw, ch, _) = comp_size(o);
    let style = shape(args, "style");
    let mut fields: Vec<(String, String)> = vec![
        ("x".into(), lower::fmt_num(num(&style, "x").unwrap_or(cw / 2.0).round())),
        ("y".into(), lower::fmt_num(num(&style, "y").unwrap_or((ch * 0.86).round()))),
        ("size".into(), lower::fmt_num(num(&style, "size").unwrap_or((ch * 0.042).round()))),
        ("color".into(), format!("\"{}\"", lower::escape_lua(&text(&style, "color").unwrap_or_else(|| "#ffffff".into())))),
        ("anchor".into(), format!("\"{}\"", lower::escape_lua(&text(&style, "anchor").unwrap_or_else(|| "center".into())))),
        ("label".into(), format!("\"{} captions\"", lower::escape_lua(&name))),
    ];
    if let Some(f) = text(&style, "font") {
        let (frel, fkind, _) = asset_rel(p, &f)?;
        if fkind != AssetKind::Font {
            return Err(format!("{f} is not a typeface"));
        }
        fields.push(("font".into(), format!("\"{}\"", lower::escape_lua(&frel))));
    }
    if let Some(sh) = style.get("shadow").filter(|v| v.is_object()).and_then(lua_table) {
        fields.push(("shadow".into(), sh));
    }
    let lit = cues
        .iter()
        .map(|(a, b, t)| format!("{{ {}, {}, \"{}\" }}", lower::fmt_num(*a), lower::fmt_num(*b), lower::escape_lua(t)))
        .collect::<Vec<_>>()
        .join(", ");
    fields.push(("cues".into(), format!("{{ {lit} }}")));
    let said = format!(
        "captioned {name}: {} lines over {} piece(s), from {}s to {}s",
        cues.len(),
        pieces.len(),
        cues.first().map(|c| c.0).unwrap_or(0.0),
        cues.last().map(|c| c.1).unwrap_or(0.0)
    );
    Ok(Produced::Edits(
        vec![Edit::Place {
            kind: "captions".into(),
            fields,
            what: format!("{name} captions"),
        }],
        said,
    ))
}
