// moonsplice-scene: the single rasterizer under the Lua timeline.
//
// The engine evaluates the scene graph at t and streams the *whole* visible tree
// here as one flat f32 command list (+ a string table). The stream is recorded into
// an anyrender Scene, which any backend can paint; the CPU painter (cpu.rs, vello_cpu
// 0.3) paints it into one premultiplied RGBA buffer: one antialiaser, one font stack,
// one gamma.
// Nothing here depends on previous frames; thread count is pinned by the caller
// because multithreaded tiling changes rounding (±1) in a handful of pixels.
//
// Command stream (f32s):
//   0..10  identical to moonsplice-vector (rect rrect circle move line cubic fill stroke grad radial grain)
//   100 transform  a b c d e f            absolute affine for subsequent ops
//   102 clear      r g b a                  fill the whole frame (background)
//   103 image      id x y w h rx alpha      registered image scaled into the box
//   104 clip_push  x y w h rx               clip layer (node-local rect) until 105
//   105 clip_pop
//   106 grain      amount seed x y w h      film grain over a frame-space rect
//   107 blend_push mix compose              blend layer until 105 (mix: peniko Mix 0-15, normal..luminosity; compose: 0 srcover 1 plus)
//   108 filter_push kind amount             CSS filter layer until 105 (0 blur 1 brightness 2 contrast 3 saturate 4 grayscale 5 sepia 6 invert 7 opacity 8 hue)
//   110 opacity_push a                      group opacity layer until 105
//   113 clip_outside x y w h rx             clip layer to everything *but* the box until 105 (clip_invert)
//   114 persp_push ox oy w h sw sh Hi[9] r20 r21 dz focus_w aperture maxcoc
//                                          perspective plane until 105: what is drawn is the flat
//                                          page at node-space (ox, oy, w, h); it is warped through
//                                          the camera (persp.rs) onto a sw x sh stage centred on it
//   115 displace_push ox oy w h cols rows t amp freq
//                                          s:displace until 105: the flat page at node-space
//                                          (ox, oy, w, h), moved as a grid mesh (displace.rs)
//   116 lottie     id frame x y w h alpha   Lottie `id` (cs_lottie_load) at Lottie frame `frame`,
//                                          its own box scaled into (x, y, w, h) (lottie.rs)
//   117 matte_push mode                     a track matte: what is drawn until 118 is the matte, in
//                                          a scratch frame the size of the output
//   118 matte_body                          then until 105 the layer that shows through it, in a
//                                          second scratch frame; 105 multiplies it by the matte
//                                          (mode 0 alpha, 1 alpha inverted, 2 luma, 3 luma
//                                          inverted; luma of the matte over black) and composites
//   111 fx_push blur bright contrast sat gray sepia invert opacity hue  bx by bw bh
//                                          render until 105 into a scratch frame the size of the
//                                          node box (transformed by the current affine), run
//                                          moonsplice-effects on it, composite back. Edge clamping
//                                          therefore matches love's per-node buffers.
//   101 text       font size x y ls wrap leading align outline_w  or og ob oa  embolden  nruns
//                  then nruns × (str_off str_len r g b a bold italic)
//                  (x,y) = top-left of the line box, like love.graphics.print
//
// C ABI:
//   cs_font_load(path) -> font id | -1            (id 0 = bundled NotoSans, loaded lazily)
//   cs_text_measure(font, size, text, ls, wrap, leading, out[2]) -> 0 | -1
//   cs_render(cmds, len, strings, strings_len, w, h, threads, out, out_len) -> 0 | -1
//   cs_render_scaled(..., w, h, scale, threads, out, out_len) -> 0 | -1
//       `w`/`h` are the OUTPUT size and `scale` maps scene units onto it: a preview of a
//       1920x1080 composition at 960x540 passes (960, 540, 0.5). Everything in the stream is in
//       scene units, so the scale is applied once, at the root of every transform, and to the
//       two things that are lengths in pixels rather than points -- blur radii.

mod cpu;
pub mod effects;
mod fx;
mod persp;
mod displace;
mod lottie;
#[cfg(feature = "html")]
pub mod html;
mod images;
mod run;
mod state;
mod text;
mod world;

use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use anyrender::{PaintScene, ResourceId, Scene};
use vello_common::paint::ImageId;
use vello_cpu::kurbo::{Affine, Rect};
use vello_cpu::{Level, Pixmap, RenderContext, RenderSettings, Resources};

pub use cpu::CpuPainter;
pub use images::{cs_image_register, cs_image_update};
pub use world::cs_world_render;

pub(crate) use images::premul_pixmap;

use run::run;
use state::{register, state};
use text::{build_layout, TextRun, TextSpec};

/// A layer that clips nothing. anyrender layers always carry a clip; the CPU painter sees that
/// this one covers the frame and drops it, and a GPU backend clips to the whole target, which is
/// the same thing.
fn everything() -> Rect {
    Rect::new(-1.0e7, -1.0e7, 1.0e7, 1.0e7)
}

fn settings(threads: u16) -> RenderSettings {
    RenderSettings { level: Level::try_detect().unwrap_or(Level::baseline()), num_threads: threads }
}

/// Paint a recorded scene into a pixmap on the CPU.
#[cfg(feature = "html")]
pub(crate) fn paint_cpu_scene(w: u16, h: u16, scene: Scene) -> Pixmap {
    let mut ctx = RenderContext::new_with(w, h, settings(0));
    let mut res = Resources::new();
    paint_cpu(&mut ctx, &mut res, &HashMap::new(), scene)
}

