//! Moonsplice's distribution launcher.
//!
//! The renderer is `moonsplice-engine` (engine/, Rust + LuaJIT). This binary resolves the
//! sidecars shipped beside it, establishes a deterministic runtime environment,
//! and delegates the requested command without relying on a system ffmpeg.

use std::env;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

const COMMANDS: &[&str] = &[
    "render", "hash", "lint", "check", "doctor", "verify", "feedback",
];

fn moonsplice_root() -> Result<PathBuf, String> {
    if let Ok(dir) = env::var("MOONSPLICE_ROOT").or_else(|_| env::var("MOONSPLICE_ROOT")) {
        return PathBuf::from(dir)
            .canonicalize()
            .map_err(|err| format!("MOONSPLICE_ROOT invalid: {err}"));
    }
    let source_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("cli has an moonsplice parent")
        .to_path_buf();
    source_root
        .canonicalize()
        .map_err(|err| format!("cannot locate moonsplice root: {err}"))
}

fn run_node_script(script: &str, args: &[OsString]) -> Result<ExitCode, String> {
    let root = moonsplice_root()?;
    let path = root.join(script);
    if !path.is_file() {
        return Err(format!("script missing: {}", path.display()));
    }
    let mut child = Command::new("node");
    child.arg(path).args(args);
    let status = child
        .status()
        .map_err(|err| format!("failed to start node for {script}: {err}"))?;
    Ok(ExitCode::from(status.code().unwrap_or(1) as u8))
}

struct Bundle {
    root: PathBuf,
    runtime: PathBuf,
    renderer: PathBuf,
    native: PathBuf,
    ffmpeg_dir: PathBuf,
}

fn executable_name(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_owned()
    }
}

fn usage() -> &'static str {
    "Usage: moonsplice <render|hash|lint|check|doctor|verify|feedback> [args]\n\
     \n\
     Engine-backed: render, hash, lint, check (bundled moonsplice-engine).\n\
     Agent tools: doctor, verify, feedback (node scripts, moonsplice.result/v1 JSON).\n\
     \n\
     Development overrides: MOONSPLICE_HOME, MOONSPLICE_ENGINE, MOONSPLICE_FFMPEG, MOONSPLICE_ROOT."
}

fn directory_with_runtime(candidate: PathBuf) -> Option<PathBuf> {
    candidate
        .join("share")
        .join("moonsplice")
        .join("core").join("runtime")
        .is_dir()
        .then_some(candidate)
}

fn bundle_root() -> Result<PathBuf, String> {
    if let Some(root) = env::var_os("MOONSPLICE_HOME").map(PathBuf::from) {
        return directory_with_runtime(root.clone())
            .ok_or_else(|| format!("MOONSPLICE_HOME does not contain share/moonsplice/runtime: {}", root.display()));
    }

    let executable = env::current_exe().map_err(|err| format!("cannot locate moonsplice executable: {err}"))?;
    if let Some(root) = executable
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .and_then(directory_with_runtime)
    {
        return Ok(root);
    }

    // `cargo run -p moonsplice-cli` is intentionally supported for renderer work.
    let source_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("cli has an moonsplice parent")
        .to_path_buf();
    if source_root.join("core").join("runtime").is_dir() {
        return Ok(source_root);
    }

    Err("cannot locate Moonsplice bundle; set MOONSPLICE_HOME".to_owned())
}

fn bundled_path(root: &Path, directory: &str, name: &str) -> PathBuf {
    root.join(directory).join(executable_name(name))
}

fn build_bundle() -> Result<Bundle, String> {
    let root = bundle_root()?;
    let source_layout = root.join("core").join("runtime").is_dir();
    let runtime = if source_layout {
        root.join("core").join("runtime")
    } else {
        root.join("share/moonsplice/runtime")
    };
    let native = if source_layout {
        root.join("native/release")
    } else {
        root.join("share/moonsplice/native/release")
    };
    let renderer = env::var_os("MOONSPLICE_ENGINE")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if source_layout {
                root.join("target/release").join(executable_name("moonsplice-engine"))
            } else {
                bundled_path(&root, "libexec", "moonsplice-engine")
            }
        });
    let ffmpeg_dir = env::var_os("MOONSPLICE_FFMPEG")
        .map(PathBuf::from)
        .and_then(|path| path.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| root.join("libexec"));

    if !runtime.is_dir() {
        return Err(format!("runtime is missing: {}", runtime.display()));
    }
    if !renderer.is_file() {
        return Err(format!(
            "bundled moonsplice-engine is missing: {} (set MOONSPLICE_ENGINE for development)",
            renderer.display()
        ));
    }

    Ok(Bundle {
        root,
        runtime,
        renderer,
        native,
        ffmpeg_dir,
    })
}

fn prepend_path(directory: &Path) -> OsString {
    let mut entries = vec![directory.to_path_buf()];
    if let Some(path) = env::var_os("PATH") {
        entries.extend(env::split_paths(&path));
    }
    env::join_paths(entries).expect("sidecar path contains no invalid separator")
}

fn run() -> Result<ExitCode, String> {
    let mut args = env::args_os();
    let _program = args.next();
    let command = args
        .next()
        .ok_or_else(|| usage().to_owned())?;
    let command_display = command.to_string_lossy();

    if command_display == "--help" || command_display == "-h" {
        println!("{}", usage());
        return Ok(ExitCode::SUCCESS);
    }
    if command_display == "--version" || command_display == "-V" {
        println!("moonsplice {}", env!("CARGO_PKG_VERSION"));
        return Ok(ExitCode::SUCCESS);
    }
    if !COMMANDS.contains(&command_display.as_ref()) {
        return Err(format!("unknown command `{command_display}`\n\n{}", usage()));
    }

    if matches!(command_display.as_ref(), "doctor" | "verify" | "feedback") {
        let script = match command_display.as_ref() {
            "doctor" => "scripts/moonsplice-doctor.mjs",
            "verify" => "scripts/moonsplice-verify.mjs",
            "feedback" => "scripts/moonsplice-feedback.mjs",
            _ => unreachable!(),
        };
        let rest: Vec<OsString> = args.collect();
        return run_node_script(script, &rest);
    }

    let bundle = build_bundle()?;
    let cwd = env::current_dir().map_err(|err| format!("cannot determine working directory: {err}"))?;
    let mut child = Command::new(&bundle.renderer);
    child
        .arg(&bundle.runtime)
        .arg(format!("--{command_display}"))
        .args(args)
        .env("MOONSPLICE_CWD", cwd)
        .env("MOONSPLICE_NATIVE", &bundle.native)
        .env("MOONSPLICE_HEADLESS", "1")
        .env("PATH", prepend_path(&bundle.ffmpeg_dir))
        .env("MOONSPLICE_BUNDLE", &bundle.root);

    let status = child
        .status()
        .map_err(|err| format!("failed to start {}: {err}", bundle.renderer.display()))?;
    Ok(ExitCode::from(status.code().unwrap_or(1) as u8))
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(message) => {
            eprintln!("moonsplice: {message}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_binary_names_are_consistent() {
        let expected = if cfg!(windows) { "moonsplice-engine.exe" } else { "moonsplice-engine" };
        assert_eq!(executable_name("moonsplice-engine"), expected);
    }

    #[test]
    fn documented_commands_include_agent_tools() {
        assert!(COMMANDS.contains(&"verify"));
        assert!(COMMANDS.contains(&"doctor"));
    }
}
