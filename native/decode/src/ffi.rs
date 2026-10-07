// The registry of open handles and the C ABI over it.

use super::worker::{spawn_worker, Worker};
use super::Decoder;
use ffmpeg_the_third as ff;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

static REG: Mutex<Option<HashMap<i64, Worker>>> = Mutex::new(None);
static NEXT_ID: Mutex<i64> = Mutex::new(1);

fn with_reg<T>(f: impl FnOnce(&mut HashMap<i64, Worker>) -> T) -> T {
    let mut guard = REG.lock().unwrap();
    f(guard.get_or_insert_with(HashMap::new))
}

#[no_mangle]
pub extern "C" fn ed_open2(path: *const c_char, fb_w: c_int, fb_h: c_int) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        ff::init().ok();
        let path = unsafe { CStr::from_ptr(path) }.to_str().ok()?;
        match Decoder::open(path, fb_w as u32, fb_h as u32) {
            Ok(d) => {
                let w = spawn_worker(d);
                let id = { let mut n = NEXT_ID.lock().unwrap(); *n += 1; *n };
                with_reg(|r| r.insert(id, w));
                Some(id)
            }
            Err(e) => { eprintln!("moonsplice-decode: open failed: {e}"); None }
        }
    }));
    match result { Ok(Some(id)) => id, _ => -1 }
}

#[no_mangle]
pub extern "C" fn ed_info(handle: i64, mode: *mut c_int, w: *mut c_int, h: *mut c_int, full_range: *mut c_int) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| {
        with_reg(|r| {
            let wk = r.get(&handle)?;
            unsafe {
                *mode = wk.mode as c_int;
                *w = wk.width as c_int;
                *h = wk.height as c_int;
                *full_range = wk.full_range as c_int;
            }
            Some(())
        })
    }));
    match result { Ok(Some(())) => 0, _ => -1 }
}

#[no_mangle]
pub extern "C" fn ed_frame_yuv(handle: i64, t: f64, y: *mut u8, ylen: usize, u: *mut u8, ulen: usize, v: *mut u8, vlen: usize) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| {
        with_reg(|r| {
            let wk = r.get(&handle)?;
            if wk.mode != 0 { return None; }
            let ys = unsafe { std::slice::from_raw_parts_mut(y, ylen) };
            let us = unsafe { std::slice::from_raw_parts_mut(u, ulen) };
            let vs = unsafe { std::slice::from_raw_parts_mut(v, vlen) };
            wk.fetch(t, ys, Some(us), Some(vs)).then_some(())
        })
    }));
    match result { Ok(Some(())) => 0, _ => -1 }
}

#[no_mangle]
pub extern "C" fn ed_frame_rgba(handle: i64, t: f64, out: *mut u8, len: usize) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| {
        with_reg(|r| {
            let wk = r.get(&handle)?;
            if wk.mode != 1 { return None; }
            let os = unsafe { std::slice::from_raw_parts_mut(out, len) };
            wk.fetch(t, os, None, None).then_some(())
        })
    }));
    match result { Ok(Some(())) => 0, _ => -1 }
}

#[no_mangle]
pub extern "C" fn ed_prefetch(handle: i64, t: f64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        with_reg(|r| {
            if let Some(wk) = r.get(&handle) {
                wk.prefetch(t);
            }
        });
    }));
}

#[no_mangle]
pub extern "C" fn ed_close(handle: i64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        with_reg(|r| r.remove(&handle));
    }));
}

/// The one pinned YUV420 -> RGBA8 path (BT.709, integer maths, opaque alpha).
/// Used by the scene renderer for yuv-mode streams; hash-exact across machines.
#[no_mangle]
pub extern "C" fn ed_yuv420_to_rgba(
    y: *const u8, u: *const u8, v: *const u8, w: c_int, h: c_int, full_range: c_int,
    out: *mut u8, out_len: usize,
) -> c_int {
    let (w, h) = (w.max(0) as usize, h.max(0) as usize);
    if out_len < w * h * 4 || w == 0 || h == 0 { return -1; }
    let cw = (w + 1) / 2;
    let yp = unsafe { std::slice::from_raw_parts(y, w * h) };
    let up = unsafe { std::slice::from_raw_parts(u, cw * ((h + 1) / 2)) };
    let vp = unsafe { std::slice::from_raw_parts(v, cw * ((h + 1) / 2)) };
    let o = unsafe { std::slice::from_raw_parts_mut(out, w * h * 4) };
    let full = full_range != 0;
    use rayon::prelude::*;
    o.par_chunks_mut(w * 4).enumerate().for_each(|(j, row)| {
        for i in 0..w {
            let yy = yp[j * w + i] as i32;
            let uu = up[(j / 2) * cw + i / 2] as i32 - 128;
            let vv = vp[(j / 2) * cw + i / 2] as i32 - 128;
            // fixed point 16.16, BT.709
            let (c, kr, kg1, kg2, kb) = if full {
                (yy << 16, 103_206, 12_276, 30_679, 121_608)      // 1.5748, 0.1873, 0.4681, 1.8556
            } else {
                ((yy - 16) * 76_309, 117_489, 13_975, 34_925, 138_438) // 1.1644 * (…)
            };
            let r = (c + kr * vv + 32_768) >> 16;
            let g = (c - kg1 * uu - kg2 * vv + 32_768) >> 16;
            let b = (c + kb * uu + 32_768) >> 16;
            let k = i * 4;
            row[k] = r.clamp(0, 255) as u8;
            row[k + 1] = g.clamp(0, 255) as u8;
            row[k + 2] = b.clamp(0, 255) as u8;
            row[k + 3] = 255;
        }
    });
    0
}
