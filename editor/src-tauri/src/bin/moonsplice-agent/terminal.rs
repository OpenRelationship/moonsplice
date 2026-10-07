use super::*;

/// The terminal, as a chat surface: events to a file (and a line each to stderr), approvals
/// either given in advance or asked on the terminal.
pub(super) struct Terminal {
    pub(super) yes: bool,
    pub(super) quiet: bool,
    pub(super) events: Option<Mutex<std::fs::File>>,
    pub(super) started: Instant,
    pub(super) turn: Mutex<u32>,
}

impl Terminal {
    pub(super) fn write(&self, mut v: serde_json::Value) {
        v["t"] = serde_json::json!((self.started.elapsed().as_secs_f64() * 100.0).round() / 100.0);
        v["turn"] = serde_json::json!(*self.turn.lock().unwrap());
        if let Some(f) = &self.events {
            let mut f = f.lock().unwrap();
            let _ = writeln!(f, "{v}");
            let _ = f.flush();
        }
    }
}

impl Surface for Terminal {
    fn emit(&self, chunk: serde_json::Value) {
        if !self.quiet {
            match chunk["event"].as_str().unwrap_or("") {
                "call" => eprintln!("  · {}", chunk["tool"].as_str().unwrap_or("?")),
                "result" if chunk["refused"].as_bool() == Some(true) || chunk["ok"].as_bool() == Some(false) => {
                    eprintln!("    refused: {}", chunk["tool"].as_str().unwrap_or("?"))
                }
                "stop" => eprintln!(
                    "  stop: {} after {} step(s)",
                    chunk["stop"].as_str().unwrap_or("?"),
                    chunk["steps"]
                ),
                _ => {}
            }
        }
        self.write(chunk);
    }

    fn ask(&self, ask: Ask) -> Decision {
        self.write(serde_json::json!({ "event": "ask", "tool": ask.tool, "auto": self.yes }));
        if self.yes {
            return Decision { allow: true, reason: None, remember: None };
        }
        eprint!("{} wants to {} — allow? [y/N/a(lways)] ", "the agent", ask.tool);
        let _ = std::io::stderr().flush();
        let mut line = String::new();
        let _ = std::io::stdin().lock().read_line(&mut line);
        match line.trim() {
            "y" | "Y" | "yes" => Decision { allow: true, reason: None, remember: None },
            "a" | "A" | "always" => Decision { allow: true, reason: None, remember: Some("tool".into()) },
            _ => Decision { allow: false, reason: Some("the person said no".into()), remember: None },
        }
    }
}
