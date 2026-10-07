use super::*;

/// The whole statement a constructor sits in: from the start of its line, past any `local x =`,
/// to the end of the line its closing brace is on.
pub(super) fn statement(src: &str, start: usize, end: usize) -> (usize, usize) {
    let a = src[..start].rfind('\n').map(|k| k + 1).unwrap_or(0);
    let b = src[end..].find('\n').map(|k| end + k + 1).unwrap_or(src.len());
    (a, b)
}

/// Cut a clip in two where the playhead is. The razor.
///
/// What comes out is the same clip twice. The first half keeps the name it had and stops at the
/// cut; the second starts there, and starts exactly that much further into its own footage, so
/// the picture does not jump across the join. That second half is written as the statement
/// immediately after the first — appending it at the end of the scene, which is what `place`
/// does for a clip somebody drops in, would put it in front of everything drawn since.
///
/// It is a source rewrite rather than a remove and two places because the half that is made has
/// to carry everything the original was written with, and most of that never reaches the window:
/// a clip's `src` is a path, and no path is ever handed to the side that makes gestures.
pub fn split(src: &str, node: &str, at: f64, nodes: Option<&[NodeRef]>) -> EditResult<String> {
    let layout = Layout::read(src, nodes)?;
    let sp = layout.span(node)?;
    let body = &src[sp.start..sp.end];

    let start_key = if field(body, "from").is_some() {
        "from"
    } else if field(body, "at").is_some() {
        "at"
    } else {
        return Err(EditRefusal::Conflict {
            detail: "that has no length of its own to cut -- it is on screen for as long as the \
                     composition is".into(),
        });
    };
    let read = |k: &str| field(body, k).and_then(|v| v.parse::<f64>().ok());
    let from = read(start_key).ok_or_else(|| EditRefusal::NotALiteral {
        what: "where that clip starts".into(),
    })?;
    let duration = read("duration").ok_or_else(|| EditRefusal::NotALiteral {
        what: "how long that clip runs".into(),
    })?;
    let media_start = match field(body, "media_start") {
        Some(v) => Some(v.parse::<f64>().map_err(|_| EditRefusal::NotALiteral {
            what: "where that clip starts in its own footage".into(),
        })?),
        None => None,
    };
    let end = from + duration;
    if at <= from || at >= end {
        return Err(EditRefusal::Conflict {
            detail: format!(
                "the cut has to fall inside the clip, and that one runs from {}s to {}s",
                fmt_num(from),
                fmt_num(end)
            ),
        });
    }

    // Where the statement that made it begins and ends. The call has to be on the same line as
    // the `{` it opens -- which is how every composition is written -- because the copy is made
    // by repeating that call, and a call that is not there cannot be repeated.
    let line_start = src[..sp.start].rfind('\n').map(|k| k + 1).unwrap_or(0);
    let head = &src[line_start..sp.start];
    let indent: String = head.chars().take_while(|c| *c == ' ' || *c == '\t').collect();
    let call = Regex::new(r"^\s*(?:local\s+\w+\s*=\s*)?([A-Za-z_]\w*\s*:\s*[A-Za-z_]\w*)\s*$")
        .unwrap()
        .captures(head)
        .map(|c| c[1].trim().to_string())
        .ok_or_else(|| EditRefusal::Unplaceable {
            node: node.to_string(),
        })?;
    let line_end = src[sp.end..]
        .find('\n')
        .map(|k| sp.end + k + 1)
        .unwrap_or(src.len());
    if !src[sp.end..line_end].trim().is_empty() {
        return Err(EditRefusal::Conflict {
            detail: "that clip shares its line with something else, so a second one cannot be \
                     written under it".into(),
        });
    }

    // The half that stays: same everything, stopping at the cut.
    let head_body = set_field(body, "duration", &fmt_num(round2(at - from))).ok_or_else(|| {
        EditRefusal::NotALiteral {
            what: "how long that clip runs".into(),
        }
    })?;

    // The half that is made: starting at the cut, and that much further into its footage. Its
    // `id`, if it was given one by hand, goes -- two things cannot be the same thing.
    let mut tail = body.to_string();
    tail = set_field(&tail, start_key, &fmt_num(round2(at))).unwrap_or(tail);
    tail = set_field(&tail, "duration", &fmt_num(round2(end - at))).unwrap_or(tail);
    let into = round2(media_start.unwrap_or(0.0) + (at - from));
    tail = match set_field(&tail, "media_start", &fmt_num(into)) {
        Some(t) => t,
        None => format!("{{ media_start = {},{}", fmt_num(into), &tail[1..]),
    };
    if let Some((f, t)) = field_span(&tail, "id") {
        let mut cut = tail.clone();
        // Back to the key, and forward past the comma that ended the value.
        let key_at = cut[..f].rfind("id").unwrap_or(f);
        let after = cut[t..].find(',').map(|k| t + k + 1).unwrap_or(t);
        cut.replace_range(key_at..after, "");
        tail = cut;
    }

    // The line that was there, with its length changed, and the new one under it.
    Ok(format!(
        "{}{head}{head_body}{}{indent}{call} {tail}\n{}",
        &src[..line_start],
        &src[sp.end..line_end],
        &src[line_end..]
    ))
}

