// moonsplice-decode: in-process frame server for the love host (LuaJIT FFI).
//
// v2: YUV-native + prefetch worker.
//  - yuv420p/yuvj420p sources: NO CPU conversion at all — raw planes are handed to
//    the renderer, which does BT.709 YUV→RGB + cover-crop + scale in a GPU shader.
//  - other pixel formats: legacy sws→RGBA fallback at a fixed output size.
//  - every handle owns a worker thread: ed_prefetch(t) decodes the next frame while
//    the renderer is busy drawing/reading back/encoding the current one.
//
// C ABI:
//   ed_open2(path, fb_w, fb_h)                    -> handle (>0) | -1
//   ed_info(h, *mode, *w, *h, *full_range)        -> 0 | -1   (mode 0=yuv420, 1=rgba)
//   ed_frame_yuv(h, t, y, ylen, u, ulen, v, vlen) -> 0 | -1   (yuv mode; blocking)
//   ed_frame_rgba(h, t, out, len)                 -> 0 | -1   (rgba mode; blocking)
//   ed_prefetch(h, t)                                          (non-blocking hint)
//   ed_close(h)

use ffmpeg_the_third as ff;
use ff::media::Type;
use ff::software::scaling;
use ff::util::format::pixel::Pixel;
use ff::util::frame::video::Video as VFrame;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

const T_EPS: f64 = 1e-6;

/// How far forward a jump has to be, in seconds, before seeking beats decoding through.
///
/// Under this, decoding on is cheaper: a seek lands on the nearest keyframe *before* the target
/// and the frames between it and the target have to be decoded anyway, so a short hop pays for
/// a flush and a re-run it did not need. Two seconds is a little over the longest keyframe
/// interval these files have, and playback never hops that far -- it asks for the next frame.
const JUMP: f64 = 2.0;

enum Mode {
    Yuv420 { full_range: bool },
    Rgba { scaler: scaling::Context, rgba: VFrame, scaled_w: u32, scaled_h: u32, out_w: u32, out_h: u32 },
}

struct Decoder {
    input: ff::format::context::Input,
    decoder: ff::codec::decoder::Video,
    stream_index: usize,
    time_base: (i32, i32),
    mode: Mode,
    width: u32,
    height: u32,
    // cache: last delivered frame. yuv mode: y/u/v planes; rgba mode: y holds RGBA.
    cache_y: Vec<u8>,
    cache_u: Vec<u8>,
    cache_v: Vec<u8>,
    cache_pts: i64,
    last_target: i64,
    eof: bool,
}

unsafe impl Send for Decoder {}

fn plane_copy(dst: &mut [u8], src: &[u8], stride: usize, w: usize, h: usize) {
    for r in 0..h {
        dst[r * w..(r + 1) * w].copy_from_slice(&src[r * stride..r * stride + w]);
    }
}

impl Decoder {
    fn open(path: &str, fb_w: u32, fb_h: u32) -> Result<Decoder, ff::Error> {
        let input = ff::format::input(&path)?;
        let stream = input.streams().best(Type::Video).ok_or(ff::Error::StreamNotFound)?;
        let stream_index = stream.index();
        let tb = stream.time_base();
        let mut ctx = ff::codec::context::Context::from_parameters(stream.parameters())?;
        ctx.set_threading(ff::codec::threading::Config {
            kind: ff::codec::threading::Type::Frame,
            count: 0,
        });
        let decoder = ctx.decoder().video()?;
        let (iw, ih) = (decoder.width(), decoder.height());

        let (mode, cy, cu, cv) = match decoder.format() {
            Pixel::YUV420P | Pixel::YUVJ420P => {
                let full = decoder.format() == Pixel::YUVJ420P;
                let ysz = (iw * ih) as usize;
                let csz = ((iw / 2) * (ih / 2)) as usize;
                (Mode::Yuv420 { full_range: full }, vec![0; ysz], vec![0; csz], vec![0; csz])
            }
            fmt => {
                let scale = f64::max(fb_w as f64 / iw as f64, fb_h as f64 / ih as f64);
                let sw = (((iw as f64 * scale).ceil() as u32).max(fb_w) + 1) & !1;
                let sh = (((ih as f64 * scale).ceil() as u32).max(fb_h) + 1) & !1;
                let scaler = scaling::Context::get(fmt, iw, ih, Pixel::RGBA, sw, sh, scaling::Flags::FAST_BILINEAR)?;
                (
                    Mode::Rgba { scaler, rgba: VFrame::empty(), scaled_w: sw, scaled_h: sh, out_w: fb_w, out_h: fb_h },
                    vec![0; (fb_w * fb_h * 4) as usize],
                    vec![],
                    vec![],
                )
            }
        };

        Ok(Decoder {
            input, decoder, stream_index,
            time_base: (tb.numerator(), tb.denominator()),
            mode, width: iw, height: ih,
            cache_y: cy, cache_u: cu, cache_v: cv,
            cache_pts: i64::MIN, last_target: i64::MIN, eof: false,
        })
    }

