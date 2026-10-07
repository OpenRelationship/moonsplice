use super::*;

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
