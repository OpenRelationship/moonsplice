//! Connections: other people's apps, reached through connectory (.robot/docs/connect.robot).
//!
//! The command line owns the rows (`./moonsplice connect`, core/cli/connect.lua): the asks an
//! agent raised, the person's approvals, the services connected. This side only asks it, and adds
//! the one thing a command line cannot do for a window: take a credential from a masked field and
//! put it in the keychain. A value goes from the window to the keychain and nowhere else. It is
//! never returned, logged, written to a row or handed to the command line, which is told only
//! that the fields are stored (`--record`) and checks for itself.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use crate::engine;

/// The keychain service the command line reads (core/connect/store.lua), so connecting in the
/// app works at the terminal too. The account is the field's name: `GITHUB_TOKEN`.
const KEYCHAIN: &str = "moonsplice";

/// A list inside a row. Lua's JSON cannot tell an empty array from an empty object, so `{}` is
/// an empty list wherever a list is expected.
fn list<'de, D: serde::Deserializer<'de>, T: DeserializeOwned>(d: D) -> Result<Vec<T>, D::Error> {
    match serde_json::Value::deserialize(d)? {
        serde_json::Value::Object(o) if o.is_empty() => Ok(Vec::new()),
        serde_json::Value::Null => Ok(Vec::new()),
        v => serde_json::from_value(v).map_err(serde::de::Error::custom),
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Field {
    pub name: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub secret: bool,
}

/// Something an agent is waiting on the person for: a service to connect, or a call to allow.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConnectAsk {
    pub id: String,
    pub kind: String,
    pub service: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub op: Option<String>,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default, deserialize_with = "list")]
    pub fields: Vec<Field>,
    #[serde(default)]
    pub docs: Option<String>,
    #[serde(default)]
    pub why: Option<String>,
    #[serde(default)]
    pub at: Option<String>,
    #[serde(default)]
    pub status: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Connection {
    pub service: String,
    #[serde(default, deserialize_with = "list")]
    pub fields: Vec<String>,
    #[serde(default)]
    pub at: Option<String>,
}

/// What connecting a service takes: its fields, and which of them the keychain lacks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Needs {
    pub service: String,
    pub name: String,
    #[serde(default)]
    pub docs: Option<String>,
    #[serde(default, deserialize_with = "list")]
    pub fields: Vec<Field>,
    #[serde(default, deserialize_with = "list")]
    pub missing: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Found {
    pub service: String,
    pub name: String,
    #[serde(default, deserialize_with = "list")]
    pub categories: Vec<String>,
    #[serde(default)]
    pub operations: u64,
    #[serde(default)]
    pub docs: Option<String>,
}

/// The command line's answer once the fields are stored: connected, and whether the service's
/// own test call passed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Recorded {
    pub service: String,
    #[serde(default, deserialize_with = "list")]
    pub fields: Vec<String>,
    #[serde(default)]
    pub checked: bool,
    /// The service's own test call: "passed", "failed" or "none" (the directory knows none).
    #[serde(default)]
    pub test: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub test_message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Answered {
    pub service: String,
    pub op: String,
    pub answer: String,
}

// ------------------------------------------------------------------------- the command line

/// A service's name as the directory spells it. Checked before it becomes an argument or a
/// path, so `../../etc` is neither.
fn service_name(s: &str) -> Result<&str, String> {
    let ok = !s.is_empty()
        && s.len() <= 80
        && s.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
        && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
        && !s.contains("..");
    if ok { Ok(s) } else { Err(format!("{s:?} is not a service in the directory")) }
}

/// An operation is `service.call_name`; it must belong to the service it is answered for.
fn op_name<'a>(service: &str, op: &'a str) -> Result<&'a str, String> {
    let ok = op.strip_prefix(service).is_some_and(|rest| rest.starts_with('.') && rest.len() > 1)
        && op.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/'));
    if ok { Ok(op) } else { Err(format!("{op:?} is not a call {service} has")) }
}

fn answer_flag(answer: &str) -> Result<&'static str, String> {
    match answer {
        "once" => Ok("--once"),
        "always" => Ok("--always"),
        "deny" => Ok("--deny"),
        _ => Err(format!("{answer:?} is not an answer; it is once, always or deny")),
    }
}

