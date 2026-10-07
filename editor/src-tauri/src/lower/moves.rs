use super::*;

/// Move when a movement begins.
///
/// A movement is a statement in a script, and a script is a cursor that walks forward: `t:wait`
/// pushes it, `t:at` puts it somewhere, and a tween takes its own length. So when a movement
/// starts is not a number written next to it — it is everything before it added up. Moving it is
/// therefore changing the one thing immediately before it that holds time.
///
/// Three cases, and the third is the honest one:
///
///   - `t:wait(x)` before it  ->  `x + delta`, and never below zero.
///   - `t:at(x)` before it    ->  `x + delta`, which is where it is told to be.
///   - neither, and later     ->  a `t:wait(delta)` goes in on its own line.
///   - neither, and earlier   ->  refused: there is nothing before it to take the time out of.
///
/// What follows it in the same run moves with it, because that is what a script means and the
/// app does not invent a second one. Making a movement longer already works this way.
pub fn move_tween_start(
    src: &str,
    node: &str,
    occurrence: usize,
    delta: f64,
    nodes: Option<&[NodeRef]>,
) -> EditResult<String> {
    if delta == 0.0 {
        return Ok(src.to_string());
    }
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
    // The line the movement is written on.
    let call = src[..hits[occurrence]]
        .rfind("t")
        .map(|k| k + 1)
        .unwrap_or(hits[occurrence]);
    let line_start = src[..call].rfind('\n').map(|k| k + 1).unwrap_or(0);
    let indent: String = src[line_start..]
        .chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .collect();

    // What is written immediately before it, if it holds time. Only the statement right before:
    // anything further back is somebody else's timing and moving it would move more than the one
    // bar that was dragged.
    let holds = Regex::new(r"(?s)\bt\s*:\s*(wait|at)\s*\(\s*([0-9.]+)\s*\)\s*$").unwrap();
    if let Some(caps) = holds.captures(&src[..line_start]) {
        let g = caps.get(2).unwrap();
        let was: f64 = g.as_str().parse().map_err(|_| EditRefusal::NotALiteral {
            what: "when that movement starts".into(),
        })?;
        let now = was + delta;
        if now < 0.0 {
            return Err(EditRefusal::Conflict {
                detail: format!(
                    "that would start it {}s before the thing in front of it has finished",
                    fmt_num(-now)
                ),
            });
        }
        return Ok(format!(
            "{}{}{}",
            &src[..g.start()],
            fmt_num(round2(now)),
            &src[g.end()..]
        ));
    }
    if delta < 0.0 {
        return Err(EditRefusal::Conflict {
            detail: "there is nothing written before it to take the time out of, so it cannot \
                     start any earlier than it already does"
                .into(),
        });
    }
    Ok(format!(
        "{}{indent}t:wait({})\n{}",
        &src[..line_start],
        fmt_num(round2(delta)),
        &src[line_start..]
    ))
}

