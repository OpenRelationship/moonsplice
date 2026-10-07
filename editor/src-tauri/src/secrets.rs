//! Keys, in the system keychain and nowhere else.
//!
//! No key reaches the frontend, and none is written into the project. The UI asks whether one
//! is set; it never asks what it is.

const SERVICE: &str = "com.moonsplice.studio";

/// The providers the app knows how to reach. A closed set, so a typo cannot write a key
/// under a name nothing reads.
pub const KNOWN: [&str; 2] = ["openrouter", "openai"];

fn entry(name: &str) -> Result<keyring::Entry, String> {
    if !KNOWN.contains(&name) {
        return Err(format!("{name} is not a provider this app reaches"));
    }
    keyring::Entry::new(SERVICE, name).map_err(|e| e.to_string())
}

pub fn set(name: &str, value: &str) -> Result<(), String> {
    let e = entry(name)?;
    if value.is_empty() {
        return e.delete_credential().map_err(|e| e.to_string());
    }
    e.set_password(value).map_err(|e| e.to_string())
}

pub fn get(name: &str) -> Option<String> {
    entry(name).ok()?.get_password().ok().filter(|s| !s.is_empty())
}

pub fn is_set(name: &str) -> bool {
    get(name).is_some()
}

/// Environment first, so a terminal that already exports a key can run the app without
/// putting one in the keychain — which is how the tests and `just check` see it.
pub fn resolve(name: &str) -> Option<String> {
    let env = match name {
        "openrouter" => "OPENROUTER_API_KEY",
        "openai" => "OPENAI_API_KEY",
        _ => return None,
    };
    if let Ok(v) = std::env::var(env) {
        if !v.is_empty() {
            return Some(v);
        }
    }
    get(name)
}

/// The provider a turn will use, and why there might not be one.
pub fn preferred() -> Result<(&'static str, String), String> {
    for name in ["openrouter", "openai"] {
        if let Some(key) = resolve(name) {
            return Ok((
                if name == "openrouter" {
                    "openrouter"
                } else {
                    "openai"
                },
                key,
            ));
        }
    }
    Err("no model key yet — add one in Settings before asking the agent for anything".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unknown_provider_is_refused_rather_than_stored() {
        assert!(set("hotmail", "x").is_err());
        assert!(get("hotmail").is_none());
    }

    #[test]
    fn the_environment_is_read_before_the_keychain() {
        std::env::set_var("OPENROUTER_API_KEY", "sk-from-the-shell");
        assert_eq!(resolve("openrouter").as_deref(), Some("sk-from-the-shell"));
        let (scheme, key) = preferred().unwrap();
        assert_eq!(scheme, "openrouter");
        assert_eq!(key, "sk-from-the-shell");
        std::env::remove_var("OPENROUTER_API_KEY");
    }
}