    fn store(&mut self, decoded: &VFrame, pts: i64) -> Result<(), ff::Error> {
        match &mut self.mode {
            Mode::Yuv420 { .. } => {
                let (w, h) = (self.width as usize, self.height as usize);
                plane_copy(&mut self.cache_y, decoded.data(0), decoded.stride(0), w, h);
                plane_copy(&mut self.cache_u, decoded.data(1), decoded.stride(1), w / 2, h / 2);
                plane_copy(&mut self.cache_v, decoded.data(2), decoded.stride(2), w / 2, h / 2);
            }
            Mode::Rgba { scaler, rgba, scaled_w, scaled_h, out_w, out_h } => {
                scaler.run(decoded, rgba)?;
                let stride = rgba.stride(0);
                let data = rgba.data(0);
                let ox = ((*scaled_w - *out_w) / 2) as usize * 4;
                let oy = ((*scaled_h - *out_h) / 2) as usize;
                let row = (*out_w * 4) as usize;
                for r in 0..*out_h as usize {
                    let s = (oy + r) * stride + ox;
                    self.cache_y[r * row..(r + 1) * row].copy_from_slice(&data[s..s + row]);
                }
            }
        }
        self.cache_pts = pts;
        Ok(())
    }

    fn decode_until(&mut self, target: i64) -> Result<(), ff::Error> {
        let mut decoded = VFrame::empty();
        loop {
            while self.decoder.receive_frame(&mut decoded).is_ok() {
                let pts = decoded.pts().unwrap_or(i64::MIN);
                if pts >= target || self.eof {
                    self.store(&decoded, pts)?;
                    if pts >= target {
                        return Ok(());
                    }
                }
            }
            if self.eof {
                return Ok(()); // hold last stored frame past EOF
            }
            match self.input.packets().next() {
                Some(Ok((stream, packet))) => {
                    if stream.index() == self.stream_index {
                        self.decoder.send_packet(&packet)?;
                    }
                }
                Some(Err(e)) => return Err(e),
                None => {
                    self.decoder.send_eof()?;
                    self.eof = true;
                }
            }
        }
    }

    fn advance_to(&mut self, t: f64) -> Result<(), ff::Error> {
        let (num, den) = self.time_base;
        let target = (t * den as f64 / num as f64).round() as i64;
        let backseek = target < self.last_target;
        // A jump forward is not playback. Decoding on is always right for the *next* frame --
        // it is what playing a clip is -- but somebody who drops the playhead five minutes in
        // is not playing, and decoding nine thousand frames to answer one is the difference
        // between a preview and a stall. Past a couple of seconds a seek to the nearest
        // keyframe and a short run up to the frame is cheaper, and it stops being cheaper
        // never: the cost of decoding through grows with the distance and the cost of seeking
        // does not.
        // A decoder that has never been asked for anything is at the start of the file, so the
        // distance to measure is the distance from there. Without this, the *first* frame a clip
        // is ever asked for is the expensive one -- and in a long edit that is every clip except
        // the first, because a person who drops the playhead five minutes in is asking six
        // decoders for their first frame at once. It was nine seconds for one frame.
        let from = if self.last_target == i64::MIN { 0 } else { self.last_target };
        let far = target > from && (target - from) as f64 * num as f64 / den as f64 > JUMP;
        self.last_target = target;
        // Going back always seeks. It used to be written "seek back, unless the frame we are
        // holding is already at or past the target" -- and the frame we are holding is *always*
        // at or past the target when the playhead moved back, because it was decoded for a later
        // moment. So the clause was never false, the seek never happened, and scrubbing left
        // handed back the frame from wherever the playhead had been. The test that found it asks
        // for the same moment twice, once walked to and once from a decoder freshly opened on the
        // file, and a decoder that has just opened has nothing to be wrong about.
        if backseek || far {
            let ts_avtb = (target as f64 * num as f64 / den as f64 * 1_000_000.0) as i64;
            self.input.seek(ts_avtb, ..=ts_avtb)?;
            self.decoder.flush();
            self.cache_pts = i64::MIN;
            self.eof = false;
            self.decode_until(target)?;
        } else if !(self.cache_pts != i64::MIN && self.cache_pts >= target) {
            self.decode_until(target)?;
        }
        Ok(())
    }
}

