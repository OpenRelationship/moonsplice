//! HTML/URL → PNG on the Blitz stack. Replaces Chrome in `bin/moonsplice-capture`.
//!
//!   moonsplice-html-shot --html page.html --base https://example.com -w 1440 -h 3000 -o page.png
//!   moonsplice-html-shot --url https://example.com -o page.png

use moonsplice_scene::html::{paint, write_png};
use std::env;
use std::fs;
use std::process::ExitCode;

fn arg(args: &[String], name: &str) -> Option<String> {
    args.windows(2)
        .find(|w| w[0] == name)
        .map(|w| w[1].clone())
}

fn flag(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if flag(&args, "-h") || flag(&args, "--help") {
        eprintln!(
            "moonsplice-html-shot [--html FILE | --url URL] [--base URL] [-w W] [--height H] [--scale S] [--no-bake] -o OUT.png"
        );
        return ExitCode::SUCCESS;
    }
    let out = match arg(&args, "-o").or_else(|| arg(&args, "--out")) {
        Some(p) => p,
        None => {
            eprintln!("moonsplice-html-shot: -o OUT.png required");
            return ExitCode::from(2);
        }
    };
    let width: u32 = arg(&args, "-w")
        .or_else(|| arg(&args, "--width"))
        .and_then(|s| s.parse().ok())
        .unwrap_or(1440);
    let height: u32 = arg(&args, "--height")
        .and_then(|s| s.parse().ok())
        .unwrap_or(3000);
    let scale: f32 = arg(&args, "--scale")
        .and_then(|s| s.parse().ok())
        .unwrap_or(1.0);
    let bake = !flag(&args, "--no-bake");

    let (html, base) = if let Some(url) = arg(&args, "--url") {
        let body = match ureq::get(&url)
            .set(
                "User-Agent",
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36",
            )
            .timeout(std::time::Duration::from_secs(30))
            .call()
        {
            Ok(resp) => match resp.into_string() {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("moonsplice-html-shot: read {url}: {e}");
                    return ExitCode::from(1);
                }
            },
            Err(e) => {
                eprintln!("moonsplice-html-shot: fetch {url}: {e}");
                return ExitCode::from(1);
            }
        };
        let base = arg(&args, "--base").unwrap_or(url);
        (body, Some(base))
    } else if let Some(path) = arg(&args, "--html") {
        let body = match fs::read_to_string(&path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("moonsplice-html-shot: read {path}: {e}");
                return ExitCode::from(1);
            }
        };
        let base = arg(&args, "--base").unwrap_or(path);
        (body, Some(base))
    } else {
        eprintln!("moonsplice-html-shot: --html FILE or --url URL required");
        return ExitCode::from(2);
    };

    let buffer = match paint(&html, base.as_deref(), width, height, scale, bake) {
        Some(b) => b,
        None => {
            eprintln!("moonsplice-html-shot: paint failed");
            return ExitCode::from(1);
        }
    };
    let rw = (width as f32 * scale) as u32;
    let rh = (height as f32 * scale) as u32;
    if let Err(e) = write_png(&out, &buffer, rw, rh) {
        eprintln!("moonsplice-html-shot: write {out}: {e}");
        return ExitCode::from(1);
    }
    println!("moonsplice-html-shot: {out} ({rw}x{rh})");
    ExitCode::SUCCESS
}
