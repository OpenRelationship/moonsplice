//! Image slots: pixels registered or replaced by the host, premultiplied on the way in.

use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use anyrender::ResourceId;
use vello_cpu::Pixmap;

use crate::state::state;

/// Straight-alpha (or already premultiplied) RGBA8 as premultiplied bytes.
fn to_premul(src: &[u8], n: usize, premul: bool) -> Vec<u8> {
    let mut px = Vec::with_capacity(n * 4);
    for i in 0..n {
        let a = src[i * 4 + 3];
        if premul || a == 255 {
            px.extend_from_slice(&src[i * 4..i * 4 + 4]);
        } else {
            let a32 = a as u32;
            let pm = |c: u8| ((c as u32 * a32 + 127) / 255) as u8;
            px.extend_from_slice(&[pm(src[i * 4]), pm(src[i * 4 + 1]), pm(src[i * 4 + 2]), a]);
        }
    }
    px
}

/// A pixmap of premultiplied bytes. Whether any pixel is see-through is measured, not assumed:
/// an opaque image (most video) then composites without blending.
pub(crate) fn premul_pixmap(px: Vec<u8>, w: u16, h: u16) -> Pixmap {
    let transparent = px.chunks_exact(4).any(|p| p[3] != 255);
    Pixmap::from_parts(px, w, h, vello_common::pixmap::PixelMetadata::new(vello_cpu::peniko::ImageAlphaType::AlphaPremultiplied, transparent))
}

/// premul != 0: pixels are already premultiplied (blitz, vello, love canvases).
#[no_mangle]
pub extern "C" fn cs_image_register(rgba: *const u8, w: u16, h: u16, premul: c_int) -> c_int {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let n = w as usize * h as usize;
        let src = unsafe { std::slice::from_raw_parts(rgba, n * 4) };
        let px = to_premul(src, n, premul != 0);
        let mut st = state().lock().unwrap();
        let id = st.res.register_image(Arc::new(premul_pixmap(px, w, h)));
        let rid = ResourceId::new();
        st.ids.insert(rid, id);
        st.images.push((rid, w, h));
        (st.images.len() - 1) as c_int
    }));
    r.unwrap_or(-1)
}

/// Replace the pixels of a registered image slot (html textures, video frames). The slot keeps
/// its resource id, so a scene that names it reads the new pixels.
#[no_mangle]
pub extern "C" fn cs_image_update(slot: c_int, rgba: *const u8, w: u16, h: u16, premul: c_int) -> c_int {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let n = w as usize * h as usize;
        let src = unsafe { std::slice::from_raw_parts(rgba, n * 4) };
        let px = to_premul(src, n, premul != 0);
        let mut st = state().lock().unwrap();
        let Some(&(rid, _, _)) = st.images.get(slot as usize) else { return -1 };
        if let Some(old) = st.ids.remove(&rid) {
            st.res.destroy_image(old);
        }
        let id = st.res.register_image(Arc::new(premul_pixmap(px, w, h)));
        st.ids.insert(rid, id);
        st.images[slot as usize] = (rid, w, h);
        0
    }));
    r.unwrap_or(-1)
}