fn root() -> Result<PathBuf, String> {
    engine::moonsplice_root().ok_or_else(|| "the Moonsplice engine is not next to this app".into())
}

/// `./moonsplice connect ARGS --json`, with no terminal: the command line refuses to take a
/// credential or an approval from anything but its person, and this is not them.
fn connect(args: &[&str]) -> Result<String, String> {
    let root = root()?;
    let out = Command::new(root.join("moonsplice"))
        .arg("connect")
        .args(args)
        .arg("--json")
        .current_dir(&root)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("the connect command did not start ({e})"))?;
    if !out.status.success() {
        return Err(said(&String::from_utf8_lossy(&out.stderr)));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The command line's own sentence, without its name in front.
fn said(stderr: &str) -> String {
    let last = stderr.lines().map(str::trim).filter(|l| !l.is_empty()).last().unwrap_or("");
    let s = last.strip_prefix("moonsplice connect: ").unwrap_or(last);
    if s.is_empty() { "the connect command failed".into() } else { s.to_string() }
}

/// Rows. The command line's JSON writes an empty array as `{}`, so that is none too.
fn rows<T: DeserializeOwned>(text: &str) -> Result<Vec<T>, String> {
    let v: serde_json::Value = serde_json::from_str(text.trim())
        .map_err(|e| format!("the connect command said something that is not rows ({e})"))?;
    match v {
        serde_json::Value::Object(o) if o.is_empty() => Ok(Vec::new()),
        serde_json::Value::Null => Ok(Vec::new()),
        v => serde_json::from_value(v).map_err(|e| format!("those rows are not the shape expected ({e})")),
    }
}

fn one<T: DeserializeOwned>(text: &str) -> Result<T, String> {
    serde_json::from_str(text.trim()).map_err(|e| format!("the connect command's answer did not read ({e})"))
}

/// The fields to store, checked against what the service takes before anything is written. A
/// name it does not take is refused rather than stored under a name nothing reads.
fn to_store<'a>(needs: &Needs, values: &'a BTreeMap<String, String>) -> Result<Vec<(&'a str, &'a str)>, String> {
    let mut out = Vec::new();
    for (name, value) in values {
        if !needs.fields.iter().any(|f| &f.name == name) {
            return Err(format!("{} does not take a field called {name}", needs.name));
        }
        if value.trim().is_empty() {
            let label = needs.fields.iter().find(|f| &f.name == name).map(|f| f.label.as_str());
            return Err(format!("nothing was given for {}", label.unwrap_or(name)));
        }
        out.push((name.as_str(), value.as_str()));
    }
    if out.is_empty() {
        return Err(format!("nothing was given to connect {}", needs.name));
    }
    Ok(out)
}

fn needs_now(service: &str) -> Result<Needs, String> {
    one(&connect(&["--needs", service_name(service)?])?)
}

/// Store each field, then have the command line check they are there and record the
/// connection. `write` is the keychain; the tests give it something else.
fn save_with(
    service: &str,
    values: &BTreeMap<String, String>,
    needs: &Needs,
    mut write: impl FnMut(&str, &str) -> Result<(), String>,
) -> Result<(), String> {
    service_name(service)?;
    if needs.service != service {
        return Err(format!("those fields are {}'s, not {service}'s", needs.service));
    }
    for (name, value) in to_store(needs, values)? {
        write(name, value)?;
    }
    Ok(())
}

