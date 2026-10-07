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
mod tests {
    /// These tests are about the bytes, not the wording, so they name nothing.
    fn no_names() -> std::collections::HashMap<String, String> {
        std::collections::HashMap::new()
    }

    use super::*;
    use tempfile::tempdir;

    const SRC: &str = "local e = require(\"moonsplice\")\n\nreturn e.comp {\n  width = 1280, height = 720, duration = 2, fps = 30,\n  scene = function(s)\n    local bar = s:rect { x = 10, y = 20, w = 4, h = 4 }\n    s:script(function(t)\n      t:tween(bar, 0.4, { w = 64 }, \"expoOut\")\n    end)\n  end,\n}\n";

    fn doc() -> (tempfile::TempDir, SourceDoc) {
        let dir = tempdir().unwrap();
        let p = dir.path().join("hero.lua");
        std::fs::write(&p, SRC).unwrap();
        let d = SourceDoc::open(&p).unwrap();
        (dir, d)
    }

    #[test]
    fn opening_and_closing_with_no_edit_leaves_the_bytes_alone() {
        let (dir, d) = doc();
        drop(d);
        assert_eq!(std::fs::read_to_string(dir.path().join("hero.lua")).unwrap(), SRC);
    }

    #[test]
    fn an_edit_is_a_write_with_no_save_step() {
        let (dir, mut d) = doc();
        d.apply(
            &[Edit::SetProp {
                node: "rect1".into(),
                key: "x".into(),
                value: serde_json::json!(40),
            }],
            None,
            &no_names(),
        )
        .unwrap();
        let on_disk = std::fs::read_to_string(dir.path().join("hero.lua")).unwrap();
        assert!(on_disk.contains("x = 40,"));
        assert_eq!(on_disk, d.text());
    }

    #[test]
    fn twelve_changes_in_one_turn_undo_as_one_step() {
        let (_dir, mut d) = doc();
        let edits: Vec<Edit> = (0..12)
            .map(|i| Edit::SetProp {
                node: "rect1".into(),
                key: "x".into(),
                value: serde_json::json!(i),
            })
            .collect();
        let applied = d.apply(&edits, None, &no_names()).unwrap();
        assert_eq!(applied.undo_depth, 1);
        assert_eq!(applied.what.len(), 12);
        d.undo().unwrap();
        assert_eq!(d.text(), SRC);
    }

    #[test]
    fn a_refusal_leaves_the_file_untouched() {
        let (dir, mut d) = doc();
        let err = d
            .apply(
                &[
                    Edit::SetProp {
                        node: "rect1".into(),
                        key: "x".into(),
                        value: serde_json::json!(99),
                    },
                    Edit::SetProp {
                        node: "ghost".into(),
                        key: "x".into(),
                        value: serde_json::json!(1),
                    },
                ],
                None,
                &no_names(),
            )
            .unwrap_err();
        assert!(matches!(err, SourceError::Refused(_)));
        assert_eq!(std::fs::read_to_string(dir.path().join("hero.lua")).unwrap(), SRC);
        assert_eq!(d.undo_depth(), 0);
    }

    #[test]
    fn undo_then_redo_returns_the_same_bytes() {
        let (_dir, mut d) = doc();
        d.apply(
            &[Edit::SetEase {
                node: "rect1".into(),
                ease: "sineOut".into(),
                occurrence: 0,
            }],
            None,
            &no_names(),
        )
        .unwrap();
        let after = d.text().to_string();
        d.undo().unwrap();
        assert_eq!(d.text(), SRC);
        d.redo().unwrap();
        assert_eq!(d.text(), after);
    }

    #[test]
    fn the_hash_changes_with_the_bytes_and_nothing_else() {
        let (_dir, mut d) = doc();
        let before = d.hash().to_string();
        d.apply(&[], None, &no_names()).unwrap();
        assert_eq!(d.hash(), before, "an empty edit is not a change");
        d.apply(
            &[Edit::SetProp {
                node: "rect1".into(),
                key: "y".into(),
                value: serde_json::json!(21),
            }],
            None,
            &no_names(),
        )
        .unwrap();
        assert_ne!(d.hash(), before);
    }

