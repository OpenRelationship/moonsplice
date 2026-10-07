//! The words the app is allowed to use out loud.
//!
//! Everything the engine reports is code: a node is `rect2`, a property is `x`, a curve is
//! `expoOut`. None of those may reach a person. The brief is explicit about it — this app is
//! for people who do not want to see code, file names or extensions — and a notice reading
//! "set x on rect2 to 11.0" breaks it in the one place a person is guaranteed to look, which is
//! the line telling them what just happened.
//!
//! The words themselves live in `editor/vocabulary.json`, which `src/format.ts` reads too.
//! They were two tables until they drifted -- the timeline called a curve "Soft stop" while a
//! notice called the same curve "Easing out" -- so there is one file and both sides read it.

use std::collections::HashMap;
use std::sync::OnceLock;

/// The vocabulary, as shipped. Compiled in, so a release has no file to lose.
fn vocab() -> &'static serde_json::Value {
    static V: OnceLock<serde_json::Value> = OnceLock::new();
    V.get_or_init(|| {
        serde_json::from_str(include_str!("../../vocabulary.json"))
            .expect("vocabulary.json is part of the build")
    })
}

fn look(table: &str, key: &str) -> Option<String> {
    vocab()[table][key].as_str().map(str::to_string)
}

/// What a property is called. Unknown keys come back as themselves, spaced out, which is still
/// better than `strokeWidth`.
pub fn property(key: &str) -> String {
    look("property", key).unwrap_or_else(|| spaced(key))
}

/// A property said out loud, or `None` when the vocabulary has no word for it. That case is worth
/// saying differently rather than echoing the key: a refusal that names `z` has shown code, and
/// the honest sentence is that there is no such thing on that node.
pub fn property_said(key: &str) -> Option<String> {
    look("property", key).map(|w| w.to_lowercase())
}

/// What a kind of thing is called.
pub fn kind(k: &str) -> String {
    look("kind", k).unwrap_or_else(|| spaced(k))
}

/// What a curve is called. These are the words the timeline shows, so an undo label and the
/// menu a person picked from agree.
pub fn curve(ease: &str) -> String {
    look("curve", ease).unwrap_or_else(|| spaced(ease))
}

/// The way back: a word (or the renderer's own name) to the name the renderer honours. `None`
/// for anything that is neither, so it can be refused rather than written down.
///
/// The closed list is the point. A live model, reading "arriving" in the outline, passed
/// "arriving" back as the curve -- and an easing name nothing recognises is a change that
/// renders identically while the person is told it worked.
pub fn ease(asked: &str) -> Option<String> {
    let want = asked.trim().to_lowercase();
    let table = vocab()["curve"].as_object()?;
    if let Some(name) = table.keys().find(|k| k.to_lowercase() == want) {
        return Some(name.clone());
    }
    table
        .iter()
        .find(|(_, word)| word.as_str().map(str::to_lowercase).as_deref() == Some(want.as_str()))
        .map(|(name, _)| name.clone())
}

/// The way back for a property: a word (or the engine's own key) to the key the renderer reads.
/// `None` for anything that is neither.
///
/// Symmetric with `ease`, and for the same reason. The agent reads "visibility" in the outline;
/// if it can only ask in `opacity` it will say `opacity` to the person, which it did.
pub fn prop_key(asked: &str) -> Option<String> {
    let want = asked.trim().to_lowercase();
    let table = vocab()["property"].as_object()?;
    if let Some(key) = table.keys().find(|k| k.to_lowercase() == want) {
        return Some(key.clone());
    }
    table
        .iter()
        .find(|(_, word)| word.as_str().map(str::to_lowercase).as_deref() == Some(want.as_str()))
        .map(|(key, _)| key.clone())
}

/// The property words worth offering, for a tool schema and for a refusal. The ones the
/// inspector shows, in the order it shows them.
pub fn prop_words() -> Vec<String> {
    [
        "x", "y", "w", "h", "r", "rx", "size", "opacity", "rotation", "scale", "color", "text",
        "tracking",
    ]
    .iter()
    .filter_map(|k| look("property", k))
    .collect()
}

/// The words a person may ask for, so a refusal can offer the alternatives. Menu order, which
/// is the order the timeline offers them in.
pub fn curve_words() -> Vec<String> {
    let menu = vocab()["curveMenu"].as_array().cloned().unwrap_or_default();
    menu.iter()
        .filter_map(|v| v.as_str())
        .map(curve)
        .collect()
}

