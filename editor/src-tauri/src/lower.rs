//! Lowering: the only way a composition changes.
//!
//! `vision/moonsplice_vision/lower.py` states the property the whole app is built on:
//!
//! ```text
//! lower(comp, [])     is the identity (byte-for-byte, so every frame hash holds)
//! lower(comp, [edit]) changes exactly what the edit named
//! ```
//!
//! So this module is a set of **span replacements** over the Lua text. It never parses and
//! reprints: a pretty-print changes bytes, and changed bytes invalidate every hash in
//! `.robot/golden/`. The verbs here are the same verbs `lower.py` has, in the same order of
//! arguments, plus `pin_prop`, which the timeline needs and which is documented below.
//!
//! The coupling this makes explicit, and which `project-sync` calls out: the UI can only
//! edit what this vocabulary can express. A gesture with no verb is **refused** — never
//! applied through a second edit path.

use std::fmt;

use regex::Regex;
use serde::{Deserialize, Serialize};

/// Why an edit did not happen. Every variant is a sentence a person can act on; none of
/// them is a stack trace, and `NoVerb` is the one the UI turns into "that is not something
/// a composition can say".
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum EditRefusal {
    UnknownNode { node: String, known: Vec<String> },
    NotInLocal { node: String },
    NoTween { node: String, have: usize, asked: usize },
    NotALiteral { what: String },
    NoCue { node: String, have: usize, asked: usize },
    Conflict { detail: String },
    IdsMisaligned { constructors: usize, nodes: usize },
    Shared { node: String, count: usize },
    Unplaceable { node: String },
    NoVerb { gesture: String },
    NoProp { node: String, key: String },
    NoCurve { asked: String, offered: Vec<String> },
}

impl fmt::Display for EditRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EditRefusal::UnknownNode { node, known } => write!(
                f,
                "there is nothing called {node:?} in this composition ({} others there are)",
                known.len()
            ),
            EditRefusal::NotInLocal { node } => write!(
                f,
                "{node:?} is not held in a name, so no timing can refer to it"
            ),
            EditRefusal::NoTween { node, have, asked } => write!(
                f,
                "{node:?} has {have} movement(s); there is no #{asked}"
            ),
            EditRefusal::NotALiteral { what } => {
                write!(f, "{what} is computed, not written down, so it cannot be nudged")
            }
            EditRefusal::NoCue { node, have, asked } => {
                write!(f, "{node:?} has {have} line(s); there is no #{asked}")
            }
            EditRefusal::NoCurve { asked, offered } => write!(
                f,
                "there is no {asked:?} curve; the ones there are: {}",
                offered.join(", ")
            ),
            EditRefusal::NoProp { node, key } => write!(
                f,
                "{node:?} has no {key:?} to set, and inventing one would put a word in the \
                 composition that nothing reads"
            ),
            EditRefusal::Conflict { detail } => write!(f, "{detail}"),
            EditRefusal::IdsMisaligned {
                constructors,
                nodes,
            } => write!(
                f,
                "the text builds {constructors} things but the composition holds {nodes}, \
                 so they cannot be lined up"
            ),
            EditRefusal::Shared { node, count } => write!(
                f,
                "{node} is one of {count} things made the same way, so changing it would change \
                 all {count} — say which one you mean, or change them together"
            ),
            EditRefusal::Unplaceable { node } => write!(
                f,
                "{node} cannot be traced back to the words that made it, so it cannot be changed \
                 from here"
            ),
            EditRefusal::NoVerb { gesture } => write!(
                f,
                "a composition has no way to say {gesture:?}, so nothing was changed"
            ),
        }
    }
}

impl EditRefusal {
    /// The same refusal, said the way everything else in this app is said: a thing by the name
    /// the timeline calls it, a property by its word, and no id anywhere.
    ///
    /// `Display` is the developer's version and keeps the ids, because a log wants them. This is
    /// the one that reaches a person -- the notice in the corner is the surface where a refusal
    /// is read, and a refusal that says `rect2 has no "z"` is code on screen, which is the one
    /// thing this app is not allowed to show.
    pub fn say(&self, names: &std::collections::HashMap<String, String>) -> String {
        let who = |id: &String| crate::words::name_of(names, id);
        match self {
            EditRefusal::UnknownNode { known, .. } => format!(
                "there is nothing like that in this composition, which holds {} things",
                known.len()
            ),
            EditRefusal::NotInLocal { node } => format!(
                "{} is not held by a name, so no timing can refer to it",
                who(node)
            ),
            EditRefusal::NoTween { node, have, asked } => match have {
                0 => format!("{} does not move, so there is no movement to change", who(node)),
                _ => format!(
                    "{} has {have} movement(s), so there is no movement {}",
                    who(node),
                    asked + 1
                ),
            },
            EditRefusal::NoCue { node, have, asked } => match have {
                0 => format!("{} says nothing, so there is no line to change", who(node)),
                _ => format!(
                    "{} has {have} line(s), so there is no line {}",
                    who(node),
                    asked + 1
                ),
            },
            EditRefusal::NoProp { node, key } => match crate::words::property_said(key) {
                Some(word) => format!(
                    "{} has no {word} to set, and inventing one would put a word in the \
                     composition that nothing reads",
                    who(node)
                ),
                // Nothing in the vocabulary, so there is no word to say. Naming the key would
                // say it in the renderer's language, which is the thing being avoided.
                None => format!(
                    "{} has no such thing to set, and inventing one would put a word in the \
                     composition that nothing reads",
                    who(node)
                ),
            },
            EditRefusal::Shared { node, count } => format!(
                "{} is one of {count} things made the same way, so changing it would change all \
                 {count} -- say which one, or change them together",
                who(node)
            ),
            EditRefusal::Unplaceable { node } => format!(
                "{} cannot be traced back to what made it, so it cannot be changed from here",
                who(node)
            ),
            EditRefusal::NoCurve { offered, .. } => format!(
                "there is no curve by that name; the ones there are: {}",
                offered.join(", ")
            ),
            // These carry no id to begin with: a phrase, two counts, or prose that was already
            // written for a person.
            EditRefusal::NotALiteral { .. }
            | EditRefusal::IdsMisaligned { .. }
            | EditRefusal::Conflict { .. } => self.to_string(),
            EditRefusal::NoVerb { gesture } => {
                format!("a composition has no way to say {gesture}, so nothing was changed")
            }
        }
    }
}

pub type EditResult<T> = Result<T, EditRefusal>;

/// One node's constructor call in the source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub id: String,
    pub kind: String,
    /// byte index of the `{`
    pub start: usize,
    /// byte index just past the matching `}`
    pub end: usize,
    /// the local name it was assigned to, if any
    pub var: Option<String>,
}

fn ctor_re() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(\w+)\s*:\s*(\w+)\s*(\{)").unwrap())
}

