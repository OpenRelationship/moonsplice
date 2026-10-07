//! `moonsplice-engine`: the Moonsplice host, with no LÖVE underneath.
//!
//! A library as well as a binary: the binary runs one command and exits (`moonsplice`), and
//! [`Session`] runs `serve` on a thread inside another process -- the Studio -- with the same Lua
//! and the same boot (.robot/docs/engine.robot, phase 4).
//!
//! LÖVE was doing very little by the end. `core/runtime/*.lua` already owns the frame loop, the ffmpeg
//! pipe and the audio mix; `scene/` already paints every frame of the default path; the native
//! helpers are Rust behind a C ABI that LuaJIT's FFI calls. What LÖVE still provided on that path
//! was a Lua VM, a way to find the runtime's own files, a few byte utilities (hashes, hex,
//! base64), a clock, and pixel buffers to hand the rasterizer. This binary provides exactly those,
//! and then runs `core/runtime/main.lua` the way LÖVE's boot does.
//!
//! Phase 1 of `.robot/docs/engine.robot` swapped the host, and the proof was the goldens: the same Lua
//! drives the same rasterizer, and every frame came out byte for byte. LÖVE itself was then
//! removed outright. Anything the runtime still asks of LÖVE that this host does not have --
//! `love.graphics`'s readbacks, its GLSL, `love.physics` -- is a feature not yet ported, and says
//! so: status 3 offline, a failed request in a serve session. Phases 2 and 3 port those features
//! until nothing is left that says it.
//!
//! LuaJIT rather than Lua 5.4 because the runtime reaches the native helpers through LuaJIT's
//! FFI. The VM is the one piece of C this host keeps, and it is the language we chose.

mod data;
mod image;
mod physics;
mod session;
pub mod solid;
pub mod tabicl;

use std::path::{Path, PathBuf};

use mlua::{Lua, LuaOptions, StdLib};

pub use session::{Session, SessionError};

/// The status for a comp that uses a feature not yet ported to the engine. Distinct from 1 (the
/// comp is wrong) and 2 (the machine is missing something), so a script or the Studio can say
/// "not ported yet" rather than "broken".
pub const NOT_PORTED: i32 = 3;

/// The checkout this crate was built in: where `core/runtime/` is when nobody says otherwise.
pub fn default_runtime() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../runtime")
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from("core/runtime"))
}

/// A LuaJIT state with the host installed and the love shim loaded, ready for [`boot`].
pub fn new_state(runtime: &Path) -> Result<Lua, String> {
    // SAFETY: the FFI library is the reason this host exists (see the module comment); LuaJIT
    // only offers it to a state opened without mlua's safety restrictions.
    let lua = unsafe { Lua::unsafe_new_with(StdLib::ALL, LuaOptions::default()) };
    let host = install(&lua, runtime).map_err(|e| format!("could not set up the host: {e}"))?;
    lua.load(include_str!("../../../core/runtime/love.lua"))
        .set_name("=engine/love.lua")
        .call::<()>(host)
        .map_err(|e| format!("the love shim would not load: {e}"))?;
    Ok(lua)
}

/// Run `core/runtime/main.lua` with `args` the way LÖVE's boot does; the exit status.
pub fn boot(lua: &Lua, runtime: &Path, args: Vec<String>) -> Result<i32, String> {
    let argv = lua.create_sequence_from(args).map_err(|e| e.to_string())?;
    lua.load(include_str!("../../../core/runtime/boot.lua"))
        .set_name("=engine/boot.lua")
        .call::<i32>((runtime.display().to_string(), argv))
        .map_err(|e| e.to_string())
}

/// The table the Lua shim builds `love` from. Everything byte-level is here in Rust, where
/// "identical to LÖVE" is a property of a well-defined algorithm rather than of a Lua port.
fn install(lua: &Lua, runtime: &Path) -> mlua::Result<mlua::Table> {
    let t = lua.create_table()?;
    t.set("runtime", runtime.display().to_string())?;
    t.set("not_ported", NOT_PORTED)?;
    data::install(lua, &t)?;
    image::install(lua, &t)?;
    physics::install(lua, &t)?;
    tabicl::install(lua, &t)?;
    solid::install(lua, &t)?;
    Ok(t)
}