/// `effect_hueRotate` -> `Hue rotate`. The fallback, never the plan: a key with no word of its
/// own is still shown as words, never as the identifier a programmer typed. Same rule as
/// `spaced` in `format.ts`.
fn spaced(k: &str) -> String {
    let stripped = k.strip_prefix("effect_").unwrap_or(k);
    let mut out = String::with_capacity(stripped.len() + 4);
    let mut prev: Option<char> = None;
    for c in stripped.chars() {
        if c == '_' || c == '-' {
            if !out.ends_with(' ') {
                out.push(' ');
            }
        } else {
            if c.is_ascii_uppercase()
                && prev.is_some_and(|p| p.is_ascii_lowercase() || p.is_ascii_digit())
            {
                out.push(' ');
                out.push(c.to_ascii_lowercase());
            } else {
                out.push(c);
            }
        }
        prev = Some(c);
    }
    let mut chars = out.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => out,
    }
}

/// What to call each thing in a composition, unambiguously.
///
/// A label if it has one, otherwise the kind; and when that would give two things the same name,
/// they are numbered the way a person would say it out loud. Same rule as `names` in
/// `format.ts`, so the notice and the timeline lane agree on what a thing is called.
pub fn names(outline: &serde_json::Value) -> HashMap<String, String> {
    let nodes = match outline["nodes"].as_array() {
        Some(a) => a,
        None => return HashMap::new(),
    };
    let base_of = |n: &serde_json::Value| -> String {
        let label = n["label"].as_str().map(str::trim).unwrap_or("");
        if !label.is_empty() {
            return label.to_string();
        }
        kind(n["kind"].as_str().unwrap_or(""))
    };

    let mut count: HashMap<String, usize> = HashMap::new();
    for n in nodes {
        *count.entry(base_of(n)).or_insert(0) += 1;
    }
    let mut seen: HashMap<String, usize> = HashMap::new();
    let mut out = HashMap::new();
    for n in nodes {
        let id = match n["id"].as_str() {
            Some(i) => i,
            None => continue,
        };
        let base = base_of(n);
        if count.get(&base).copied().unwrap_or(0) < 2 {
            out.insert(id.to_string(), base);
            continue;
        }
        let nth = seen.entry(base.clone()).or_insert(0);
        *nth += 1;
        out.insert(id.to_string(), format!("{base} {nth}"));
    }
    out
}

/// What to call one thing, falling back to something sayable rather than to its id.
pub fn name_of(names: &HashMap<String, String>, id: &str) -> String {
    names.get(id).cloned().unwrap_or_else(|| "that thing".into())
}

