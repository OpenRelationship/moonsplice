use super::*;

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

pub(super) fn ctor_re() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(\w+)\s*:\s*(\w+)\s*(\{)").unwrap())
}

pub(super) fn tween_re() -> &'static Regex {
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
    pub(super) spans: Vec<Span>,
    pub(super) of_node: std::collections::HashMap<String, usize>,
    pub(super) shared: std::collections::HashMap<usize, usize>,
    pub(super) known: Vec<String>,
}

pub(super) fn line_of(src: &str, byte: usize) -> u32 {
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
