use super::*;

/// Replace `key = <value>` inside a constructor body, at depth 0 only. Returns
/// `None` when the field is not there.
/// What `key` is set to in this node's own table, as it is written. `None` when the field is
/// not there; the text is returned untrimmed of nothing but its surrounding whitespace, so a
/// caller that wants a number still has to decide whether it reads as one.
pub(super) fn field<'a>(body: &'a str, key: &str) -> Option<&'a str> {
    let (from, to) = field_span(body, key)?;
    Some(body[from..to].trim())
}

/// Where the value of `key` sits inside `body`, if this node's own table sets it.
pub(super) fn field_span(body: &str, key: &str) -> Option<(usize, usize)> {
    let re = Regex::new(&format!(r"\b{}\s*=\s*", regex::escape(key))).unwrap();
    for m in re.find_iter(body) {
        let head = &body[..m.start()];
        let depth = head.matches('{').count() as i64 - head.matches('}').count() as i64;
        if depth != 1 {
            continue; // a nested table, not this node's own field
        }
        return Some((m.end(), m.end() + value_len(&body[m.end()..])));
    }
    None
}

/// How far the value that starts here runs: to the comma that ends it, or to the brace that
/// ends the table, with strings and nested tables skipped whole.
pub(super) fn value_len(rest: &str) -> usize {
    let rb = rest.as_bytes();
    if !rb.is_empty() && (rb[0] == b'"' || rb[0] == b'\'') {
        let q = rb[0];
        let mut j = 1;
        while j < rb.len() && rb[j] != q {
            j += if rb[j] == b'\\' { 2 } else { 1 };
        }
        return (j + 1).min(rb.len());
    }
    let mut j = 0usize;
    let mut depth = 0i64;
    while j < rb.len() {
        match rb[j] {
            b'{' | b'(' => depth += 1,
            b'}' | b')' => {
                if depth == 0 {
                    break;
                }
                depth -= 1;
            }
            b',' if depth == 0 => break,
            _ => {}
        }
        j += 1;
    }
    j
}

pub(super) fn set_field(body: &str, key: &str, value: &str) -> Option<String> {
    let re = Regex::new(&format!(r"\b{}\s*=\s*", regex::escape(key))).unwrap();
    for m in re.find_iter(body) {
        let head = &body[..m.start()];
        let depth = head.matches('{').count() as i64 - head.matches('}').count() as i64;
        if depth != 1 {
            continue; // a nested table, not this node's own field
        }
        let rest = &body[m.end()..];
        let rb = rest.as_bytes();
        let j = if !rb.is_empty() && (rb[0] == b'"' || rb[0] == b'\'') {
            let q = rb[0];
            let mut j = 1;
            while j < rb.len() && rb[j] != q {
                j += if rb[j] == b'\\' { 2 } else { 1 };
            }
            j + 1
        } else {
            let mut j = 0usize;
            let mut depth = 0i64;
            while j < rb.len() {
                match rb[j] {
                    b'{' | b'(' => depth += 1,
                    b'}' | b')' => {
                        if depth == 0 {
                            break;
                        }
                        depth -= 1;
                    }
                    b',' if depth == 0 => break,
                    _ => {}
                }
                j += 1;
            }
            j
        };
        return Some(format!("{}{}{}", &body[..m.end()], value, &rest[j..]));
    }
    None
}

// ------------------------------------------------------------------------- the edit verbs

/// `node.key = value` on the node's constructor; inserts the field when absent.
/// Properties worth setting on anything that has a place and a look, whether or not the
/// composition happened to write them down. Everything else has to already be there.
///
/// The closed list is the point. Without it an edit naming a property that does not exist is
/// written into the source anyway -- a live model asked to restack a caption invented
/// `z = "-1"`, and the lowering put it in the file, where it does exactly nothing. An edit the
/// renderer will ignore is worse than a refusal, because the person is told it worked.
pub(super) const OPEN_TO_ALL: &[&str] = &[
    "x", "y", "w", "h", "opacity", "rotation", "scale", "color", "size", "anchor", "rx", "r",
    "blur", "text", "font", "tracking", "leading", "volume", "at",
    // What a thing is called. Every thing can be given one, including a thing that has never
    // had one -- which is the point: a shape nobody named is "Block 2", and "Block 2" changes
    // when the stack is reordered. A name somebody typed does not.
    "label",
];