/// The way back. Since the agent reads names, it asks for changes by name, and a name has to
/// become the id the lowering aligns on.
///
/// An id still works -- the UI sends those -- and anything that matches neither is passed
/// through untouched, so the refusal quotes what was actually asked for rather than something
/// this function guessed.
pub fn resolve(names: &HashMap<String, String>, asked: &str) -> String {
    if names.contains_key(asked) {
        return asked.to_string();
    }
    let fold = |s: &str| s.trim().to_lowercase();
    let want = fold(asked);
    if let Some((id, _)) = names.iter().find(|(_, n)| fold(n) == want) {
        return id.clone();
    }
    // "Block" when there is a Block 1 and a Block 2 is ambiguous, and guessing which would be
    // the wrong kind of helpful. Only an exact single match counts.
    let mut hits = names.iter().filter(|(_, n)| fold(n).starts_with(&want));
    match (hits.next(), hits.next()) {
        (Some((id, _)), None) => id.clone(),
        _ => asked.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outline(nodes: serde_json::Value) -> serde_json::Value {
        serde_json::json!({ "nodes": nodes })
    }

    #[test]
    fn a_thing_with_a_label_is_called_by_it() {
        let o = outline(serde_json::json!([
            { "id": "text5", "kind": "text", "label": "EDITOR" },
            { "id": "rect2", "kind": "rect", "label": null },
        ]));
        let n = names(&o);
        assert_eq!(n["text5"], "EDITOR");
        assert_eq!(n["rect2"], "Block");
    }

    #[test]
    fn two_things_that_would_share_a_name_are_numbered() {
        let o = outline(serde_json::json!([
            { "id": "rect2", "kind": "rect" },
            { "id": "rect4", "kind": "rect" },
            { "id": "text1", "kind": "text", "label": "Title" },
        ]));
        let n = names(&o);
        assert_eq!(n["rect2"], "Block 1");
        assert_eq!(n["rect4"], "Block 2");
        assert_eq!(n["text1"], "Title");
    }

    #[test]
    fn a_curve_reads_and_writes_the_same_table() {
        assert_eq!(curve("expoOut"), "Arriving");
        assert_eq!(ease("Arriving").as_deref(), Some("expoOut"));
        assert_eq!(ease("arriving").as_deref(), Some("expoOut"));
        // The renderer's own name still works, because the timeline menu sends those.
        assert_eq!(ease("expoOut").as_deref(), Some("expoOut"));
        // And a word for no curve is nothing, so it gets refused rather than written down.
        assert_eq!(ease("gently"), None);
        assert_eq!(ease("swooshy"), None);
        // Every word in the shipped vocabulary maps back to the name it came from.
        let table = vocab()["curve"].as_object().unwrap();
        assert!(table.len() > 15, "the vocabulary looks empty");
        for (name, word) in table {
            let word = word.as_str().unwrap();
            assert_eq!(ease(word).as_deref(), Some(name.as_str()), "{word}");
            assert_eq!(curve(name), word);
        }
    }

    #[test]
    fn a_property_reads_and_writes_the_same_table() {
        assert_eq!(property("opacity"), "Visibility");
        assert_eq!(prop_key("Visibility").as_deref(), Some("opacity"));
        assert_eq!(prop_key("visibility").as_deref(), Some("opacity"));
        assert_eq!(prop_key("across").as_deref(), Some("x"));
        // The engine's own key still works, because that is what the UI sends.
        assert_eq!(prop_key("opacity").as_deref(), Some("opacity"));
        // And a word for nothing is nothing.
        assert_eq!(prop_key("vibe"), None);
        assert!(prop_words().iter().any(|w| w == "Visibility"));
    }

    #[test]
    fn a_name_becomes_the_id_the_lowering_needs() {
        let o = outline(serde_json::json!([
            { "id": "rect2", "kind": "rect" },
            { "id": "rect4", "kind": "rect" },
            { "id": "text5", "kind": "text", "label": "EDITOR" },
        ]));
        let n = names(&o);
        assert_eq!(resolve(&n, "EDITOR"), "text5");
        assert_eq!(resolve(&n, "editor"), "text5");
        assert_eq!(resolve(&n, "Block 2"), "rect4");
        // An id still works, because that is what the UI sends.
        assert_eq!(resolve(&n, "rect2"), "rect2");
        // "Block" could be either, so it stays what it was and gets refused by name.
        assert_eq!(resolve(&n, "Block"), "Block");
        assert_eq!(resolve(&n, "nothing like this"), "nothing like this");
    }

    #[test]
    fn an_unknown_property_is_still_not_code() {
        assert_eq!(property("strokeWidth"), "Stroke width");
        assert_eq!(property("effect_hueRotate"), "Hue rotate");
        assert_eq!(property("x"), "Across");
        assert_eq!(curve("expoOut"), "Arriving");
        assert_eq!(kind("rect"), "Block");
    }

    /// The rule the whole vocabulary exists for.
    #[test]
    fn nothing_it_says_looks_like_code() {
        let codey = |s: &str| {
            s.contains('_')
                || s.chars().any(|c| c == ':' || c == '.' || c == '(')
                || s.chars().zip(s.chars().skip(1)).any(|(a, b)| {
                    a.is_ascii_lowercase() && b.is_ascii_uppercase()
                })
        };
        for k in [
            "x", "y", "w", "h", "opacity", "rotation", "size", "color", "text", "tracking",
            "strokeWidth", "some_odd_key",
        ] {
            let said = property(k);
            assert!(!codey(&said), "property({k}) said {said}");
        }
        for e in [
            "linear", "expoOut", "sineInOut", "bounceOut", "elasticOut", "somethingNew",
        ] {
            let said = curve(e);
            assert!(!codey(&said), "curve({e}) said {said}");
        }
        for k in ["rect", "text", "tts", "captions", "brandNewKind"] {
            let said = kind(k);
            assert!(!codey(&said), "kind({k}) said {said}");
        }
    }
}