fn tween_re() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\bt\s*:\s*tween\s*\(").unwrap())
}

/// Index just past the `}` matching the `{` at `i`, skipping strings and comments.
///
/// A byte scan: every character it reacts to is ASCII, so it cannot land inside a
/// multi-byte sequence and the indices it returns are always char boundaries.
pub fn match_brace(src: &str, i: usize) -> usize {
    let b = src.as_bytes();
    let n = b.len();
    let mut depth: i32 = 0;
    let mut j = i;
    while j < n {
        let ch = b[j];
        if ch == b'-' && j + 1 < n && b[j + 1] == b'-' {
            match src[j..].find('\n') {
                Some(k) => j += k,
                None => return n,
            }
        } else if ch == b'"' || ch == b'\'' {
            let q = ch;
            j += 1;
            while j < n && b[j] != q {
                j += if b[j] == b'\\' { 2 } else { 1 };
            }
        } else if ch == b'[' && j + 1 < n && b[j + 1] == b'[' {
            match src[j..].find("]]") {
                Some(k) => j += k + 1,
                None => return n,
            }
        } else if ch == b'{' {
            depth += 1;
        } else if ch == b'}' {
            depth -= 1;
            if depth == 0 {
                return j + 1;
            }
        }
        j += 1;
    }
    n
}

/// Every constructor call in the source, in construction order. The ids on these are the naive
/// `kind .. count` guess; `Layout` replaces them with the engine's real ones.
pub fn node_spans(src: &str) -> EditResult<Vec<Span>> {
    let mut seq: Vec<Span> = Vec::new();
    let mut count = 0usize;
    let id_re = Regex::new(r#"\bid\s*=\s*"([^"]+)""#).unwrap();
    let local_re = Regex::new(r"^\s*local\s+(\w+)\s*=").unwrap();
    for m in ctor_re().captures_iter(src) {
        let recv = m.get(1).unwrap().as_str();
        if matches!(recv, "t" | "e" | "math" | "string" | "table") {
            continue; // timeline / library calls, not nodes
        }
        let kind = m.get(2).unwrap().as_str().to_string();
        let start = m.get(3).unwrap().start();
        let end = match_brace(src, start);
        count += 1;
        let body = &src[start..end];
        let nid = id_re
            .captures(body)
            .map(|c| c[1].to_string())
            .unwrap_or_else(|| format!("{kind}{count}"));
        let head = m.get(0).unwrap().start();
        let line_start = src[..head].rfind('\n').map(|k| k + 1).unwrap_or(0);
        let var = local_re
            .captures(&src[line_start..head])
            .map(|c| c[1].to_string());
        seq.push(Span {
            id: nid,
            kind,
            start,
            end,
            var,
        });
    }
    Ok(seq)
}

/// One node as the engine reports it: its id, its kind, and the line of the composition that
/// built it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NodeRef {
    pub id: String,
    pub kind: String,
    /// 1-based, from the engine. `None` on an engine too old to report it, which falls the
    /// alignment back to counting constructors.
    pub line: Option<u32>,
    /// What this thing actually has, from the engine. Empty means "the caller did not say",
    /// and the vocabulary check is skipped -- so a test that only cares about spans still can.
    pub props: Vec<String>,
}

impl NodeRef {
    pub fn at(id: &str, kind: &str, line: u32) -> NodeRef {
        NodeRef {
            id: id.into(),
            kind: kind.into(),
            props: Vec::new(),
            line: Some(line),
        }
    }
}

/// Which constructor built which node.
///
/// The naive answer — count constructor calls and pair them with nodes in order — is wrong for
/// most real compositions, because **one call inside a loop builds many nodes**. Measured on this
/// repo's own eval suite it lined up for 29 of 42 compositions. So the engine reports the line
/// each node was written on, and the alignment is by line:
///
///   * one constructor on the line, one node   → that node is that constructor's
///   * one constructor, several nodes          → a loop: all of them are that constructor's, and
///                                               it is marked **shared**, so an edit naming one
///                                               of them is refused rather than changing all
///   * k constructors, a multiple of k nodes   → a loop over k calls; the nodes cycle
///   * anything else                           → those nodes are unplaceable, and refused
///
/// A refusal is the point. The failure mode of guessing here is an edit that silently changes
/// eight things when the person pointed at one.
pub struct Layout {
    spans: Vec<Span>,
    of_node: std::collections::HashMap<String, usize>,
    shared: std::collections::HashMap<usize, usize>,
    known: Vec<String>,
}

fn line_of(src: &str, byte: usize) -> u32 {
    (src[..byte.min(src.len())].matches('\n').count() + 1) as u32
}

impl Layout {
    pub fn read(src: &str, nodes: Option<&[NodeRef]>) -> EditResult<Layout> {
        let mut spans = node_spans(src)?;
        let Some(nodes) = nodes else {
            let known = spans.iter().map(|s| s.id.clone()).collect();
            let of_node = spans
                .iter()
                .enumerate()
                .map(|(i, s)| (s.id.clone(), i))
                .collect();
            return Ok(Layout {
                spans,
                of_node,
                shared: Default::default(),
                known,
            });
        };

        let known: Vec<String> = nodes.iter().map(|n| n.id.clone()).collect();
        let mut of_node = std::collections::HashMap::new();
        let mut shared = std::collections::HashMap::new();

        if nodes.iter().all(|n| n.line.is_some()) {
            // by line
            let mut by_line: std::collections::BTreeMap<u32, Vec<usize>> = Default::default();
            for (i, sp) in spans.iter().enumerate() {
                by_line.entry(line_of(src, sp.start)).or_default().push(i);
            }
            let mut nodes_by_line: std::collections::BTreeMap<u32, Vec<&NodeRef>> =
                Default::default();
            for n in nodes {
                nodes_by_line.entry(n.line.unwrap()).or_default().push(n);
            }
            let mut claimed: std::collections::HashSet<usize> = Default::default();
            for (line, group) in &nodes_by_line {
                let Some(candidates) = by_line.get(line) else {
                    continue; // nothing was written on that line; the second pass may still place it
                };
                let k = candidates.len();
                if group.len() % k == 0 {
                    for (i, n) in group.iter().enumerate() {
                        of_node.insert(n.id.clone(), candidates[i % k]);
                    }
                    for &c in candidates {
                        claimed.insert(c);
                    }
                    let per = group.len() / k;
                    if per > 1 {
                        for &c in candidates {
                            shared.insert(c, per);
                        }
                    }
                }
            }

            // Second pass: a node built inside a helper.
            //
            // `local function plane(s, ...) return s:svg { ... } end` loses its own line, because
            // `return s:svg{}` is a *tail call* and Lua replaces the frame — so the line that
            // reaches the engine is the helper's call site, where there is no constructor. What is
            // left over is unambiguous: the unclaimed constructors of that kind, and the nodes of
            // that kind nobody placed. A helper called four times is a loop by another name, so it
            // comes out shared, and an edit naming one of the four is refused.
            let unplaced: Vec<&NodeRef> =
                nodes.iter().filter(|n| !of_node.contains_key(&n.id)).collect();
            if !unplaced.is_empty() {
                let mut by_kind: std::collections::BTreeMap<&str, Vec<usize>> = Default::default();
                for (i, sp) in spans.iter().enumerate() {
                    if !claimed.contains(&i) {
                        by_kind.entry(sp.kind.as_str()).or_default().push(i);
                    }
                }
                let mut want: std::collections::BTreeMap<&str, Vec<&NodeRef>> = Default::default();
                for n in unplaced {
                    want.entry(n.kind.as_str()).or_default().push(n);
                }
                for (kind, group) in want {
                    let Some(candidates) = by_kind.get(kind) else { continue };
                    let k = candidates.len();
                    if k == 0 || group.len() % k != 0 {
                        continue; // genuinely unplaceable; `span` says so
                    }
                    for (i, n) in group.iter().enumerate() {
                        of_node.insert(n.id.clone(), candidates[i % k]);
                    }
                    let per = group.len() / k;
                    if per > 1 {
                        for &c in candidates {
                            shared.insert(c, per);
                        }
                    }
                }
            }
        } else if nodes.len() == spans.len() {
            // Positional, as `lower.py` does it. Right whenever every constructor builds exactly
            // one node, which is what an engine with no line information leaves us to assume.
            for (i, n) in nodes.iter().enumerate() {
                of_node.insert(n.id.clone(), i);
            }
        } else {
            return Err(EditRefusal::IdsMisaligned {
                constructors: spans.len(),
                nodes: nodes.len(),
            });
        }

        // The span carries the engine's id, so a later lookup reads the same name the UI showed.
        for (id, &i) in &of_node {
            if shared.get(&i).is_none() {
                spans[i].id = id.clone();
            }
        }

        Ok(Layout {
            spans,
            of_node,
            shared,
            known,
        })
    }