/// A value for `security -i`, which reads its commands from stdin and parses double quotes with
/// backslash escapes.
pub(crate) fn quoted(v: &str) -> String {
    format!("\"{}\"", v.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Through `security -i` on its stdin, as the command line's store does (core/connect/store.lua): the
/// value is never an argument, and the item trusts `security`, so the command line reads it with no
/// prompt. `MOONSPLICE_KEYCHAIN` names a keychain file in tests.
pub(crate) fn keychain_write(name: &str, value: &str) -> Result<(), String> {
    use std::io::Write;
    let keychain = std::env::var("MOONSPLICE_KEYCHAIN").ok().filter(|k| !k.is_empty());
    let line = format!(
        "add-generic-password -U -s {} -a {} -l {} -w {}{}\n",
        quoted(KEYCHAIN),
        quoted(name),
        quoted(&format!("Moonsplice: {name}")),
        quoted(value),
        keychain.map(|k| format!(" {}", quoted(&k))).unwrap_or_default()
    );
    let mut child = std::process::Command::new("security")
        .arg("-i")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("the keychain did not store {name} ({e})"))?;
    child
        .stdin
        .take()
        .ok_or_else(|| format!("the keychain did not store {name}"))?
        .write_all(line.as_bytes())
        .map_err(|e| format!("the keychain did not store {name} ({e})"))?;
    let status = child.wait().map_err(|e| format!("the keychain did not store {name} ({e})"))?;
    if !status.success() {
        return Err(format!("the keychain did not store {name}"));
    }
    Ok(())
}

/// Off the window's thread: every one of these starts a process.
async fn off<T: Send + 'static>(f: impl FnOnce() -> Result<T, String> + Send + 'static) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(f).await.map_err(|e| format!("that did not finish ({e})"))?
}

// ------------------------------------------------------------------------------ commands

/// What agents are waiting on the person for.
#[tauri::command]
pub async fn connect_asks() -> Result<Vec<ConnectAsk>, String> {
    off(|| rows(&connect(&["--asks"])?)).await
}

#[tauri::command]
pub async fn connect_list() -> Result<Vec<Connection>, String> {
    off(|| rows(&connect(&["--list"])?)).await
}

#[tauri::command]
pub async fn connect_needs(service: String) -> Result<Needs, String> {
    off(move || needs_now(&service)).await
}

#[tauri::command]
pub async fn connect_find(words: String) -> Result<Vec<Found>, String> {
    off(move || {
        let words: Vec<&str> = words.split_whitespace().collect();
        if words.is_empty() {
            return Ok(Vec::new());
        }
        let mut args = vec!["--find"];
        args.extend(words);
        rows(&connect(&args)?)
    })
    .await
}

/// The person's fields, into the keychain, then recorded. Nothing comes back but the record.
#[tauri::command]
pub async fn connect_save(service: String, values: BTreeMap<String, String>) -> Result<Recorded, String> {
    off(move || {
        let needs = needs_now(&service)?;
        save_with(&service, &values, &needs, keychain_write)?;
        drop(values);
        one(&connect(&["--record", &service])?)
    })
    .await
}

#[tauri::command]
pub async fn connect_answer(service: String, op: String, answer: String) -> Result<Answered, String> {
    off(move || {
        let service = service_name(&service)?;
        let args = ["--approve", service, op_name(service, &op)?, "--from-app", answer_flag(&answer)?];
        one(&connect(&args)?)
    })
    .await
}

#[tauri::command]
pub async fn connect_forget(service: String) -> Result<(), String> {
    off(move || {
        let root = root()?;
        let out = Command::new(root.join("moonsplice"))
            .args(["connect", "--forget", service_name(&service)?])
            .current_dir(&root)
            .stdin(Stdio::null())
            .output()
            .map_err(|e| format!("the connect command did not start ({e})"))?;
        if out.status.success() { Ok(()) } else { Err(said(&String::from_utf8_lossy(&out.stderr))) }
    })
    .await
}

/// A service's logo, as SVG text, or nothing when the directory has none.
#[tauri::command]
pub async fn connect_logo(service: String) -> Result<Option<String>, String> {
    off(move || {
        let path = root()?.join("submodules/connectory/providers").join(service_name(&service)?).join("logo.svg");
        Ok(std::fs::read_to_string(path).ok())
    })
    .await
}

/// The service's documentation, in the person's browser. The address comes from the directory,
/// never from the window, so the window cannot open anything else with it.
#[tauri::command]
pub async fn connect_docs(service: String) -> Result<(), String> {
    off(move || {
        let docs = needs_now(&service)?.docs.unwrap_or_default();
        if !(docs.starts_with("https://") || docs.starts_with("http://")) {
            return Err("the directory has no documentation address for that service".into());
        }
        Command::new("open").arg(&docs).status().map_err(|e| format!("the browser did not open ({e})"))?;
        Ok(())
    })
    .await
}

#[cfg(test)]
mod tests;