pub(super) fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// Put a thing in a composition: a clip, a picture or a sound.
///
/// It goes in as the last statement of the scene, which is the front of the picture — the same
/// place a clip dropped on the top of a stack lands in any editor. `fields` are already Lua
/// literals, because deciding what a dropped clip *is* (where it starts, how long it runs, what
/// it is called) belongs to the side that holds the project, not to a span rewrite.
pub fn place(src: &str, kind: &str, fields: &[(String, String)]) -> EditResult<String> {
    let scene = Regex::new(r"scene\s*=\s*function\s*\(\s*(\w+)\s*\)").unwrap();
    let found = scene.captures(src).ok_or(EditRefusal::NoVerb {
        gesture: "put something in a composition that has no scene in it".into(),
    })?;
    let whole = found.get(0).expect("the match");
    let var = found.get(1).expect("the scene's own name").as_str().to_string();
    let body_end = find_function_end(src, whole.end()).ok_or(EditRefusal::NotALiteral {
        what: "the scene".into(),
    })?;
    let written = fields
        .iter()
        .map(|(k, v)| format!("{k} = {v}"))
        .collect::<Vec<_>>()
        .join(", ");
    // `find_function_end` gives the start of the line the `end` sits on, so the statement goes in
    // exactly there, indented one step in from it -- a whole line, so taking it out again leaves
    // no blank behind.
    let indent = format!("{}  ", indent_at(src, body_end));
    let line = format!("{indent}{var}:{kind} {{ {written} }}\n");
    Ok(format!("{}{}{}", &src[..body_end], line, &src[body_end..]))
}

/// The composition's own numbers, rewritten where `e.comp { ... }` says them.
///
/// Only the head of the table is looked at -- everything before `scene =` -- so a `width` that
/// belongs to a rectangle is never mistaken for the composition's.
pub fn set_comp(
    src: &str,
    width: Option<u32>,
    height: Option<u32>,
    duration: Option<f64>,
    fps: Option<f64>,
    background: Option<&str>,
) -> EditResult<String> {
    let head_end = Regex::new(r"scene\s*=\s*function")
        .unwrap()
        .find(src)
        .map(|m| m.start())
        .ok_or(EditRefusal::NoVerb {
            gesture: "resize a composition that has no scene in it".into(),
        })?;
    let mut head = src[..head_end].to_string();
    let tail = &src[head_end..];
    let mut one = |key: &str, lit: String| -> EditResult<()> {
        let re = Regex::new(&format!(r#"\b{key}\s*=\s*("[^"]*"|[0-9.]+)"#)).unwrap();
        if re.is_match(&head) {
            head = re.replace(&head, format!("{key} = {lit}").as_str()).to_string();
            Ok(())
        } else {
            // Not said yet: written on the line after `e.comp {`.
            let open = Regex::new(r"e\.comp\s*\{\s*\n").unwrap();
            let m = open.find(&head).ok_or(EditRefusal::NotALiteral {
                what: format!("the composition's {key}"),
            })?;
            head.insert_str(m.end(), &format!("  {key} = {lit},\n"));
            Ok(())
        }
    };
    if let Some(w) = width {
        one("width", w.to_string())?;
    }
    if let Some(h) = height {
        one("height", h.to_string())?;
    }
    if let Some(d) = duration {
        if !(d > 0.0) {
            return Err(EditRefusal::NoVerb {
                gesture: "make a composition that lasts no time at all".into(),
            });
        }
        one("duration", fmt_num(d))?;
    }
    if let Some(f) = fps {
        one("fps", fmt_num(f))?;
    }
    if let Some(b) = background {
        one("background", format!("\"{}\"", escape_lua(b)))?;
    }
    Ok(format!("{head}{tail}"))
}

pub(super) fn find_function_end(src: &str, from: usize) -> Option<usize> {
    let word = Regex::new(r"\b(function|if|for|while|do|end|then|repeat|until)\b").unwrap();
    let mut depth = 1i32;
    for m in word.find_iter(&src[from..]) {
        match m.as_str() {
            "function" | "if" | "for" | "while" | "repeat" => depth += 1,
            // `do`, `then` belong to a for/while/if already counted
            "do" | "then" | "until" => {}
            "end" => {
                depth -= 1;
                if depth == 0 {
                    let at = from + m.start();
                    return Some(src[..at].rfind('\n').map(|k| k + 1).unwrap_or(at));
                }
            }
            _ => {}
        }
    }
    None
}

/// The indentation of the line that starts at `at`.
pub(super) fn indent_at(src: &str, at: usize) -> String {
    src[at..]
        .chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .collect()
}

/// `%g` in Lua's sense: `2` not `2.0`, `0.55` not `0.550000`.
pub fn fmt_num(v: f64) -> String {
    if v == v.trunc() && v.abs() < 1e15 {
        format!("{}", v as i64)
    } else {
        let s = format!("{v:.6}");
        let s = s.trim_end_matches('0').trim_end_matches('.');
        s.to_string()
    }
}

pub fn escape_lua(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n")
}

/// A Lua literal for a value that came from the UI as JSON.
pub fn lua_literal(v: &serde_json::Value) -> Option<String> {
    match v {
        serde_json::Value::Number(n) => n.as_f64().map(fmt_num),
        serde_json::Value::String(s) => Some(format!("\"{}\"", escape_lua(s))),
        serde_json::Value::Bool(b) => Some(b.to_string()),
        _ => None,
    }
}