    /// The constructor that built `node`, or the reason it cannot be named.
    pub fn span(&self, node: &str) -> EditResult<&Span> {
        let Some(&i) = self.of_node.get(node) else {
            if self.known.iter().any(|k| k == node) {
                return Err(EditRefusal::Unplaceable {
                    node: node.to_string(),
                });
            }
            let mut known = self.known.clone();
            known.sort();
            return Err(EditRefusal::UnknownNode {
                node: node.to_string(),
                known,
            });
        };
        if let Some(&count) = self.shared.get(&i) {
            return Err(EditRefusal::Shared {
                node: node.to_string(),
                count,
            });
        }
        Ok(&self.spans[i])
    }

    /// How many nodes, of the ones the engine reported, this app can actually edit.
    pub fn placed(&self) -> usize {
        self.of_node
            .iter()
            .filter(|(_, i)| !self.shared.contains_key(i))
            .count()
    }

    pub fn spans(&self) -> &[Span] {
        &self.spans
    }
}

/// Replace `key = <value>` inside a constructor body, at depth 0 only. Returns
/// `None` when the field is not there.
/// What `key` is set to in this node's own table, as it is written. `None` when the field is
/// not there; the text is returned untrimmed of nothing but its surrounding whitespace, so a
/// caller that wants a number still has to decide whether it reads as one.
fn field<'a>(body: &'a str, key: &str) -> Option<&'a str> {
    let (from, to) = field_span(body, key)?;
    Some(body[from..to].trim())
}