/// Paint a recorded scene into a pixmap on the CPU, with the stream's image slots.
fn paint_cpu(ctx: &mut RenderContext, res: &mut Resources, ids: &HashMap<ResourceId, ImageId>, scene: Scene) -> Pixmap {
    ctx.reset();
    let mut p = CpuPainter { ctx: &mut *ctx, res: &mut *res, images: ids, inline: Vec::new() };
    p.append_scene(scene, Affine::IDENTITY);
    let inline = std::mem::take(&mut p.inline);
    ctx.flush();
    let mut pm = Pixmap::new(ctx.width(), ctx.height());
    ctx.render(&mut pm, res);
    for id in inline {
        res.destroy_image(id);
    }
    pm
}

/// The last thing a render refused, in words, for `cs_last_error`.
fn set_error(msg: String) {
    *last_error().lock().unwrap() = std::ffi::CString::new(msg).unwrap_or_default();
}
fn last_error() -> &'static Mutex<std::ffi::CString> {
    static E: OnceLock<Mutex<std::ffi::CString>> = OnceLock::new();
    E.get_or_init(|| Mutex::new(std::ffi::CString::default()))
}

#[no_mangle]
pub extern "C" fn cs_last_error() -> *const c_char {
    last_error().lock().unwrap().as_ptr()
}

#[no_mangle]
pub extern "C" fn cs_font_load(path: *const c_char) -> c_int {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let p = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
        let mut st = state().lock().unwrap();
        if let Some(id) = st.by_path.get(&p) {
            return *id;
        }
        let Ok(bytes) = std::fs::read(&p) else { return -1 };
        let id = register(&mut st, Arc::new(bytes));
        if id >= 0 {
            st.by_path.insert(p, id);
        }
        id
    }));
    r.unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn cs_text_measure(
    font: c_int,
    size: f32,
    text: *const c_char,
    ls: f32,
    wrap: f32,
    leading: f32,
    out: *mut f32,
) -> c_int {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let t = unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned();
        let mut st = state().lock().unwrap();
        let spec = TextSpec {
            font: font.max(0) as usize,
            size,
            ls,
            wrap,
            leading,
            align: 0,
            runs: vec![TextRun { text: &t, color: [1.0; 4], bold: false, italic: false }],
        };
        build_layout(&mut st, &spec);
        let (w, h) = (st.layout.full_width(), st.layout.height());
        unsafe {
            *out = w;
            *out.add(1) = h;
        }
        0
    }));
    r.unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn cs_render(
    cmds: *const f32,
    len: usize,
    strings: *const u8,
    strings_len: usize,
    w: u16,
    h: u16,
    threads: u16,
    out: *mut u8,
    out_len: usize,
) -> c_int {
    cs_render_scaled(cmds, len, strings, strings_len, w, h, 1.0, threads, out, out_len)
}

/// The same render, with the scene drawn at `scale` into an output of `w`×`h`.
///
/// A preview is not the render: the window shows the composition in a pane that is usually
/// smaller than the composition, and rasterising pixels that are then thrown away is the largest
/// avoidable cost in the frame path. At `scale = 1.0` this is `cs_render` exactly -- the root
/// transform is the identity and every number reaching vello is the number it had before, which
/// is what keeps the goldens the goldens.
#[no_mangle]
pub extern "C" fn cs_render_scaled(
    cmds: *const f32,
    len: usize,
    strings: *const u8,
    strings_len: usize,
    w: u16,
    h: u16,
    scale: f32,
    threads: u16,
    out: *mut u8,
    out_len: usize,
) -> c_int {
    let r = catch_unwind(AssertUnwindSafe(|| {
        let cmds = unsafe { std::slice::from_raw_parts(cmds, len) };
        let strings = if strings_len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(strings, strings_len) } };
        let out = unsafe { std::slice::from_raw_parts_mut(out, out_len) };
        let mut st = state().lock().unwrap();
        run(&mut st, cmds, strings, w, h, scale, threads, out)
    }));
    match r {
        Ok(Some(())) => 0,
        _ => -1,
    }
}

/// Load a Lottie file. Returns its id for opcode 116, or -1 (cs_last_error says why);
/// `out` gets [first frame, end frame, frames per second, width, height].
#[no_mangle]
pub extern "C" fn cs_lottie_load(path: *const c_char, out: *mut f32) -> c_int {
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<c_int, String> {
        let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();
        let bytes = std::fs::read(&path).map_err(|e| format!("{path}: {e}"))?;
        let c = lottie::load(&bytes).map_err(|e| format!("{path}: {e}"))?;
        let info = lottie::info(&c);
        unsafe { std::ptr::copy_nonoverlapping(info.as_ptr(), out, 5) };
        let mut st = state().lock().unwrap();
        st.lotties.push(c);
        Ok((st.lotties.len() - 1) as c_int)
    }));
    match r {
        Ok(Ok(id)) => id,
        Ok(Err(why)) => { *last_error().lock().unwrap() = std::ffi::CString::new(why).unwrap_or_default(); -1 }
        Err(_) => -1,
    }
}

/// Memory for the caller to fill, where the caller has no allocator of its own in this address
/// space: the browser, which hands the stream over by writing into wasm memory.
#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn cs_alloc(len: usize) -> *mut u8 {
    let mut v = std::mem::ManuallyDrop::new(Vec::<u8>::with_capacity(len.max(1)));
    v.as_mut_ptr()
}

#[cfg(target_arch = "wasm32")]
#[no_mangle]
pub extern "C" fn cs_free(ptr: *mut u8, len: usize) {
    unsafe { drop(Vec::from_raw_parts(ptr, 0, len.max(1))) }
}
