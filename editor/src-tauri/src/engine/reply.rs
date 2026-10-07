use super::*;

pub(super) fn gone(e: SessionError) -> EngineError {
    EngineError::Gone(e.to_string())
}

/// The next reply. Lines that are not ours never reach here: the session passes on only `CS`
/// lines, so a native helper printing a warning cannot corrupt the stream.
pub(super) fn next_cs_line(inner: &mut Inner) -> EngineResult<String> {
    inner.session.recv().map_err(gone)
}

/// The bytes a reply names, taken from the session while the engine is still held, so the next
/// request cannot reuse the slot first.
pub(super) fn payload(inner: &mut Inner, path: &str) -> EngineResult<Vec<u8>> {
    inner
        .session
        .take(path)
        .ok_or_else(|| EngineError::Gone(format!("no payload at {path}")))
}

/// One line of the renderer's own words, with the code taken out of it.
///
/// A Lua error is `path/to/comp.lua:59: Incorrect number of parameters`, and both halves of that
/// are code: the path is a file name, which this app never shows, and the line number is a line
/// of a language the person has not been told exists. What is left is the sentence, which is the
/// only part anybody can act on.
///
/// Shared by the two places a composition can refuse: when it will not open at all, and when it
/// was open and a save stopped it reloading. They said the same thing differently until this
/// was one function.
pub fn in_words(said: &str) -> String {
    let sentence = Regex::new(r"(?:^|\s)(?:[\w./-]+):\d+:\s*")
        .ok()
        .and_then(|re| re.find_iter(said).last().map(|m| said[m.end()..].to_string()))
        .unwrap_or_else(|| said.to_string());
    // The engine names itself in its own errors. A person editing a video did not ask which part
    // of the renderer was speaking.
    let mut sentence = sentence.trim().to_string();
    for prefix in [
        "moonsplice error:",
        "moonsplice resolve:",
        "moonsplice-decode:",
        "moonsplice-engine:",
        "moonsplice:",
    ] {
        sentence = sentence.trim().trim_start_matches(prefix).to_string();
    }
    sentence.trim().to_string()
}

/// The renderer's own words about why a composition would not open, in one line.
///
/// Its stack traceback is dropped: it names Lua files inside the engine, which is code about code
/// and no help at all to somebody who opened a video. What is kept is the line that says what
/// went wrong, without the path it happened in.
pub(super) fn why_it_would_not_open(lines: &[String]) -> String {
    let first = lines
        .iter()
        .map(|l| l.trim())
        .find(|l| !l.is_empty() && !l.starts_with("stack traceback") && !l.starts_with('['))
        .unwrap_or("");
    if first.is_empty() {
        return "that composition would not open, and the renderer said nothing about why".into();
    }
    // "moonsplice error: physics_bake.lua:59: Incorrect number of parameters" -> the part after the
    // last "file:line:", which is the sentence somebody can act on.
    let sentence = in_words(first);
    let sentence = sentence.trim();
    if sentence.is_empty() {
        format!("that composition would not open: {first}")
    } else {
        format!("that composition would not open: {sentence}")
    }
}

pub(super) fn read_ready(inner: &mut Inner) -> EngineResult<EngineMeta> {
    let line = next_cs_line(inner)?;
    let mut it = line.split_whitespace();
    match it.next() {
        Some("ready") => {
            let mut next = || it.next().unwrap_or("0");
            let width = next().parse().unwrap_or(0);
            let height = next().parse().unwrap_or(0);
            let duration = next().parse().unwrap_or(0.0);
            let fps = next().parse().unwrap_or(30.0);
            Ok(EngineMeta {
                width,
                height,
                duration,
                fps,
            })
        }
        Some("err") => Err(EngineError::Refused(tail(&line, 2))),
        _ => Err(EngineError::Gone(format!("unexpected greeting: {line}"))),
    }
}

pub(super) fn read_reply(inner: &mut Inner) -> EngineResult<Reply> {
    let line = next_cs_line(inner)?;
    let parts: Vec<&str> = line.split_whitespace().collect();
    match parts.first().copied() {
        Some("frame") if parts.len() >= 5 => {
            let us = |i: usize| parts.get(i).and_then(|v| v.parse().ok()).unwrap_or(0);
            Ok(Reply::Frame {
                bytes: payload(inner, parts[1])?,
                w: parts[2].parse().unwrap_or(0),
                h: parts[3].parse().unwrap_or(0),
                spent: (us(5), us(6), us(7)),
            })
        }
        Some("json") if parts.len() >= 3 => Ok(Reply::Json {
            text: payload(inner, parts[1])?,
        }),
        Some("ok") => Ok(Reply::Done),
        Some("err") => Err(EngineError::Refused(tail(&line, 2))),
        _ => Err(EngineError::Gone(format!("unexpected reply: {line}"))),
    }
}

/// Everything after the first `skip` whitespace-separated words.
pub(super) fn tail(line: &str, skip: usize) -> String {
    line.split_whitespace()
        .skip(skip)
        .collect::<Vec<_>>()
        .join(" ")
}