/// Where the value of `key` sits inside `body`, if this node's own table sets it.
fn field_span(body: &str, key: &str) -> Option<(usize, usize)> {
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
fn value_len(rest: &str) -> usize {
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

fn set_field(body: &str, key: &str, value: &str) -> Option<String> {
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
const OPEN_TO_ALL: &[&str] = &[
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

fn tween_hits(src: &str, var: &str) -> Vec<usize> {
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

/// The whole statement a constructor sits in: from the start of its line, past any `local x =`,
/// to the end of the line its closing brace is on.
fn statement(src: &str, start: usize, end: usize) -> (usize, usize) {
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

fn round2(v: f64) -> f64 {
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

/// A block of whole lines, written just before the scene's closing `end` -- the same place
/// `place` writes its one line, so what was put in last paints in front.
pub fn insert(src: &str, lua: &str) -> EditResult<String> {
    let scene = Regex::new(r"scene\s*=\s*function\s*\(\s*(\w+)\s*\)").unwrap();
    let found = scene.captures(src).ok_or(EditRefusal::NoVerb {
        gesture: "put something in a composition that has no scene in it".into(),
    })?;
    let whole = found.get(0).expect("the match");
    let var = found.get(1).expect("the scene's own name").as_str();
    let body_end = find_function_end(src, whole.end()).ok_or(EditRefusal::NotALiteral {
        what: "the scene".into(),
    })?;
    let indent = format!("{}  ", indent_at(src, body_end));
    // The block is written against a scene called `s`; a composition that named its scene
    // something else gets the block in its own word.
    let mut block = String::new();
    for line in lua.lines() {
        let line = if var == "s" {
            line.to_string()
        } else {
            line.replace("s:", &format!("{var}:"))
        };
        if line.trim().is_empty() {
            block.push('\n');
        } else {
            block.push_str(&format!("{indent}{line}\n"));
        }
    }
    Ok(format!("{}{}{}", &src[..body_end], block, &src[body_end..]))
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

fn find_function_end(src: &str, from: usize) -> Option<usize> {
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
fn indent_at(src: &str, at: usize) -> String {
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

// ------------------------------------------------------------------------------- the edit

/// One edit, named the way the agent and the UI both name it.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "verb", rename_all = "snake_case")]
pub enum Edit {
    SetProp {
        node: String,
        key: String,
        value: serde_json::Value,
    },
    SetEase {
        node: String,
        ease: String,
        #[serde(default)]
        occurrence: usize,
    },
    SetTweenDuration {
        node: String,
        seconds: f64,
        #[serde(default)]
        occurrence: usize,
    },
    SetCue {
        node: String,
        index: usize,
        #[serde(default)]
        t0: Option<f64>,
        #[serde(default)]
        t1: Option<f64>,
        #[serde(default)]
        text: Option<String>,
    },
    PinProp {
        node: String,
        t: f64,
        key: String,
        value: serde_json::Value,
        /// The caller states whether a movement already covers that instant; it is the
        /// side that holds the outline.
        #[serde(default)]
        covered: bool,
    },
    /// Take a thing out of the composition.
    Remove { node: String },
    /// Cut a clip in two at a moment. The razor; see `split`.
    Split { node: String, at: f64 },
    /// Move when a movement begins, by `delta` seconds. See `move_tween_start`.
    MoveTweenStart {
        node: String,
        #[serde(default)]
        occurrence: usize,
        delta: f64,
    },
    /// Move a thing in the stack: it now paints over `over`, or goes to the back. See `reorder`.
    Restack {
        node: String,
        #[serde(default)]
        over: Option<String>,
    },
    /// Put a thing in the composition. The only verb that names no node, because the node it is
    /// about does not exist until it lands.
    Place {
        kind: String,
        /// Lua literals, in the order they are written.
        fields: Vec<(String, String)>,
        /// What to call it out loud: "Earth night", never a path and never `video7`.
        what: String,
    },
    /// Put a whole block in the scene: a thing *and* the movements that bring it on and take it
    /// off. `Place` writes one constructor and nothing else, which is right for a clip and wrong
    /// for a title card, because a card with no way in and no way out is on screen for the whole
    /// composition.
    ///
    /// Never read from JSON. The block is Lua, and the only Lua that reaches a composition is
    /// Lua this app wrote from a structured request (see `crate::headless::draw_block`). A model
    /// that could send this through `change` could write anything at all into the file.
    #[serde(skip)]
    Insert {
        /// Whole lines, already indented one step in from the scene's own `end`.
        lua: String,
        what: String,
    },
    /// The composition's own frame: how big it is, how long, how many pictures a second and what
    /// is behind everything. Each is left alone when it is `None`.
    SetComp {
        #[serde(default)]
        width: Option<u32>,
        #[serde(default)]
        height: Option<u32>,
        #[serde(default)]
        duration: Option<f64>,
        #[serde(default)]
        fps: Option<f64>,
        #[serde(default)]
        background: Option<String>,
    },
}

impl Edit {
    pub fn node(&self) -> &str {
        match self {
            Edit::SetProp { node, .. }
            | Edit::SetEase { node, .. }
            | Edit::SetTweenDuration { node, .. }
            | Edit::SetCue { node, .. }
            | Edit::PinProp { node, .. }
            | Edit::Split { node, .. }
            | Edit::Restack { node, .. }
            | Edit::MoveTweenStart { node, .. }
            | Edit::Remove { node } => node,
            // Nothing yet. It is about to be something.
            Edit::Place { .. } | Edit::Insert { .. } | Edit::SetComp { .. } => "",
        }
    }

    /// The property this edit sets, if it sets one, to be rewritten from a word into the key
    /// the renderer reads. See `crate::words::prop_key`.
    pub fn key_mut(&mut self) -> Option<&mut String> {
        match self {
            Edit::SetProp { key, .. } | Edit::PinProp { key, .. } => Some(key),
            _ => None,
        }
    }

    /// The thing this edit is about, to be rewritten from a name into an id before it is
    /// applied. See `crate::words::resolve`.
    pub fn node_mut(&mut self) -> Option<&mut String> {
        match self {
            Edit::SetProp { node, .. }
            | Edit::SetEase { node, .. }
            | Edit::SetTweenDuration { node, .. }
            | Edit::SetCue { node, .. }
            | Edit::PinProp { node, .. }
            | Edit::Split { node, .. }
            | Edit::Restack { node, .. }
            | Edit::MoveTweenStart { node, .. }
            | Edit::Remove { node } => Some(node),
            Edit::Place { .. } | Edit::Insert { .. } | Edit::SetComp { .. } => None,
        }
    }

    /// What this edit did, in the words a person would use. Goes straight into the undo
    /// label, the notice in the corner, and the agent's transcript -- so it may not contain a
    /// node id, a property key or an easing name. `names` comes from the outline; see
    /// `crate::words`.
    pub fn describe(&self, names: &std::collections::HashMap<String, String>) -> String {
        let who = |id: &str| crate::words::name_of(names, id);
        match self {
            Edit::SetProp { node, key, value } => format!(
                "set {}'s {} to {}",
                who(node),
                crate::words::property(key).to_lowercase(),
                brief(value)
            ),
            Edit::SetEase { node, ease, .. } => format!(
                "set {}'s curve to {}",
                who(node),
                crate::words::curve(ease)
            ),
            Edit::SetTweenDuration { node, seconds, .. } => {
                format!("made {}'s move {}s long", who(node), fmt_num(*seconds))
            }
            Edit::SetCue { node, index, .. } => {
                format!("changed line {} of {}", index + 1, who(node))
            }
            Edit::PinProp { node, key, t, .. } => format!(
                "set {}'s {} by hand at {}s",
                who(node),
                crate::words::property(key).to_lowercase(),
                fmt_num(*t)
            ),
            Edit::Place { what, .. } | Edit::Insert { what, .. } => format!("put {what} in"),
            Edit::SetComp {
                width,
                height,
                duration,
                fps,
                background,
            } => {
                let mut said = Vec::new();
                if let (Some(w), Some(h)) = (width, height) {
                    said.push(format!("{w} by {h}"));
                }
                if let Some(d) = duration {
                    said.push(format!("{}s long", fmt_num(*d)));
                }
                if let Some(f) = fps {
                    said.push(format!("{} pictures a second", fmt_num(*f)));
                }
                if background.is_some() {
                    said.push("a new background".into());
                }
                format!("made the composition {}", said.join(", "))
            }
            Edit::Remove { node } => format!("took {} out", who(node)),
            Edit::Split { node, at } => {
                format!("cut {} in two at {}s", who(node), fmt_num(*at))
            }
            Edit::MoveTweenStart { node, delta, .. } => format!(
                "started {}'s move {}s {}",
                who(node),
                fmt_num(delta.abs()),
                if *delta < 0.0 { "earlier" } else { "later" }
            ),
            Edit::Restack { node, over } => match over {
                Some(o) => format!("put {} in front of {}", who(node), who(o)),
                None => format!("sent {} to the back", who(node)),
            },
        }
    }
}

fn brief(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// Apply edits in order. With no edits this returns the source unchanged, byte for byte.
pub fn lower(src: &str, edits: &[Edit], nodes: Option<&[NodeRef]>) -> EditResult<String> {
    if edits.is_empty() {
        return Ok(src.to_string());
    }
    let mut out = src.to_string();
    for e in edits {
        out = match e {
            Edit::SetProp { node, key, value } => {
                let lit = lua_literal(value).ok_or_else(|| EditRefusal::NoVerb {
                    gesture: format!("set {key} to something that is not a number, word or switch"),
                })?;
                set_prop(&out, node, key, &lit, nodes)?
            }
            Edit::SetEase {
                node,
                ease,
                occurrence,
            } => set_ease(&out, node, ease, *occurrence, nodes)?,
            Edit::SetTweenDuration {
                node,
                seconds,
                occurrence,
            } => set_tween_duration(&out, node, *seconds, *occurrence, nodes)?,
            Edit::SetCue {
                node,
                index,
                t0,
                t1,
                text,
            } => set_cue(&out, node, *index, *t0, *t1, text.as_deref(), nodes)?,
            Edit::PinProp {
                node,
                t,
                key,
                value,
                covered,
            } => {
                let lit = lua_literal(value).ok_or_else(|| EditRefusal::NoVerb {
                    gesture: format!("pin {key} to something that is not a number, word or switch"),
                })?;
                pin_prop(&out, node, *t, key, &lit, *covered, nodes)?
            }
            Edit::Place { kind, fields, .. } => place(&out, kind, fields)?,
            Edit::Insert { lua, .. } => insert(&out, lua)?,
            Edit::SetComp {
                width,
                height,
                duration,
                fps,
                background,
            } => set_comp(&out, *width, *height, *duration, *fps, background.as_deref())?,
            Edit::Remove { node } => remove(&out, node, nodes)?,
            Edit::Split { node, at } => split(&out, node, *at, nodes)?,
            Edit::Restack { node, over } => reorder(&out, node, over.as_deref(), nodes)?,
            Edit::MoveTweenStart {
                node,
                occurrence,
                delta,
            } => move_tween_start(&out, node, *occurrence, *delta, nodes)?,
        };
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SRC: &str = r##"local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "35  CAPTIONS", size = 22, color = "#6b7894" }
    local bar = s:rect { x = 80, y = 528, w = 0, h = 4, rx = 2, color = "#3ee0c6" }
    s:captions {
      x = 80, y = 578, size = 36, color = "#f4f6fb",
      cues = {
        { 0.55, 1.45, "Hold the cut." },
        { 1.45, 2.45, "Let the type land." },
      },
    }

    s:script(function(t)
      t:wait(0.15)
      t:tween(bar, 0.4, { w = 640 }, "expoOut")
    end)
  end,
}
"##;

    #[test]
    fn no_edits_is_byte_identical() {
        assert_eq!(lower(SRC, &[], None).unwrap(), SRC);
    }

    /// The three nodes SRC builds, as the engine reports them: `s:captions` builds a *text*
    /// node, so its id is text3 and not captions3.
    fn engine_nodes() -> Vec<NodeRef> {
        vec![
            NodeRef::at("text1", "text", 8),
            NodeRef::at("rect2", "rect", 9),
            NodeRef::at("text3", "text", 10),
        ]
    }

    #[test]
    fn spans_find_every_node_and_its_local() {
        let spans = node_spans(SRC).unwrap();
        let ids: Vec<&str> = spans.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, vec!["text1", "rect2", "captions3"]);
        assert_eq!(spans[1].var.as_deref(), Some("bar"));
        assert_eq!(spans[0].var, None);
    }

    #[test]
    fn a_node_is_traced_to_the_line_that_wrote_it() {
        let nodes = engine_nodes();
        let layout = Layout::read(SRC, Some(&nodes)).unwrap();
        assert_eq!(layout.span("text3").unwrap().kind, "captions");
        assert_eq!(layout.span("rect2").unwrap().var.as_deref(), Some("bar"));
        assert_eq!(layout.placed(), 3);
    }

    #[test]
    fn a_thing_built_in_a_loop_is_refused_rather_than_changing_all_of_them() {
        // Eight circles from one line, the way every real composition with a loop does it.
        let src = "return e.comp {\n  scene = function(s)\n    for i = 1, 8 do\n      s:circle { x = i * 10, y = 100, r = 20 }\n    end\n  end,\n}\n";
        let nodes: Vec<NodeRef> = (1..=8)
            .map(|i| NodeRef::at(&format!("circle{i}"), "circle", 4))
            .collect();
        let layout = Layout::read(src, Some(&nodes)).unwrap();
        match layout.span("circle3") {
            Err(EditRefusal::Shared { count, .. }) => assert_eq!(count, 8),
            other => panic!("{other:?}"),
        }
        assert_eq!(layout.placed(), 0);
        assert!(layout
            .span("circle3")
            .unwrap_err()
            .to_string()
            .contains("would change all 8"));
    }

    #[test]
    fn a_thing_built_inside_a_helper_is_found_anyway() {
        // Lua replaces a tail-called frame, so `return s:svg{}` inside a helper reports the
        // helper's *call site* as its line. The second pass places it from what is left over.
        let src = "local function plane(s, x)\n  return s:svg { src = \"a.svg\", x = x }\nend\n\nreturn e.comp {\n  scene = function(s)\n    local a = plane(s, 10)\n    local b = plane(s, 20)\n  end,\n}\n";
        let nodes = vec![
            NodeRef::at("svg1", "svg", 7),
            NodeRef::at("svg2", "svg", 8),
        ];
        let layout = Layout::read(src, Some(&nodes)).unwrap();
        // Two nodes, one constructor: the helper is a loop by another name, so both are refused
        // by name rather than one of them silently changing both.
        assert!(matches!(
            layout.span("svg1"),
            Err(EditRefusal::Shared { count: 2, .. })
        ));
    }

    #[test]
    fn a_loop_over_two_constructors_pairs_them_by_turn() {
        let src = "return e.comp {\n  scene = function(s)\n    for i = 1, 3 do\n      s:circle { r = 4 } s:text { text = \"x\" }\n    end\n  end,\n}\n";
        let nodes: Vec<NodeRef> = vec![
            NodeRef::at("circle1", "circle", 4),
            NodeRef::at("text2", "text", 4),
            NodeRef::at("circle3", "circle", 4),
            NodeRef::at("text4", "text", 4),
            NodeRef::at("circle5", "circle", 4),
            NodeRef::at("text6", "text", 4),
        ];
        let layout = Layout::read(src, Some(&nodes)).unwrap();
        // Three of each, so both constructors are shared three ways and both are refused.
        assert!(matches!(
            layout.span("text4"),
            Err(EditRefusal::Shared { count: 3, .. })
        ));
    }

    #[test]
    fn a_node_from_nowhere_is_refused_not_guessed() {
        // Nothing in SRC builds a video, and the line is not one anything was written on, so
        // neither pass can place it and the app says so.
        let nodes = vec![NodeRef::at("ghost1", "video", 999)];
        let layout = Layout::read(SRC, Some(&nodes)).unwrap();
        assert!(matches!(
            layout.span("ghost1"),
            Err(EditRefusal::Unplaceable { .. })
        ));
        assert!(layout
            .span("ghost1")
            .unwrap_err()
            .to_string()
            .contains("cannot be traced back"));
    }

    #[test]
    fn with_no_line_information_it_falls_back_to_counting() {
        let nodes: Vec<NodeRef> = ["text1", "rect2", "text3"]
            .iter()
            .map(|id| NodeRef {
                id: (*id).into(),
                kind: "text".into(),
                line: None,
                props: Vec::new(),
            })
            .collect();
        let layout = Layout::read(SRC, Some(&nodes)).unwrap();
        assert_eq!(layout.span("text3").unwrap().kind, "captions");
    }

    #[test]
    fn a_count_that_cannot_be_paired_refuses_rather_than_guessing() {
        let nodes = vec![NodeRef {
            id: "text1".into(),
            kind: "text".into(),
            line: None,
            props: Vec::new(),
        }];
        assert!(matches!(
            Layout::read(SRC, Some(&nodes)),
            Err(EditRefusal::IdsMisaligned {
                constructors: 3,
                nodes: 1
            })
        ));
    }

    /// A live model, asked to put a caption behind a bar, invented `z = "-1"` -- and the
    /// lowering wrote it into the composition, where nothing reads it. A word the renderer
    /// ignores is worse than a refusal: the person is told their change worked.
    #[test]
    fn a_property_the_thing_does_not_have_is_refused_not_invented() {
        let nodes = vec![NodeRef {
            id: "rect2".into(),
            kind: "rect".into(),
            line: Some(3),
            props: vec!["x".into(), "y".into(), "w".into(), "h".into()],
        }];
        let refused = set_prop(SRC, "rect2", "z", "-1", Some(&nodes));
        assert!(
            matches!(&refused, Err(EditRefusal::NoProp { key, .. }) if key == "z"),
            "got {refused:?}"
        );
        let said = refused.unwrap_err().to_string();
        assert!(said.contains("no \"z\" to set"), "{said}");

        // What it does have still works.
        assert!(set_prop(SRC, "rect2", "w", "640", Some(&nodes)).is_ok());
        // And so does a property anything can have, whether or not it is written down.
        assert!(set_prop(SRC, "rect2", "opacity", "0.5", Some(&nodes)).is_ok());
    }

    #[test]
    fn set_prop_replaces_only_that_field() {
        let out = set_prop(SRC, "rect2", "w", "640", None).unwrap();
        assert!(out.contains("x = 80, y = 528, w = 640, h = 4"));
        assert_eq!(out.len(), SRC.len() + 2);
        // and it left the other node alone
        assert!(out.contains("s:text { x = 48, y = 36,"));
    }

    #[test]
    fn set_prop_inserts_a_missing_field() {
        let out = set_prop(SRC, "rect2", "opacity", "0.5", None).unwrap();
        assert!(out.contains("s:rect { opacity = 0.5, x = 80"));
    }

    #[test]
    fn set_prop_does_not_reach_into_a_nested_table() {
        // `cues` holds tables; a bare `x` inside one must not be mistaken for the node's.
        let out = set_prop(SRC, "captions3", "x", "120", None).unwrap();
        assert!(out.contains("x = 120, y = 578"));
        assert!(out.contains("{ 0.55, 1.45, \"Hold the cut.\" }"));
    }

    #[test]
    fn unknown_node_is_refused_with_the_names_it_knows() {
        match set_prop(SRC, "nope", "x", "1", None) {
            Err(EditRefusal::UnknownNode { known, .. }) => {
                assert_eq!(known, vec!["captions3", "rect2", "text1"]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_curve_that_does_not_exist_is_refused_not_written() {
        let refused = set_ease(SRC, "rect2", "gently", 0, None);
        assert!(
            matches!(&refused, Err(EditRefusal::NoCurve { asked, .. }) if asked == "gently"),
            "got {refused:?}"
        );
        let said = refused.unwrap_err().to_string();
        assert!(said.contains("Arriving"), "the refusal should offer the real ones: {said}");

        // The word the app itself shows is accepted, and lands as the renderer's own name.
        let out = set_ease(SRC, "rect2", "Arriving", 0, None).unwrap();
        assert!(out.contains("\"expoOut\""), "{out}");
    }

    #[test]
    fn set_ease_rewrites_the_curve_name() {
        let out = set_ease(SRC, "rect2", "sineOut", 0, None).unwrap();
        assert!(out.contains(r#"t:tween(bar, 0.4, { w = 640 }, "sineOut")"#));
    }

    #[test]
    fn set_ease_needs_a_name_to_hold_the_node() {
        assert!(matches!(
            set_ease(SRC, "text1", "sineOut", 0, None),
            Err(EditRefusal::NotInLocal { .. })
        ));
    }

    #[test]
    fn set_ease_appends_when_no_curve_was_written() {
        let src = SRC.replace(r#", "expoOut")"#, ")");
        let out = set_ease(&src, "rect2", "backOut", 0, None).unwrap();
        assert!(out.contains(r#"t:tween(bar, 0.4, { w = 640 }, "backOut")"#));
    }

    #[test]
    fn set_tween_duration_edits_the_number() {
        let out = set_tween_duration(SRC, "rect2", 1.25, 0, None).unwrap();
        assert!(out.contains("t:tween(bar, 1.25, { w = 640 }"));
    }

    #[test]
    fn a_movement_that_is_not_there_is_refused() {
        assert!(matches!(
            set_tween_duration(SRC, "rect2", 1.0, 3, None),
            Err(EditRefusal::NoTween {
                have: 1,
                asked: 3,
                ..
            })
        ));
    }

    #[test]
    fn a_computed_duration_is_refused_rather_than_guessed() {
        let src = SRC.replace("t:tween(bar, 0.4,", "t:tween(bar, dur * 2,");
        assert!(matches!(
            set_tween_duration(&src, "rect2", 1.0, 0, None),
            Err(EditRefusal::NotALiteral { .. })
        ));
    }

    #[test]
    fn set_cue_retimes_one_line() {
        let out = set_cue(SRC, "captions3", 1, Some(1.6), None, None, None).unwrap();
        assert!(out.contains(r#"{ 1.6, 2.45, "Let the type land." }"#));
        assert!(out.contains(r#"{ 0.55, 1.45, "Hold the cut." }"#));
    }

    #[test]
    fn set_cue_rewords_one_line_and_escapes_it() {
        let out = set_cue(SRC, "captions3", 0, None, None, Some("Say \"cut\"."), None).unwrap();
        assert!(out.contains(r#"{ 0.55, 1.45, "Say \"cut\"." }"#));
    }

    #[test]
    fn a_line_that_is_not_there_is_refused() {
        assert!(matches!(
            set_cue(SRC, "captions3", 9, Some(0.0), None, None, None),
            Err(EditRefusal::NoCue { have: 2, asked: 9, .. })
        ));
    }

    #[test]
    fn pin_writes_a_step_into_the_timeline_block() {
        let out = pin_prop(SRC, "rect2", 2.5, "opacity", "0", false, None).unwrap();
        assert!(out.contains("t:at(2.5) t:set(bar, { opacity = 0 })"));
        // still one script block, still closed
        assert_eq!(out.matches("s:script(").count(), 1);
        assert!(out.contains("t:tween(bar, 0.4,"));
    }

    #[test]
    fn pin_refuses_where_a_movement_already_decides_the_value() {
        assert!(matches!(
            pin_prop(SRC, "rect2", 0.3, "w", "100", true, None),
            Err(EditRefusal::Conflict { .. })
        ));
    }

    #[test]
    fn edits_apply_in_order_and_compose() {
        let edits = vec![
            Edit::SetProp {
                node: "rect2".into(),
                key: "h".into(),
                value: serde_json::json!(8),
            },
            Edit::SetEase {
                node: "rect2".into(),
                ease: "quadOut".into(),
                occurrence: 0,
            },
        ];
        let out = lower(SRC, &edits, None).unwrap();
        assert!(out.contains("h = 8,"));
        assert!(out.contains(r#""quadOut""#));
    }

    #[test]
    fn numbers_read_the_way_a_person_wrote_them() {
        assert_eq!(fmt_num(2.0), "2");
        assert_eq!(fmt_num(0.55), "0.55");
        assert_eq!(fmt_num(1.25), "1.25");
        assert_eq!(fmt_num(-3.0), "-3");
    }

    #[test]
    fn match_brace_skips_strings_and_comments() {
        let src = "{ a = \"}\", -- }\n b = { c = 1 } }";
        assert_eq!(match_brace(src, 0), src.len());
    }

    #[test]
    fn a_gesture_with_no_verb_is_refused_not_applied() {
        // The UI asks to move where a movement *starts*. No verb says that, so the app
        // must refuse rather than open a second edit path.
        let refusal = EditRefusal::NoVerb {
            gesture: "move when a movement starts".into(),
        };
        assert!(refusal.to_string().contains("nothing was changed"));
    }
}

#[cfg(test)]
mod razor {
    use super::*;

    const CLIPS: &str = r##"local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 10, fps = 30,

  scene = function(s)
    local shot = s:video { src = "a.mp4", from = 1, duration = 6, media_start = 2, x = 0, y = 0 }
    s:rect { x = 0, y = 600, w = 1280, h = 120, color = "#000000aa" }
  end,
}
"##;

    fn nodes() -> Vec<NodeRef> {
        vec![NodeRef::at("video1", "video", 7), NodeRef::at("rect2", "rect", 8)]
    }

    #[test]
    fn a_clip_cut_in_two_is_the_same_clip_twice() {
        let out = split(CLIPS, "video1", 4.0, Some(&nodes())).unwrap();

        // The half that stays keeps its name and stops at the cut.
        assert!(
            out.contains(
                r#"local shot = s:video { src = "a.mp4", from = 1, duration = 3, media_start = 2, x = 0, y = 0 }"#
            ),
            "{out}"
        );
        // The half that is made starts there, and starts three seconds further into the footage
        // -- so the frame after the cut is the frame that was after the cut before it.
        assert!(
            out.contains(
                r#"    s:video { src = "a.mp4", from = 4, duration = 3, media_start = 5, x = 0, y = 0 }"#
            ),
            "{out}"
        );
        // It is written under the clip it came from, not at the end of the scene: what it draws
        // over and what draws over it are unchanged.
        let first = out.find("local shot").unwrap();
        let second = out[first..].find("s:video").map(|k| first + k).unwrap();
        let plate = out.find("s:rect").unwrap();
        assert!(second < plate, "the new half landed after the plate\n{out}");
        // And nothing else moved.
        assert_eq!(out.lines().count(), CLIPS.lines().count() + 1);
    }

    #[test]
    fn the_cut_has_to_land_inside_the_clip() {
        for t in [0.5, 1.0, 7.0, 9.0] {
            let err = split(CLIPS, "video1", t, Some(&nodes())).unwrap_err();
            assert!(
                err.to_string().contains("inside the clip"),
                "{t}s: {err}"
            );
        }
    }

    #[test]
    fn a_thing_with_no_length_is_not_cut_but_told_why() {
        let err = split(CLIPS, "rect2", 4.0, Some(&nodes())).unwrap_err();
        assert!(err.to_string().contains("no length of its own"), "{err}");
    }

    #[test]
    fn cutting_twice_makes_three_and_they_join_up() {
        let once = split(CLIPS, "video1", 3.0, Some(&nodes())).unwrap();
        // The engine would now report three nodes; the second half is the new video2.
        let three = vec![
            NodeRef::at("video1", "video", 7),
            NodeRef::at("video2", "video", 8),
            NodeRef::at("rect3", "rect", 9),
        ];
        let twice = split(&once, "video2", 5.0, Some(&three)).unwrap();

        // 1..3, 3..5, 5..7 -- no gap, no overlap, and each starts where the last left off in
        // the footage as well as on the timeline.
        let spans: Vec<(f64, f64, f64)> = twice
            .lines()
            .filter(|l| l.contains("s:video"))
            .map(|l| {
                let n = |k: &str| {
                    field(&l[l.find('{').unwrap()..], k)
                        .unwrap()
                        .parse::<f64>()
                        .unwrap()
                };
                (n("from"), n("duration"), n("media_start"))
            })
            .collect();
        assert_eq!(spans, vec![(1.0, 2.0, 2.0), (3.0, 2.0, 4.0), (5.0, 2.0, 6.0)], "{twice}");
    }

    #[test]
    fn a_clip_given_a_name_by_hand_does_not_get_it_twice() {
        let src = CLIPS.replace(
            r#"{ src = "a.mp4", from = 1"#,
            r#"{ id = "hero", src = "a.mp4", from = 1"#,
        );
        let out = split(&src, "hero", 4.0, Some(&[NodeRef::at("hero", "video", 7), NodeRef::at("rect2", "rect", 8)])).unwrap();
        assert_eq!(out.matches(r#"id = "hero""#).count(), 1, "{out}");
    }
}

#[cfg(test)]
mod stack {
    use super::*;

    const THREE: &str = r##"local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,

  scene = function(s)
    s:rect { x = 0, y = 0, w = 1280, h = 720, color = "#101418" }
    local bar = s:rect { x = 80, y = 528, w = 0, h = 4, color = "#3ee0c6" }
    s:text { x = 48, y = 36, text = "TOP", size = 22 }

    s:script(function(t)
      t:tween(bar, 0.4, { w = 640 }, "expoOut")
    end)
  end,
}
"##;

    fn nodes() -> Vec<NodeRef> {
        vec![
            NodeRef::at("rect1", "rect", 7),
            NodeRef::at("rect2", "rect", 8),
            NodeRef::at("text3", "text", 9),
        ]
    }

    /// The order of the statements is the order of the picture, so the only thing worth asserting
    /// is which line is where.
    fn order(src: &str) -> Vec<&str> {
        src.lines()
            .filter_map(|l| {
                let t = l.trim();
                if t.starts_with("s:") || t.starts_with("local ") {
                    t.split_whitespace().last()
                } else {
                    None
                }
            })
            .collect()
    }

    #[test]
    fn a_thing_is_brought_in_front_of_another() {
        // The backdrop, which is drawn first, put in front of the bar.
        let out = reorder(THREE, "rect1", Some("rect2"), Some(&nodes())).unwrap();
        let lines: Vec<&str> = out.lines().map(str::trim).collect();
        let backdrop = lines.iter().position(|l| l.contains("#101418")).unwrap();
        let bar = lines.iter().position(|l| l.contains("#3ee0c6")).unwrap();
        let top = lines.iter().position(|l| l.contains("\"TOP\"")).unwrap();
        assert!(bar < backdrop && backdrop < top, "{out}");
        // And nothing else changed: same lines, in a different order.
        assert_eq!(order(&out).len(), order(THREE).len());
    }

    #[test]
    fn a_thing_is_sent_to_the_very_back() {
        let out = reorder(THREE, "text3", None, Some(&nodes())).unwrap();
        let lines: Vec<&str> = out.lines().map(str::trim).collect();
        let top = lines.iter().position(|l| l.contains("\"TOP\"")).unwrap();
        let backdrop = lines.iter().position(|l| l.contains("#101418")).unwrap();
        assert!(top < backdrop, "{out}");
    }

    #[test]
    fn a_thing_something_else_reads_does_not_move_past_it() {
        // The bar is tweened by the script at the end. Moving it in front of the text is fine --
        // the script is still after it -- but there is nothing after the script to move it to.
        let ok = reorder(THREE, "rect2", Some("text3"), Some(&nodes())).unwrap();
        assert!(ok.contains("t:tween(bar"), "{ok}");

        // Now the other direction: the text moved behind the bar would put it above nothing it
        // reads, so that is allowed too. What is not allowed is the bar going after its script.
        let with_last = THREE.replace(
            "    end)\n",
            "    end)\n    s:rect { x = 0, y = 0, w = 10, h = 10, color = \"#fff\" }\n",
        );
        let mut all = nodes();
        all.push(NodeRef::at("rect4", "rect", 15));
        let err = reorder(&with_last, "rect2", Some("rect4"), Some(&all)).unwrap_err();
        assert!(err.to_string().contains("what moves it is written between"), "{err}");
    }

    #[test]
    fn a_thing_does_not_move_above_what_it_is_made_of() {
        let src = THREE.replace(
            r#"    s:text { x = 48, y = 36, text = "TOP", size = 22 }"#,
            "    local pill = s:rect { x = 0, y = 0, w = 40, h = 20 }\n    s:text { x = 48, y = 36, text = \"TOP\", size = 22, clip_node = pill }",
        );
        let all = vec![
            NodeRef::at("rect1", "rect", 7),
            NodeRef::at("rect2", "rect", 8),
            NodeRef::at("rect3", "rect", 9),
            NodeRef::at("text4", "text", 10),
        ];
        let err = reorder(&src, "text4", None, Some(&all)).unwrap_err();
        assert!(err.to_string().contains("does not exist yet"), "{err}");
    }

    #[test]
    fn putting_a_thing_where_it_already_is_changes_nothing() {
        let same = reorder(THREE, "rect2", Some("rect1"), Some(&nodes())).unwrap();
        assert_eq!(same, THREE);
        let err = reorder(THREE, "rect1", Some("rect1"), Some(&nodes())).unwrap_err();
        assert!(err.to_string().contains("in front of itself"), "{err}");
    }
}

#[cfg(test)]
mod starts {
    use super::*;

    const SCRIPT: &str = r##"local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,

  scene = function(s)
    local bar = s:rect { x = 80, y = 528, w = 0, h = 4 }
    local dot = s:circle { x = 40, y = 40, r = 8 }

    s:script(function(t)
      t:wait(0.15)
      t:tween(bar, 0.4, { w = 640 }, "expoOut")
      t:tween(dot, 0.3, { x = 900 }, "sineOut")
      t:wait(0.2)
      t:tween(bar, 0.5, { w = 100 }, "sineIn")
    end)
  end,
}
"##;

    fn nodes() -> Vec<NodeRef> {
        vec![NodeRef::at("rect1", "rect", 7), NodeRef::at("circle2", "circle", 8)]
    }

    #[test]
    fn a_movement_with_a_wait_before_it_starts_later_by_changing_the_wait() {
        let out = move_tween_start(SCRIPT, "rect1", 0, 0.35, Some(&nodes())).unwrap();
        assert!(out.contains("t:wait(0.5)"), "{out}");
        // And nothing else was touched: the movement itself is the same words.
        assert!(out.contains(r#"t:tween(bar, 0.4, { w = 640 }, "expoOut")"#));
        assert_eq!(out.lines().count(), SCRIPT.lines().count());
    }

    #[test]
    fn it_starts_earlier_the_same_way_and_stops_at_zero() {
        let out = move_tween_start(SCRIPT, "rect1", 0, -0.15, Some(&nodes())).unwrap();
        assert!(out.contains("t:wait(0)"), "{out}");

        // Past the thing in front of it, it is refused, with how far past.
        let err = move_tween_start(SCRIPT, "rect1", 0, -0.9, Some(&nodes())).unwrap_err();
        assert!(err.to_string().contains("0.75s before"), "{err}");
    }

    #[test]
    fn a_movement_with_nothing_before_it_gets_a_wait_of_its_own() {
        // The dot's movement follows the bar's directly: there is no wait to change, so one goes
        // in, on its own line, at the indentation already there.
        let out = move_tween_start(SCRIPT, "circle2", 0, 0.25, Some(&nodes())).unwrap();
        assert!(out.contains("      t:wait(0.25)\n      t:tween(dot,"), "{out}");
        assert_eq!(out.lines().count(), SCRIPT.lines().count() + 1);
    }

    #[test]
    fn and_cannot_start_earlier_than_the_thing_it_follows() {
        let err = move_tween_start(SCRIPT, "circle2", 0, -0.1, Some(&nodes())).unwrap_err();
        assert!(err.to_string().contains("nothing written before it"), "{err}");
    }

    #[test]
    fn the_second_movement_of_a_thing_is_a_different_movement() {
        // The bar moves twice. Moving the second one changes the wait before *it*.
        let out = move_tween_start(SCRIPT, "rect1", 1, 0.3, Some(&nodes())).unwrap();
        assert!(out.contains("t:wait(0.15)"), "the first wait is untouched:\n{out}");
        assert!(out.contains("t:wait(0.5)"), "{out}");

        // And asking for one that is not there says how many there are.
        let err = move_tween_start(SCRIPT, "rect1", 7, 0.3, Some(&nodes())).unwrap_err();
        assert!(err.to_string().contains("there is no #7"), "{err}");
    }

    #[test]
    fn moving_it_nowhere_is_the_same_file() {
        assert_eq!(move_tween_start(SCRIPT, "rect1", 0, 0.0, Some(&nodes())).unwrap(), SCRIPT);
        assert_eq!(lower(SCRIPT, &[], None).unwrap(), SCRIPT);
    }
}
