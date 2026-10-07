//! `moonsplice-engine`: one command, then exit. The host itself is the library (src/lib.rs).

use std::path::Path;

fn main() {
    std::process::exit(run());
}

/// Where `core/runtime/` is. LÖVE took it as its first argument (the "game" directory) and so does
/// this, so the launcher's line did not change. Without it, the checkout this binary was built in.
fn runtime_dir(args: &mut Vec<String>) -> std::path::PathBuf {
    if let Some(first) = args.first() {
        let p = Path::new(first);
        if p.is_dir() && p.join("main.lua").is_file() {
            let dir = p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
            args.remove(0);
            return dir;
        }
    }
    moonsplice_engine::default_runtime()
}

fn run() -> i32 {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let runtime = runtime_dir(&mut args);
    if args.first().map(String::as_str) == Some("--tabicl") {
        return moonsplice_engine::tabicl::serve();
    }
    let lua = match moonsplice_engine::new_state(&runtime) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("moonsplice-engine: {e}");
            return 2;
        }
    };
    match moonsplice_engine::boot(&lua, &runtime, args) {
        Ok(code) => code,
        Err(e) => {
            // The boot routes runtime errors through the runtime's own `love.errorhandler`, which
            // exits; reaching here means the boot itself failed.
            eprintln!("moonsplice-engine: {e}");
            1
        }
    }
}
