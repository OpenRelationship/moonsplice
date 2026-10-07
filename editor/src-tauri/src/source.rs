//! The source store: one representation of a composition, and Rust is the only writer.
//!
//! `project-sync` states the rule this file exists to make true: the Lua source *is* the
//! composition, so there is no second copy for the UI to drift from and no save step. An
//! edit is a write. Undo is a stack of source strings, which is why an agent edit across
//! twelve nodes and a one-node drag are both a single entry with no transaction machinery.

use std::path::{Path, PathBuf};

use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::lower::{self, Edit, EditRefusal, NodeRef};

/// Short content hash. The frame cache is keyed on it, so invalidation is free: a different
/// source is a different key and nothing has to be told about anything.
pub fn hash_of(text: &str) -> String {
    let mut h = Sha256::new();
    h.update(text.as_bytes());
    format!("{:x}", h.finalize())[..16].to_string()
}

#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    /// What the step did, in the words a person would use. Drives the undo menu.
    pub label: String,
}

#[derive(Debug)]
pub enum SourceError {
    Io(String),
    Refused(EditRefusal),
    NothingToUndo,
    NothingToRedo,
}

impl std::fmt::Display for SourceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SourceError::Io(m) => write!(f, "{m}"),
            SourceError::Refused(r) => write!(f, "{r}"),
            SourceError::NothingToUndo => write!(f, "there is nothing to undo"),
            SourceError::NothingToRedo => write!(f, "there is nothing to redo"),
        }
    }
}

struct Step {
    text: String,
    label: String,
}

pub struct SourceDoc {
    pub path: PathBuf,
    text: String,
    hash: String,
    undo: Vec<Step>,
    redo: Vec<Step>,
}

/// What one write changed, for the event the UI listens to.
#[derive(Debug, Clone, Serialize)]
pub struct Applied {
    pub hash: String,
    pub what: Vec<String>,
    pub undo_depth: usize,
    pub redo_depth: usize,
}

impl SourceDoc {
    pub fn open(path: &Path) -> Result<SourceDoc, SourceError> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| SourceError::Io(format!("{}: {e}", path.display())))?;
        Ok(SourceDoc {
            path: path.to_path_buf(),
            hash: hash_of(&text),
            text,
            undo: Vec::new(),
            redo: Vec::new(),
        })
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn hash(&self) -> &str {
        &self.hash
    }

    pub fn undo_depth(&self) -> usize {
        self.undo.len()
    }

    pub fn redo_depth(&self) -> usize {
        self.redo.len()
    }

    pub fn undo_label(&self) -> Option<&str> {
        self.undo.last().map(|s| s.label.as_str())
    }

    pub fn redo_label(&self) -> Option<&str> {
        self.redo.last().map(|s| s.label.as_str())
    }

    /// Apply a batch of edits as one step. All of them or none: a refusal leaves the file
    /// exactly as it was, so a half-applied agent turn is not a state the app can reach.
    pub fn apply(
        &mut self,
        edits: &[Edit],
        nodes: Option<&[NodeRef]>,
        names: &std::collections::HashMap<String, String>,
    ) -> Result<Applied, SourceError> {
        if edits.is_empty() {
            return Ok(self.applied(Vec::new()));
        }
        // A thing may be named the way the app names it. The agent reads those names and asks
        // in them; the UI sends ids. Resolving here rather than in the caller is deliberate:
        // it was in one caller and the other forgot, which a live model found immediately --
        // "the same `Block 2` name is being rejected as missing, even though `at` finds it".
        let edits: Vec<Edit> = edits
            .iter()
            .cloned()
            .map(|mut e| {
                let asked = e.node().to_string();
                if let Some(node) = e.node_mut() {
                    *node = crate::words::resolve(names, &asked);
                }
                // And the property, for the same reason: the agent reads "visibility" and has
                // to be able to ask in it, or it says `opacity` to the person instead.
                if let Some(key) = e.key_mut() {
                    if let Some(real) = crate::words::prop_key(key) {
                        *key = real;
                    }
                }
                e
            })
            .collect();
        let edits = &edits[..];
        let next = lower::lower(&self.text, edits, nodes).map_err(SourceError::Refused)?;
        let what: Vec<String> = edits.iter().map(|e| e.describe(names)).collect();
        let label = summarise(&what);
        self.commit(next, label)?;
        Ok(self.applied(what))
    }

    fn commit(&mut self, next: String, label: String) -> Result<(), SourceError> {
        if next == self.text {
            return Ok(()); // a no-op write is not an undo step
        }
        write_atomically(&self.path, &next)?;
        self.undo.push(Step {
            text: std::mem::replace(&mut self.text, next),
            label,
        });
        self.redo.clear();
        self.hash = hash_of(&self.text);
        Ok(())
    }

    pub fn undo(&mut self) -> Result<Applied, SourceError> {
        let step = self.undo.pop().ok_or(SourceError::NothingToUndo)?;
        write_atomically(&self.path, &step.text)?;
        let current = std::mem::replace(&mut self.text, step.text);
        self.redo.push(Step {
            text: current,
            label: step.label.clone(),
        });
        self.hash = hash_of(&self.text);
        Ok(self.applied(vec![format!("undid: {}", step.label)]))
    }

    pub fn redo(&mut self) -> Result<Applied, SourceError> {
        let step = self.redo.pop().ok_or(SourceError::NothingToRedo)?;
        write_atomically(&self.path, &step.text)?;
        let current = std::mem::replace(&mut self.text, step.text);
        self.undo.push(Step {
            text: current,
            label: step.label.clone(),
        });
        self.hash = hash_of(&self.text);
        Ok(self.applied(vec![format!("redid: {}", step.label)]))
    }

    /// A write that happened outside the app. There is one representation, so this is a
    /// re-read rather than a merge — the third writer needs no machinery of its own.
    /// Returns `None` when the bytes are the ones we already hold, which is what makes the
    /// watcher safe to fire on our own writes.
    pub fn adopt_from_disk(&mut self) -> Result<Option<Applied>, SourceError> {
        let text = std::fs::read_to_string(&self.path)
            .map_err(|e| SourceError::Io(format!("{}: {e}", self.path.display())))?;
        if text == self.text {
            return Ok(None);
        }
        self.undo.push(Step {
            text: std::mem::replace(&mut self.text, text),
            label: "a change from outside the app".into(),
        });
        self.redo.clear();
        self.hash = hash_of(&self.text);
        Ok(Some(self.applied(vec!["changed outside the app".into()])))
    }

    fn applied(&self, what: Vec<String>) -> Applied {
        Applied {
            hash: self.hash.clone(),
            what,
            undo_depth: self.undo.len(),
            redo_depth: self.redo.len(),
        }
    }
}

fn summarise(what: &[String]) -> String {
    match what.len() {
        0 => "nothing".into(),
        1 => what[0].clone(),
        n => format!("{} and {} more change(s)", what[0], n - 1),
    }
}

/// Write through a sibling temp file and rename. A half-written composition is a comp that
/// will not load, and the watcher would pick it up.
fn write_atomically(path: &Path, text: &str) -> Result<(), SourceError> {
    let tmp = path.with_extension("lua.moonsplice-tmp");
    std::fs::write(&tmp, text).map_err(|e| SourceError::Io(format!("{}: {e}", tmp.display())))?;
    std::fs::rename(&tmp, path).map_err(|e| SourceError::Io(format!("{}: {e}", path.display())))
}

#[cfg(test)]
mod tests;
