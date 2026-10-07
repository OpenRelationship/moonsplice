//! TabICL, tablua's move ranker, inside the host (.robot/docs/rows.robot, level 7): Lua calls
//! `MOONSPLICE_ENGINE.tabicl(body_json) -> reply_json`, and `moonsplice-engine --tabicl` answers
//! one body per line on stdin for a harness outside the engine (tablua under plain LuaJIT).
//! body = { train = { columns, rows }, labels, categorical, test = { columns, rows } }
//! reply = { probas = { { p0, p1 }, ... }, ms } or { error }. The weights load once, on first use.

use mlua::{Lua, Table};
use moonsplice_tabicl::{prep, TabIcl};
use std::io::{BufRead, Write};
use std::sync::OnceLock;

static MODEL: OnceLock<Result<TabIcl, String>> = OnceLock::new();

fn weights() -> std::path::PathBuf {
    std::env::var_os("MOONSPLICE_TABICL_WEIGHTS").map(Into::into).unwrap_or_else(|| {
        std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache/moonsplice/tabicl/tabicl-v2.safetensors")
    })
}

fn model() -> Result<&'static TabIcl, String> {
    MODEL
        .get_or_init(|| {
            let p = weights();
            TabIcl::load(&p, &candle_core::Device::Cpu).map_err(|e| format!("TabICL weights at {}: {e}", p.display()))
        })
        .as_ref()
        .map_err(|e| e.clone())
}

/// one request, as JSON text in and out; an error is a reply, not a panic
pub fn answer(body: &str) -> String {
    let reply = (|| -> Result<serde_json::Value, String> {
        let body: serde_json::Value = serde_json::from_str(body).map_err(|e| format!("body is not JSON: {e}"))?;
        let m = model()?;
        let mut s = prep::Settings::default();
        if let Some(n) = body["n_estimators"].as_u64() {
            s.n_estimators = n.max(1) as usize;
        }
        prep::host_predict(m, &body, &s).map_err(|e| e.to_string())
    })();
    match reply {
        Ok(v) => v.to_string(),
        Err(e) => serde_json::json!({ "error": e }).to_string(),
    }
}

pub fn install(lua: &Lua, t: &Table) -> mlua::Result<()> {
    t.set("tabicl", lua.create_function(|_, body: String| Ok(answer(&body)))?)?;
    Ok(())
}

/// `moonsplice-engine --tabicl`: a line of JSON in, a line of JSON out, until stdin closes
pub fn serve() -> i32 {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { return 1 };
        if line.trim().is_empty() {
            continue;
        }
        if writeln!(out, "{}", answer(&line)).and_then(|_| out.flush()).is_err() {
            return 1;
        }
    }
    0
}