// ---------- prefetch worker ----------

struct Ready {
    t: f64,
    y: Vec<u8>,
    u: Vec<u8>,
    v: Vec<u8>,
    ok: bool,
}

struct Shared {
    req: Option<f64>,
    ready: Option<Ready>,
    dead: bool,
}

struct Worker {
    sh: Arc<(Mutex<Shared>, Condvar, Condvar)>, // (state, req_cv, ready_cv)
    mode: u8, // 0 yuv, 1 rgba
    width: u32,
    height: u32,
    full_range: bool,
    join: Option<thread::JoinHandle<()>>,
}

fn spawn_worker(mut dec: Decoder) -> Worker {
    let (mode, full_range) = match &dec.mode {
        Mode::Yuv420 { full_range } => (0u8, *full_range),
        Mode::Rgba { .. } => (1u8, true),
    };
    let (width, height) = match &dec.mode {
        Mode::Yuv420 { .. } => (dec.width, dec.height),
        Mode::Rgba { out_w, out_h, .. } => (*out_w, *out_h),
    };
    let sh = Arc::new((
        Mutex::new(Shared { req: None, ready: None, dead: false }),
        Condvar::new(),
        Condvar::new(),
    ));
    let sh2 = sh.clone();
    let join = thread::spawn(move || {
        let (m, req_cv, ready_cv) = &*sh2;
        loop {
            let t = {
                let mut g = m.lock().unwrap();
                while g.req.is_none() && !g.dead {
                    g = req_cv.wait(g).unwrap();
                }
                if g.dead {
                    return;
                }
                g.req.take().unwrap()
            };
            let ok = dec.advance_to(t).is_ok();
            let ready = Ready {
                t,
                y: dec.cache_y.clone(),
                u: dec.cache_u.clone(),
                v: dec.cache_v.clone(),
                ok,
            };
            let mut g = m.lock().unwrap();
            g.ready = Some(ready);
            ready_cv.notify_all();
        }
    });
    Worker { sh, mode, width, height, full_range, join: Some(join) }
}

impl Worker {
    fn fetch(&self, t: f64, y: &mut [u8], u: Option<&mut [u8]>, v: Option<&mut [u8]>) -> bool {
        let (m, req_cv, ready_cv) = &*self.sh;
        let mut g = m.lock().unwrap();
        let matches = |r: &Option<Ready>| r.as_ref().map_or(false, |r| (r.t - t).abs() < T_EPS);
        if !matches(&g.ready) {
            g.req = Some(t);
            req_cv.notify_all();
            while !matches(&g.ready) && !g.dead {
                g = ready_cv.wait(g).unwrap();
            }
        }
        match g.ready.as_ref() {
            Some(r) if r.ok => {
                y.copy_from_slice(&r.y);
                if let Some(u) = u { u.copy_from_slice(&r.u); }
                if let Some(v) = v { v.copy_from_slice(&r.v); }
                true
            }
            _ => false,
        }
    }

    fn prefetch(&self, t: f64) {
        let (m, req_cv, _) = &*self.sh;
        let mut g = m.lock().unwrap();
        let already = g.ready.as_ref().map_or(false, |r| (r.t - t).abs() < T_EPS);
        if g.req.is_none() && !already {
            g.req = Some(t);
            req_cv.notify_all();
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        {
            let (m, req_cv, _) = &*self.sh;
            m.lock().unwrap().dead = true;
            req_cv.notify_all();
        }
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}

// ---------- registry + C ABI ----------

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