    #[test]
    fn an_outside_edit_is_adopted_without_a_merge() {
        let (dir, mut d) = doc();
        let p = dir.path().join("hero.lua");
        std::fs::write(&p, SRC.replace("y = 20", "y = 200")).unwrap();
        let applied = d.adopt_from_disk().unwrap().expect("a change");
        assert!(d.text().contains("y = 200"));
        assert_eq!(applied.undo_depth, 1);
        // and firing again on the same bytes is a no-op, so our own writes are safe
        assert!(d.adopt_from_disk().unwrap().is_none());
    }

    #[test]
    fn the_undo_label_reads_like_a_person_wrote_it() {
        let (_dir, mut d) = doc();
        d.apply(
            &[Edit::SetTweenDuration {
                node: "rect1".into(),
                seconds: 1.5,
                occurrence: 0,
            }],
            None,
            &no_names(),
        )
        .unwrap();
        // With nothing named it still says something sayable rather than an id.
        assert_eq!(d.undo_label(), Some("made that thing's move 1.5s long"));

        // And given the outline, it uses what the timeline calls the thing.
        let (_dir2, mut e) = doc();
        let named = crate::words::names(&serde_json::json!({
            "nodes": [{ "id": "rect1", "kind": "rect", "label": null }]
        }));
        e.apply(
            &[Edit::SetTweenDuration {
                node: "rect1".into(),
                seconds: 1.5,
                occurrence: 0,
            }],
            None,
            &named,
        )
        .unwrap();
        let label = e.undo_label().unwrap().to_string();
        assert_eq!(label, "made Block's move 1.5s long");
        assert!(!label.contains("rect1"), "the label leaked a node id: {label}");
    }

    /// A name is as good as an id, whoever is asking. The agent only ever sees names; if the
    /// resolution lives in the caller instead of here, one caller forgets and the agent is told
    /// the thing it can plainly see does not exist.
    #[test]
    fn a_thing_can_be_named_the_way_the_app_names_it() {
        let (_dir, mut d) = doc();
        let named = crate::words::names(&serde_json::json!({
            "nodes": [{ "id": "rect1", "kind": "rect", "label": null }]
        }));
        let by_name = d.apply(
            &[Edit::SetTweenDuration {
                node: "Block".into(),
                seconds: 0.8,
                occurrence: 0,
            }],
            None,
            &named,
        );
        assert!(by_name.is_ok(), "a name was refused: {by_name:?}");

        // And a name for nothing is still refused, quoting what was asked rather than a guess.
        let nonsense = d.apply(
            &[Edit::SetTweenDuration {
                node: "The Widget".into(),
                seconds: 0.8,
                occurrence: 0,
            }],
            None,
            &named,
        );
        let why = format!("{:?}", nonsense.unwrap_err());
        assert!(why.contains("The Widget"), "{why}");
    }

    /// The rule, over every verb: nothing the app says about a change contains a node id, a
    /// property key or an easing name. This is the brief -- the person using this app does not
    /// want to see code -- and the undo label is where code leaks first.
    #[test]
    fn no_verb_says_anything_that_looks_like_code() {
        let named = crate::words::names(&serde_json::json!({
            "nodes": [
                { "id": "rect1", "kind": "rect", "label": null },
                { "id": "text2", "kind": "text", "label": "EDITOR" },
                { "id": "cap3", "kind": "captions", "label": "Hold the cut." }
            ]
        }));
        let edits = vec![
            Edit::SetProp {
                node: "rect1".into(),
                key: "opacity".into(),
                value: serde_json::json!(0.5),
            },
            Edit::SetEase {
                node: "text2".into(),
                ease: "expoOut".into(),
                occurrence: 0,
            },
            Edit::SetTweenDuration {
                node: "rect1".into(),
                seconds: 0.8,
                occurrence: 0,
            },
            Edit::SetCue {
                node: "cap3".into(),
                index: 1,
                t0: None,
                t1: None,
                text: Some("Let it land.".into()),
            },
            Edit::PinProp {
                node: "text2".into(),
                key: "x".into(),
                t: 1.0,
                value: serde_json::json!(96),
                covered: false,
            },
        ];
        for edit in &edits {
            let said = edit.describe(&named);
            for code in ["rect1", "text2", "cap3", "opacity", "expoOut", " x "] {
                assert!(
                    !said.contains(code),
                    "`{said}` contains `{code}`, which is code"
                );
            }
            eprintln!("  {said}");
        }
    }
}