pub fn set_prop(
    src: &str,
    node: &str,
    key: &str,
    value: &str,
    nodes: Option<&[NodeRef]>,
) -> EditResult<String> {
    if let Some(all) = nodes {
        if let Some(n) = all.iter().find(|n| n.id == node) {
            if !n.props.is_empty()
                && !n.props.iter().any(|p| p == key)
                && !OPEN_TO_ALL.contains(&key)
            {
                return Err(EditRefusal::NoProp {
                    node: node.to_string(),
                    key: key.to_string(),
                });
            }
        }
    }
    let layout = Layout::read(src, nodes)?;
    let sp = layout.span(node)?;
    let body = &src[sp.start..sp.end];
    let new = match set_field(body, key, value) {
        Some(s) => s,
        None => format!("{{ {key} = {value},{}", &body[1..]),
    };
    Ok(format!("{}{}{}", &src[..sp.start], new, &src[sp.end..]))
}

pub(super) fn tween_hits(src: &str, var: &str) -> Vec<usize> {
    let follows = Regex::new(&format!(r"^\s*{}\s*,", regex::escape(var))).unwrap();
    tween_re()
        .find_iter(src)
        .filter(|m| follows.is_match(&src[m.end()..]))
        .map(|m| m.end())
        .collect()
}

/// Replace the ease name of the movement that drives `node`.
pub fn set_ease(
    src: &str,
    node: &str,
    ease: &str,
    occurrence: usize,
    nodes: Option<&[NodeRef]>,
) -> EditResult<String> {
    // The word has to be one the renderer honours. A live model, reading "arriving" in the
    // outline, passed "arriving" back -- and an easing name nothing recognises is a change that
    // renders identically while the person is told it worked.
    let ease = crate::words::ease(ease).ok_or_else(|| EditRefusal::NoCurve {
        asked: ease.to_string(),
        offered: crate::words::curve_words(),
    })?;
    let ease = ease.as_str();
    let layout = Layout::read(src, nodes)?;
    let sp = layout.span(node)?;
    let var = sp.var.clone().ok_or(EditRefusal::NotInLocal {
        node: node.to_string(),
    })?;
    let hits = tween_hits(src, &var);
    if occurrence >= hits.len() {
        return Err(EditRefusal::NoTween {
            node: node.to_string(),
            have: hits.len(),
            asked: occurrence,
        });
    }
    let after = hits[occurrence];
    let brace = src[after..].find('{').map(|k| after + k).ok_or(
        EditRefusal::NotALiteral {
            what: "the movement's target".into(),
        },
    )?;
    let end = match_brace(src, brace);
    let close = src[end..].find(')').map(|k| end + k + 1).ok_or(
        EditRefusal::NotALiteral {
            what: "the movement call".into(),
        },
    )?;
    let tail = &src[end..close];
    let name_re = Regex::new(r#""[A-Za-z]\w*""#).unwrap();
    let newtail = if name_re.is_match(tail) {
        name_re
            .replace(tail, format!("\"{ease}\"").as_str())
            .to_string()
    } else {
        // no ease written down: append one
        let trimmed = tail[..tail.len() - 1].trim_end().trim_end_matches(',');
        format!("{trimmed}, \"{ease}\")")
    };
    Ok(format!("{}{}{}", &src[..end], newtail, &src[close..]))
}

/// Retime one movement. Refuses when the duration is computed rather than written down.
pub fn set_tween_duration(
    src: &str,
    node: &str,
    seconds: f64,
    occurrence: usize,
    nodes: Option<&[NodeRef]>,
) -> EditResult<String> {
    let layout = Layout::read(src, nodes)?;
    let sp = layout.span(node)?;
    let var = sp.var.clone().ok_or(EditRefusal::NotInLocal {
        node: node.to_string(),
    })?;
    let hits = tween_hits(src, &var);
    if occurrence >= hits.len() {
        return Err(EditRefusal::NoTween {
            node: node.to_string(),
            have: hits.len(),
            asked: occurrence,
        });
    }
    let after = hits[occurrence];
    let arg =
        Regex::new(&format!(r"^(\s*{}\s*,\s*)([0-9.]+)", regex::escape(&var))).unwrap();
    let caps = arg
        .captures(&src[after..])
        .ok_or(EditRefusal::NotALiteral {
            what: "the movement's length".into(),
        })?;
    let g = caps.get(2).unwrap();
    let (a, b) = (after + g.start(), after + g.end());
    Ok(format!("{}{}{}", &src[..a], fmt_num(seconds), &src[b..]))
}
