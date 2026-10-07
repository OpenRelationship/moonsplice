//! `love.data` and `love.timer`, as far as the runtime uses them.
//!
//! The runtime hashes frames (`hash` mode prints an md5 per frame, which is what every golden
//! is), content-addresses its cache with sha1, and decodes base64 audio from a TTS response. All
//! three are standard algorithms with one right answer, so "the same bytes as LÖVE" here is "the
//! same bytes as the standard".

use std::time::{Duration, Instant};

use base64::Engine as _;
use md5::Digest as _;
use mlua::{Lua, Table};

pub fn install(lua: &Lua, t: &Table) -> mlua::Result<()> {
    // Raw digest bytes, as `love.data.hash("md5", s)` returns them.
    t.set(
        "hash",
        lua.create_function(|lua, (algo, s): (String, mlua::String)| {
            let b = s.as_bytes();
            let out: Vec<u8> = match algo.as_str() {
                "md5" => md5::Md5::digest(&b[..]).to_vec(),
                "sha1" => sha1::Sha1::digest(&b[..]).to_vec(),
                "sha224" => sha2::Sha224::digest(&b[..]).to_vec(),
                "sha256" => sha2::Sha256::digest(&b[..]).to_vec(),
                "sha384" => sha2::Sha384::digest(&b[..]).to_vec(),
                "sha512" => sha2::Sha512::digest(&b[..]).to_vec(),
                other => {
                    return Err(mlua::Error::runtime(format!(
                        "love.data.hash: unknown hash function {other:?}"
                    )))
                }
            };
            lua.create_string(&out)
        })?,
    )?;
    t.set(
        "hex",
        lua.create_function(|lua, s: mlua::String| {
            const D: &[u8; 16] = b"0123456789abcdef";
            let b = s.as_bytes();
            let mut out = Vec::with_capacity(b.len() * 2);
            for &c in b.iter() {
                out.push(D[(c >> 4) as usize]);
                out.push(D[(c & 15) as usize]);
            }
            lua.create_string(&out)
        })?,
    )?;
    t.set(
        "unhex",
        lua.create_function(|lua, s: mlua::String| {
            let b = s.as_bytes();
            let v = |c: u8| -> u8 {
                match c {
                    b'0'..=b'9' => c - b'0',
                    b'a'..=b'f' => c - b'a' + 10,
                    b'A'..=b'F' => c - b'A' + 10,
                    _ => 0,
                }
            };
            let out: Vec<u8> = b.chunks(2).map(|p| (v(p[0]) << 4) | v(*p.get(1).unwrap_or(&b'0'))).collect();
            lua.create_string(&out)
        })?,
    )?;
    t.set(
        "base64_encode",
        lua.create_function(|lua, s: mlua::String| {
            lua.create_string(base64::engine::general_purpose::STANDARD.encode(&s.as_bytes()[..]))
        })?,
    )?;
    t.set(
        "base64_decode",
        lua.create_function(|lua, s: mlua::String| {
            // LÖVE tolerates the line breaks a wrapped encoder leaves in; so does this.
            let clean: Vec<u8> = s.as_bytes().iter().copied().filter(|c| !c.is_ascii_whitespace()).collect();
            let out = base64::engine::general_purpose::STANDARD
                .decode(&clean)
                .map_err(|e| mlua::Error::runtime(format!("love.data.decode: {e}")))?;
            lua.create_string(&out)
        })?,
    )?;

    // A monotonic clock, like `love.timer.getTime`. The runtime uses it only to measure itself;
    // a composition never sees it (its clock is `t`).
    let start = Instant::now();
    t.set("now", lua.create_function(move |_, ()| Ok(start.elapsed().as_secs_f64()))?)?;
    t.set(
        "sleep",
        lua.create_function(|_, s: f64| {
            if s > 0.0 {
                std::thread::sleep(Duration::from_secs_f64(s));
            }
            Ok(())
        })?,
    )?;
    Ok(())
}
