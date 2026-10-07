//! moonsplice-tabicl parity FIXTURE.json...   check the port against tablua-local's fixtures
//! moonsplice-tabicl < body.json              one call: { train, labels, categorical, test } -> { probas, ms }

use anyhow::{Context, Result};
use candle_core::Device;
use moonsplice_tabicl::{parity, TabIcl};
use std::path::PathBuf;

fn weights() -> PathBuf {
    std::env::var_os("MOONSPLICE_TABICL_WEIGHTS").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache/moonsplice/tabicl/tabicl-v2.safetensors")
    })
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dev = Device::Cpu;
    let m = TabIcl::load(&weights(), &dev).context("loading TabICL weights")?;
    if args.first().map(|s| s.as_str()) == Some("parity") {
        let json = args.iter().any(|a| a == "--json");
        for p in args[1..].iter().filter(|a| *a != "--json") {
            let fx: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(p)?)?;
            let t0 = std::time::Instant::now();
            let l1 = parity::level1(&m, &fx)?;
            let (enc, xin, matched, of) = parity::level2(&fx)?;
            let t1 = std::time::Instant::now();
            let l3 = parity::level3(&m, &fx)?;
            if json {
                let name = std::path::Path::new(p).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                println!(
                    "{}",
                    serde_json::json!({ "fixture": name, "level1": l1, "encoded": enc, "member_x": xin,
                        "matched": matched, "members": of, "level3": l3 })
                );
                continue;
            }
            println!(
                "{p}\n  level1 max|dlogit| {l1:.2e} ({:.0} ms)\n  level2 encoded {enc:.2e}, member X {xin:.2e} ({matched}/{of} members matched)\n  level3 max|dp| {l3:.2e} ({:.0} ms)",
                (t1 - t0).as_secs_f64() * 1e3,
                t1.elapsed().as_secs_f64() * 1e3
            );
        }
        return Ok(());
    }
    anyhow::bail!("usage: moonsplice-tabicl parity FIXTURE.json...")
}
