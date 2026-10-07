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

mod fields;
mod layout;
mod moves;
mod refusal;
mod statements;

pub use fields::*;
pub use layout::*;
pub use moves::*;
pub use refusal::*;
pub use statements::*;

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
mod tests;

#[cfg(test)]
mod razor;

#[cfg(test)]
mod stack;

#[cfg(test)]
mod starts;