/// Retime or reword one line of a captions node: `{ 0.55, 1.45, "Hold the cut." }`.
pub fn set_cue(
    src: &str,
    node: &str,
    index: usize,
    t0: Option<f64>,
    t1: Option<f64>,
    text: Option<&str>,
    nodes: Option<&[NodeRef]>,
) -> EditResult<String> {
    let layout = Layout::read(src, nodes)?;
    let sp = layout.span(node)?;
    let body = &src[sp.start..sp.end];
    let cue_re =
        Regex::new(r#"\{\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*"((?:[^"\\]|\\.)*)"\s*\}"#).unwrap();
    let cues: Vec<_> = cue_re.captures_iter(body).collect();
    if index >= cues.len() {
        return Err(EditRefusal::NoCue {
            node: node.to_string(),
            have: cues.len(),
            asked: index,
        });
    }
    let m = &cues[index];
    let whole = m.get(0).unwrap();
    let a = t0.unwrap_or_else(|| m[1].parse().unwrap_or(0.0));
    let b = t1.unwrap_or_else(|| m[2].parse().unwrap_or(0.0));
    let s = text.map(escape_lua).unwrap_or_else(|| m[3].to_string());
    let new = format!(
        "{}{{ {}, {}, \"{}\" }}{}",
        &body[..whole.start()],
        fmt_num(a),
        fmt_num(b),
        s,
        &body[whole.end()..]
    );
    Ok(format!("{}{}{}", &src[..sp.start], new, &src[sp.end..]))
}

/// Pin a value by hand at an instant.
///
/// The verb the timeline needed and `lower.py` did not have. A pin is `t:set`, which the
/// timeline records as a *step* — structurally a different thing from a tween, which is why
/// the UI can mark it as manual without carrying a flag of its own.
///
/// It refuses when a movement already covers that instant, because a step inside a tween's
/// window is unreachable at evaluation: the tween wins and the pin would silently do
/// nothing. Better to say so.
pub fn pin_prop(
    src: &str,
    node: &str,
    t: f64,
    key: &str,
    value: &str,
    covered: bool,
    nodes: Option<&[NodeRef]>,
) -> EditResult<String> {
    let layout = Layout::read(src, nodes)?;
    let sp = layout.span(node)?;
    let var = sp.var.clone().ok_or(EditRefusal::NotInLocal {
        node: node.to_string(),
    })?;
    if covered {
        return Err(EditRefusal::Conflict {
            detail: format!(
                "{key} is already moving at {}s, so pinning it there would have no effect — \
                 change the movement instead",
                fmt_num(t)
            ),
        });
    }
    // Append to the last script block: `t:at` is an absolute cursor, so position in the
    // block does not change what it means.
    let script_re = Regex::new(r"s\s*:\s*script\s*\(\s*function\s*\(\s*\w+\s*\)").unwrap();
    let open = script_re
        .find_iter(src)
        .last()
        .ok_or(EditRefusal::NoVerb {
            gesture: format!(
                "pin {} at {}s with no timeline to put it on",
                crate::words::property(key).to_lowercase(),
                fmt_num(t)
            ),
        })?;
    // find the `end` that closes that function
    let body_end = find_function_end(src, open.end()).ok_or(EditRefusal::NotALiteral {
        what: "the timeline block".into(),
    })?;
    let indent = format!("{}  ", indent_at(src, body_end));
    let line = format!(
        "{indent}t:at({}) t:set({}, {{ {} = {} }})\n",
        fmt_num(t),
        var,
        key,
        value
    );
    Ok(format!("{}{}{}", &src[..body_end], line, &src[body_end..]))
}

/// Byte index of the `end` that closes the Lua function whose body starts at `from`.
/// Take a thing out of a composition.
///
/// The inverse of `place`, and the one a person reaches for with the Delete key. It deletes the
/// whole statement that built the thing — the constructor, the `local x =` in front of it if there
/// is one, and the line it sat on — so what is left is what would have been written if the thing
/// had never been put there.
///
/// It refuses when the name is used again: a thing a movement refers to cannot simply vanish, or
/// the composition stops loading, and a composition that will not open is a worse answer than a
/// sentence saying why.
pub fn remove(src: &str, node: &str, nodes: Option<&[NodeRef]>) -> EditResult<String> {
    let layout = Layout::read(src, nodes)?;
    let sp = layout.span(node)?;
    if let Some(var) = &sp.var {
        let word = Regex::new(&format!(r"\b{}\b", regex::escape(var))).unwrap();
        // Once for the declaration itself; anything more is something that refers to it.
        if word.find_iter(src).count() > 1 {
            return Err(EditRefusal::Conflict {
                detail: "something else in this composition refers to that, so taking it out \
                         would leave the rest pointing at nothing"
                    .into(),
            });
        }
    }
    // Back to the start of the statement: past `local x =`, then to the start of its line.
    let mut from = src[..sp.start].trim_end().len();
    from = src[..from].rfind(|c: char| c == '\n' || c == ';').map(|k| k + 1).unwrap_or(0);
    // And forward past the end of the line it finished on, so no blank line is left behind.
    let mut to = sp.end;
    let tail = &src[to..];
    let line_end = tail.find('\n').map(|k| to + k + 1).unwrap_or(src.len());
    if src[to..line_end].trim().is_empty() {
        to = line_end;
    }
    Ok(format!("{}{}", &src[..from], &src[to..]))
}

/// Move a thing up or down the stack: what paints over what.
///
/// `over` is the thing it should now paint over -- the one directly behind it, which on the
/// timeline is the lane directly below. `None` sends it to the very back, behind everything.
/// Draw order is the order the statements are written in, so this moves a whole statement.
///
/// Two things can stop it, and both are said rather than worked around. A statement that is
/// held in a name cannot move past something that reads that name, and a statement that reads a
/// name cannot move above where that name is made -- either would leave the composition pointing
/// at nothing. And a statement that is nested deeper than where it is going (inside a group, a
/// loop, a branch) is not the same statement somewhere else, so it stays where it is.
pub fn reorder(
    src: &str,
    node: &str,
    over: Option<&str>,
    nodes: Option<&[NodeRef]>,
) -> EditResult<String> {
    let layout = Layout::read(src, nodes)?;
    let sp = layout.span(node)?;
    if over == Some(node) {
        return Err(EditRefusal::Conflict {
            detail: "a thing cannot be put in front of itself".into(),
        });
    }
    let (a, b) = statement(src, sp.start, sp.end);
    let moving = &src[a..b];
    let indent: String = moving.chars().take_while(|c| *c == ' ' || *c == '\t').collect();

    // Where it lands: just after the statement it is to paint over, or at the top of the scene
    // when there is nothing for it to be behind.
    let (dest, dest_indent) = match over {
        Some(other) => {
            let osp = layout.span(other)?;
            let (oa, ob) = statement(src, osp.start, osp.end);
            (ob, indent_at(src, oa))
        }
        None => {
            let scene = Regex::new(r"scene\s*=\s*function\s*\(\s*\w+\s*\)").unwrap();
            let m = scene.find(src).ok_or(EditRefusal::NoVerb {
                gesture: "reorder things in a composition that has no scene in it".into(),
            })?;
            let at = src[m.end()..]
                .find('\n')
                .map(|k| m.end() + k + 1)
                .unwrap_or(src.len());
            (at, indent.clone())
        }
    };
    if dest_indent != indent {
        return Err(EditRefusal::Conflict {
            detail: "those two are not written in the same place in the composition, so one \
                     cannot simply be moved above the other"
                .into(),
        });
    }
    if dest >= a && dest <= b {
        return Ok(src.to_string()); // already there
    }

    // A name it is held in cannot be left behind by the things that read it.
    if let Some(var) = &sp.var {
        let word = Regex::new(&format!(r"\b{}\b", regex::escape(var))).unwrap();
        let crossed = if dest > b { &src[b..dest] } else { &src[dest..a] };
        if let Some(hit) = word.find(crossed) {
            // Said in terms of the thing rather than the text. Almost always what is in the way
            // is the composition's own timing -- the movements that drive it -- and "something
            // refers to it" is a sentence about source code, which is the one thing the person
            // reading it has chosen not to look at.
            let moves = Regex::new(r"\b(tween|set|wait|at|parallel)\s*\(").unwrap();
            let line = {
                let from = crossed[..hit.start()].rfind('\n').map(|k| k + 1).unwrap_or(0);
                let to = crossed[hit.start()..]
                    .find('\n')
                    .map(|k| hit.start() + k)
                    .unwrap_or(crossed.len());
                &crossed[from..to]
            };
            return Err(EditRefusal::Conflict {
                detail: if moves.is_match(line) {
                    "what moves it is written between those two, so it cannot go past that \
                     without losing the movement"
                        .into()
                } else {
                    "something between those two is made out of it, so moving it there would \
                     leave that pointing at nothing"
                        .into()
                },
            });
        }
    }
    // And a name it reads cannot be made after it arrives.
    if dest < a {
        let local = Regex::new(r"\blocal\s+(\w+)").unwrap();
        for m in local.captures_iter(&src[dest..a]) {
            let name = &m[1];
            if Regex::new(&format!(r"\b{}\b", regex::escape(name)))
                .unwrap()
                .is_match(moving)
            {
                return Err(EditRefusal::Conflict {
                    detail: "it is made out of something that does not exist yet that far back, \
                             so it cannot go there"
                        .into(),
                });
            }
        }
    }

    let mut out = String::with_capacity(src.len());
    if dest > b {
        out.push_str(&src[..a]);
        out.push_str(&src[b..dest]);
        out.push_str(moving);
        out.push_str(&src[dest..]);
    } else {
        out.push_str(&src[..dest]);
        out.push_str(moving);
        out.push_str(&src[dest..a]);
        out.push_str(&src[b..]);
    }
    Ok(out)
}
