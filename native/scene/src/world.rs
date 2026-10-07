//! A 3D world drawn by Bevy, as a picture for the scene.

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::last_error;

/// One frame of a 3D world drawn by Bevy (render/src/world.rs). `doc` is the world at `t` as JSON
/// (core/runtime/worldbevy.lua builds it); `id` names the world node, so its entities persist. Writes
/// `w` x `h` sRGB RGBA, straight alpha, into `out`. -1 on failure, with cs_last_error saying why.
#[no_mangle]
pub extern "C" fn cs_world_render(id: *const c_char, doc: *const u8, doc_len: usize, w: u16, h: u16, out: *mut u8, out_len: usize) -> c_int {
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
        let id = unsafe { CStr::from_ptr(id) }.to_string_lossy().into_owned();
        let doc = std::str::from_utf8(unsafe { std::slice::from_raw_parts(doc, doc_len) }).map_err(|e| e.to_string())?;
        let px = world(&id, doc, w as u32, h as u32)?;
        let n = (w as usize * h as usize * 4).min(out_len).min(px.len());
        unsafe { std::ptr::copy_nonoverlapping(px.as_ptr(), out, n) };
        Ok(())
    }));
    match r {
        Ok(Ok(())) => 0,
        Ok(Err(why)) => { *last_error().lock().unwrap() = std::ffi::CString::new(why).unwrap_or_default(); -1 }
        Err(_) => -1,
    }
}

#[cfg(feature = "gpu")]
fn world(id: &str, doc: &str, w: u32, h: u32) -> Result<Vec<u8>, String> {
    moonsplice_render::world_frame(id, doc, w, h)
}
#[cfg(not(feature = "gpu"))]
fn world(_: &str, _: &str, _: u32, _: u32) -> Result<Vec<u8>, String> {
    Err("world: this build has no GPU (moonsplice-scene without the gpu feature)".into())
}
