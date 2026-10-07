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

use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use anyrender::{Filter, Glyph, PaintScene, ResourceId, Scene};
use anyrender::filters::FilterEffect;
use parley::fontique::{Blob, CollectionOptions, FontInfoOverride};
use parley::{
    Alignment, AlignmentOptions, FontContext, FontFamily, FontStyle, FontWeight, Layout,
    LayoutContext, LineHeight, PositionedLayoutItem, StyleProperty,
};
use vello_common::paint::ImageId;
use vello_cpu::color::{AlphaColor, DynamicColor, Srgb};
use vello_cpu::kurbo::{Affine, BezPath, Circle, Point, Rect, RoundedRect, Shape, Stroke, Vec2};
use vello_cpu::peniko::{BlendMode, Compose, ColorStop, Extend, Fill, FontData, Gradient, ImageBrush, ImageQuality, ImageSampler, Mix};
use vello_cpu::{Level, Pixmap, RenderContext, RenderSettings, Resources};

pub use cpu::CpuPainter;

const DEFAULT_FONT: &[u8] = include_bytes!("../fonts/NotoSans-Regular.ttf");

#[derive(Clone, PartialEq, Default, Debug)]
struct Brush([f32; 4]);

struct State {
    fcx: FontContext,
    lcx: LayoutContext<Brush>,
    families: Vec<String>,
    by_path: HashMap<String, i32>,
    ctx: Option<(u16, u16, u16, RenderContext)>,
    res: Resources,
    layout: Layout<Brush>,
    cache: HashMap<String, Layout<Brush>>,
    /// Image slots as the stream names them, and what each slot is to the CPU painter.
    images: Vec<(ResourceId, u16, u16)>,
    ids: HashMap<ResourceId, ImageId>,
    /// Lottie compositions as the stream names them (opcode 116).
    lotties: Vec<velato::Composition>,
}

fn state() -> &'static Mutex<State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(|| {
        let mut fcx = FontContext {
            collection: parley::fontique::Collection::new(CollectionOptions {
                shared: false,
                system_fonts: false,
                ..Default::default()
            }),
            source_cache: Default::default(),
        };
        let mut st = State {
            lcx: LayoutContext::new(),
            families: Vec::new(),
            by_path: HashMap::new(),
            ctx: None,
            res: Resources::new(),
            layout: Layout::new(),
            cache: HashMap::new(),
            images: Vec::new(),
            ids: HashMap::new(),
            lotties: Vec::new(),
            fcx: FontContext::new(),
        };
        std::mem::swap(&mut st.fcx, &mut fcx);
        register(&mut st, Arc::new(DEFAULT_FONT.to_vec()));
        Mutex::new(st)
    })
}

fn register(st: &mut State, bytes: Arc<Vec<u8>>) -> i32 {
    let id = st.families.len() as i32;
    let name = format!("moonsplice-font-{id}");
    let blob = Blob::new(bytes);
    let fams = st.fcx.collection.register_fonts(
        blob,
        Some(FontInfoOverride { family_name: Some(&name), ..Default::default() }),
    );
    if fams.is_empty() {
        return -1;
    }
    st.families.push(name);
    id
}

fn color(r: f32, g: f32, b: f32, a: f32) -> AlphaColor<Srgb> {
    AlphaColor::<Srgb>::new([r, g, b, a])
}

struct Reader<'a> {
    d: &'a [f32],
    i: usize,
}
impl<'a> Reader<'a> {
    fn next(&mut self) -> Option<f32> {
        let v = self.d.get(self.i).copied();
        self.i += 1;
        v
    }
    fn take<const N: usize>(&mut self) -> Option<[f32; N]> {
        let mut out = [0f32; N];
        for s in out.iter_mut() {
            *s = self.next()?;
        }
        Some(out)
    }
}

struct TextRun<'a> {
    text: &'a str,
    color: [f32; 4],
    bold: bool,
    italic: bool,
}

struct TextSpec<'a> {
    font: usize,
    size: f32,
    ls: f32,
    wrap: f32,
    leading: f32,
    align: i32,
    runs: Vec<TextRun<'a>>,
}

fn spec_key(spec: &TextSpec) -> String {
    let mut k = format!("{}|{}|{}|{}|{}|{}", spec.font, spec.size, spec.ls, spec.wrap, spec.leading, spec.align);
    for r in &spec.runs {
        k.push('\u{1}');
        k.push_str(r.text);
        k.push_str(&format!("|{:?}|{}|{}", r.color, r.bold, r.italic));
    }
    k
}

// Shaping + line breaking is the expensive half of text; comps re-draw the same
// strings every frame, so keep built layouts (bounded) and swap them in.
fn build_layout(st: &mut State, spec: &TextSpec) {
    let key = spec_key(spec);
    if let Some(l) = st.cache.get(&key) {
        st.layout = l.clone();
        return;
    }
    build_layout_uncached(st, spec);
    if st.cache.len() > 4096 {
        st.cache.clear();
    }
    st.cache.insert(key, st.layout.clone());
}

fn build_layout_uncached(st: &mut State, spec: &TextSpec) {
    let State { fcx, lcx, families, layout, .. } = st;
    let mut text = String::new();
    let mut ranges = Vec::with_capacity(spec.runs.len());
    for r in &spec.runs {
        let s = text.len();
        text.push_str(r.text);
        ranges.push(s..text.len());
    }
    let family = families.get(spec.font).cloned().unwrap_or_else(|| families[0].clone());
    let mut b = lcx.ranged_builder(fcx, &text, 1.0, false);
    b.push_default(FontFamily::named(&family));
    b.push_default(StyleProperty::FontSize(spec.size));
    b.push_default(StyleProperty::LetterSpacing(spec.ls));
    b.push_default(StyleProperty::LineHeight(if spec.leading > 0.0 {
        LineHeight::MetricsRelative(spec.leading)
    } else {
        LineHeight::MetricsRelative(1.0)
    }));
    b.push_default(StyleProperty::Brush(Brush([1.0, 1.0, 1.0, 1.0])));
    for (r, range) in spec.runs.iter().zip(ranges) {
        b.push(StyleProperty::Brush(Brush(r.color)), range.clone());
        if r.bold {
            b.push(StyleProperty::FontWeight(FontWeight::BOLD), range.clone());
        }
        if r.italic {
            b.push(StyleProperty::FontStyle(FontStyle::Italic), range.clone());
        }
    }
    b.build_into(layout, &text);
    layout.break_all_lines(if spec.wrap > 0.0 { Some(spec.wrap) } else { None });
    let al = match spec.align {
        1 => Alignment::Center,
        2 => Alignment::End,
        _ => Alignment::Start,
    };
    layout.align(al, AlignmentOptions::default());
}

fn draw_text(
    st: &State,
    sc: &mut Scene,
    base: Affine,
    x: f32,
    y: f32,
    outline: (f32, [f32; 4]),
    embolden: f32,
) {
    let xf = base * Affine::translate((x as f64, y as f64));
    for line in st.layout.lines() {
        for item in line.items() {
            let PositionedLayoutItem::GlyphRun(gr) = item else { continue };
            let run = gr.run();
            let font: &FontData = run.font();
            let size = run.font_size();
            let skew = run.synthesis().skew().map(|a| Affine::skew((a.to_radians()).tan() as f64, 0.0));
            let emb = if run.synthesis().embolden() { size * 0.03 } else { 0.0 } + embolden;
            let glyphs = gr.positioned_glyphs().map(|g| Glyph { id: g.id, x: g.x, y: g.y }).collect::<Vec<_>>();
            if outline.0 > 0.0 {
                let c = outline.1;
                sc.draw_glyphs(font, size, false, run.normalized_coords(), Vec2::ZERO,
                    &Stroke::new(outline.0 as f64), color(c[0], c[1], c[2], c[3]), 1.0, xf, skew, glyphs.iter().copied());
            }
            let c = gr.style().brush.0;
            sc.draw_glyphs(font, size, true, run.normalized_coords(), Vec2::new(emb as f64, emb as f64 * 0.8),
                Fill::NonZero, color(c[0], c[1], c[2], c[3]), 1.0, xf, skew, glyphs.iter().copied());
        }
    }
}

/// Whether two closed paths wind the same way (signed area has the same sign).
fn hole_winds_like(a: &BezPath, b: &BezPath) -> bool {
    (a.area() > 0.0) == (b.area() > 0.0)
}

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

/// What a 105 closes, and for a scratch frame, what to do with it.
enum Fx { Effects([f32; 9]), Chain(Vec<Pass>) }
/// One pass of an `s:fx` chain: the CPU maths in fx.rs, or the comp's own GLSL on the GPU.
enum Pass { Cpu(u32, f32, f32), Shader(String, f32) }

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

/// A chain over a premultiplied frame: runs of CPU passes together (one conversion each way),
/// shader passes on the GPU between them.
fn run_passes(px: &mut [u8], w: usize, h: usize, passes: &[Pass]) -> Result<(), String> {
    let mut cpu: Vec<(u32, f32, f32)> = Vec::new();
    for p in passes {
        match p {
            Pass::Cpu(k, a, e) => cpu.push((*k, *a, *e)),
            Pass::Shader(src, t) => {
                fx::run_chain(px, w, h, &cpu);
                cpu.clear();
                shader(src, px, w, h, *t)?;
            }
        }
    }
    fx::run_chain(px, w, h, &cpu);
    Ok(())
}

#[cfg(feature = "gpu")]
fn shader(src: &str, px: &mut [u8], w: usize, h: usize, t: f32) -> Result<(), String> {
    moonsplice_render::shader_pass(src, px, w as u32, h as u32, t).map_err(|e| format!("shadertoy: {e}"))
}
#[cfg(not(feature = "gpu"))]
fn shader(_: &str, _: &mut [u8], _: usize, _: usize, _: f32) -> Result<(), String> {
    Err("shadertoy: this build has no GPU (moonsplice-scene without the gpu feature)".into())
}
enum Close {
    /// run the effects on the scratch frame (sw x sh at frame-space ox, oy) and put it back
    Fx(Fx, (i32, i32, u16, u16)),
    /// warp the flat page (pw x ph) onto a stage (sw x sh) and draw the stage with `place`
    Persp(persp::Camera, (u16, u16, u16, u16), (f32, f32), Affine),
    /// displace the flat page (pw x ph) as a grid onto a stage (sw x sh), drawn with `place`
    Displace(displace::Grid, (u16, u16, u16, u16), (f32, f32), Affine),
}
struct Frame {
    scene: Scene,
    /// the transform from what the stream says to this frame's pixels (identity for the frame)
    off: Affine,
    fx: Option<Close>,
}

#[allow(clippy::too_many_arguments)]
fn run(st: &mut State, cmds: &[f32], strings: &[u8], w: u16, h: u16, scale: f32, threads: u16, out: &mut [u8]) -> Option<()> {
    if out.len() != w as usize * h as usize * 4 {
        return None;
    }
    // vello_cpu filters are single-threaded only: any 108 in the stream pins threads to 0
    let has_filter = {
        let mut r = Reader { d: cmds, i: 0 };
        let mut found = false;
        while let Some(op) = r.next() {
            let n = match op as u32 { 0 => 8, 1 => 9, 2 => 7, 3 | 4 => 2, 5 => 6, 6 => 4, 7 => 5, 8 => 16, 9 => 11, 10 => 2,
                100 => 6, 101 => { let hdr = r.take::<15>(); match hdr { Some(h) => (h[14] as usize) * 8, None => 0 } }, 102 => 4, 103 => 7, 104 => 5, 105 => 0,
                106 => 6, 107 => 2, 108 => { found = true; 2 }, 110 => 1, 111 => 13, 113 => 5, 114 => 21, 115 => 9, 116 => 7, 112 => { let hdr = r.take::<5>(); match hdr { Some(h) => (h[0] as usize) * 4, None => 0 } }, _ => 0 };
            r.i += n;
        }
        found
    };
    let threads = if has_filter { 0 } else { threads };

    let mut frames = vec![Frame { scene: Scene::new(), off: Affine::IDENTITY, fx: None }];
    // whether a 105 pops a layer (false) or closes a scratch frame (true)
    let mut layers: Vec<bool> = Vec::new();
    let mut temp: Vec<ResourceId> = Vec::new();
    // Scene units onto output pixels. Every transform is composed from this, so a scaled preview
    // is the same drawing seen from further away rather than a different drawing.
    let root = if scale == 1.0 { Affine::IDENTITY } else { Affine::scale(scale as f64) };
    let mut base = root;
    let mut path = BezPath::new();
    let mut grain: Option<(f32, u32)> = None;
    let mut grains: Vec<(f32, u32, usize, usize, usize, usize)> = Vec::new();
    let mut rd = Reader { d: cmds, i: 0 };
    let sref = |off: f32, len: f32| -> Option<&str> {
        let (o, l) = (off as usize, len as usize);
        std::str::from_utf8(strings.get(o..o + l)?).ok()
    };
    let solid = |r: f32, g: f32, b: f32, a: f32| color(r, g, b, a);
    let ok = (|| -> Option<()> {
        while let Some(op) = rd.next() {
            let off = frames.last()?.off;
            let cur = off * base;
            match op as u32 {
                0 => {
                    let [x, y, rw, rh, r, g, b, a] = rd.take::<8>()?;
                    frames.last_mut()?.scene.fill(Fill::NonZero, cur, solid(r, g, b, a), None,
                        &Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64));
                }
                1 => {
                    let [x, y, rw, rh, rad, r, g, b, a] = rd.take::<9>()?;
                    let rr = RoundedRect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64, rad as f64);
                    frames.last_mut()?.scene.fill(Fill::NonZero, cur, solid(r, g, b, a), None, &rr);
                }
                2 => {
                    let [cx, cy, rad, r, g, b, a] = rd.take::<7>()?;
                    frames.last_mut()?.scene.fill(Fill::NonZero, cur, solid(r, g, b, a), None,
                        &Circle::new(Point::new(cx as f64, cy as f64), rad as f64));
                }
                3 => {
                    let [x, y] = rd.take::<2>()?;
                    path.move_to(Point::new(x as f64, y as f64));
                }
                4 => {
                    let [x, y] = rd.take::<2>()?;
                    path.line_to(Point::new(x as f64, y as f64));
                }
                5 => {
                    let [x1, y1, x2, y2, x, y] = rd.take::<6>()?;
                    path.curve_to(Point::new(x1 as f64, y1 as f64), Point::new(x2 as f64, y2 as f64), Point::new(x as f64, y as f64));
                }
                6 => {
                    let [r, g, b, a] = rd.take::<4>()?;
                    path.close_path();
                    frames.last_mut()?.scene.fill(Fill::NonZero, cur, solid(r, g, b, a), None, &path);
                    path = BezPath::new();
                }
                7 => {
                    let [width, r, g, b, a] = rd.take::<5>()?;
                    frames.last_mut()?.scene.stroke(&Stroke::new(width as f64), cur, solid(r, g, b, a), None, &path);
                    path = BezPath::new();
                }
                8 => {
                    let [x, y, rw, rh, x0, y0, x1, y1] = rd.take::<8>()?;
                    let [r0, g0, b0, a0, r1, g1, b1, a1] = rd.take::<8>()?;
                    let grad = Gradient::new_linear(Point::new(x0 as f64, y0 as f64), Point::new(x1 as f64, y1 as f64)).with_stops([
                        ColorStop { offset: 0.0, color: DynamicColor::from_alpha_color(color(r0, g0, b0, a0)) },
                        ColorStop { offset: 1.0, color: DynamicColor::from_alpha_color(color(r1, g1, b1, a1)) },
                    ]);
                    frames.last_mut()?.scene.fill(Fill::NonZero, cur, &grad, None,
                        &Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64));
                }
                9 => {
                    let [cx, cy, rad] = rd.take::<3>()?;
                    let [r0, g0, b0, a0, r1, g1, b1, a1] = rd.take::<8>()?;
                    let grad = Gradient::new_radial(Point::new(cx as f64, cy as f64), rad).with_stops([
                        ColorStop { offset: 0.0, color: DynamicColor::from_alpha_color(color(r0, g0, b0, a0)) },
                        ColorStop { offset: 1.0, color: DynamicColor::from_alpha_color(color(r1, g1, b1, a1)) },
                    ]);
                    frames.last_mut()?.scene.fill(Fill::NonZero, cur, &grad, None,
                        &Rect::new((cx - rad) as f64, (cy - rad) as f64, (cx + rad) as f64, (cy + rad) as f64));
                }
                10 => {
                    let [amount, seed] = rd.take::<2>()?;
                    grain = Some((amount, seed as u32));
                }
                103 => {
                    let [id, x, y, rw, rh, rx, alpha] = rd.take::<7>()?;
                    let (rid, iw, ih) = *st.images.get(id as usize)?;
                    let brush = anyrender::Paint::Resource(ImageBrush {
                        image: rid,
                        sampler: ImageSampler { x_extend: Extend::Pad, y_extend: Extend::Pad, quality: ImageQuality::Medium, alpha: 1.0 },
                    });
                    let sc = &mut frames.last_mut()?.scene;
                    let layered = alpha < 0.999;
                    if layered { sc.push_layer(Mix::Normal, alpha.max(0.0), Affine::IDENTITY, &everything(), None, None); }
                    let bt = Affine::translate((x as f64, y as f64)) * Affine::scale_non_uniform(rw as f64 / iw as f64, rh as f64 / ih as f64);
                    let r = Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64);
                    if rx > 0.0 { sc.fill(Fill::NonZero, cur, brush, Some(bt), &RoundedRect::from_rect(r, rx as f64)); }
                    else { sc.fill(Fill::NonZero, cur, brush, Some(bt), &r); }
                    if layered { sc.pop_layer(); }
                }
                104 => {
                    layers.push(false);
                    let [x, y, rw, rh, rx] = rd.take::<5>()?;
                    let r = Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64);
                    let sc = &mut frames.last_mut()?.scene;
                    if rx > 0.0 { sc.push_clip_layer(cur, &RoundedRect::from_rect(r, rx as f64)); } else { sc.push_clip_layer(cur, &r); }
                }
                105 => {
                    if layers.pop() == Some(true) {
                        // close the scratch frame: render, run the effect chain, composite
                        let fr = frames.pop()?;
                        let (pm, place, (ox, oy, sw, sh)) = match fr.fx? {
                            Close::Fx(fx, (ox, oy, sw, sh)) => {
                                let mut sub = RenderContext::new_with(sw, sh, settings(threads));
                                let mut pm = paint_cpu(&mut sub, &mut st.res, &st.ids, fr.scene);
                                match fx {
                                    Fx::Effects(fx) => effects::apply(pm.data_as_u8_slice_mut(), sw as usize, sh as usize,
                                        fx[0], fx[1], fx[2], fx[3], fx[4], fx[5], fx[6], fx[7], fx[8]),
                                    Fx::Chain(passes) => {
                                        if let Err(e) = run_passes(pm.data_as_u8_slice_mut(), sw as usize, sh as usize, &passes) {
                                            set_error(e);
                                            return None;
                                        }
                                    }
                                }
                                (pm, frames.last()?.off, (ox, oy, sw, sh))
                            }
                            Close::Persp(cam, (pw, ph, sw, sh), (x0, y0), place) => {
                                let mut sub = RenderContext::new_with(pw, ph, settings(threads));
                                let page = paint_cpu(&mut sub, &mut st.res, &st.ids, fr.scene);
                                let stage = persp::warp(page.data_as_u8_slice(), pw as usize, ph as usize, sw as usize, sh as usize, x0, y0, &cam);
                                (premul_pixmap(stage, sw, sh), place, (0, 0, sw, sh))
                            }
                            Close::Displace(grid, (pw, ph, sw, sh), (x0, y0), place) => {
                                let mut sub = RenderContext::new_with(pw, ph, settings(threads));
                                let page = paint_cpu(&mut sub, &mut st.res, &st.ids, fr.scene);
                                let stage = displace::warp(page.data_as_u8_slice(), pw as usize, ph as usize, sw as usize, sh as usize, x0, y0, &grid);
                                (premul_pixmap(stage, sw, sh), place, (0, 0, sw, sh))
                            }
                        };
                        let rid = ResourceId::new();
                        st.ids.insert(rid, st.res.register_image(Arc::new(pm)));
                        temp.push(rid);
                        let parent = frames.last_mut()?;
                        parent.scene.fill(Fill::NonZero, place,
                            anyrender::Paint::Resource(ImageBrush {
                                image: rid,
                                sampler: ImageSampler { x_extend: Extend::Pad, y_extend: Extend::Pad, quality: ImageQuality::Low, alpha: 1.0 },
                            }),
                            Some(Affine::translate((ox as f64, oy as f64))),
                            &Rect::new(ox as f64, oy as f64, (ox + sw as i32) as f64, (oy + sh as i32) as f64));
                    } else {
                        frames.last_mut()?.scene.pop_layer();
                    }
                }
                114 => {
                    let [ox, oy, pw, ph, sw, sh] = rd.take::<6>()?;
                    let hi = rd.take::<9>()?;
                    let [r20, r21, dz, focus_w, aperture, maxcoc] = rd.take::<6>()?;
                    let size = |v: f32| v.ceil().clamp(1.0, 16384.0) as u16;
                    let cam = persp::Camera { hi, r20, r21, dz, focus_w, aperture, maxcoc };
                    // The stage is the box the page projects into; the authored margin
                    // (sw x sh, centred) only when part of the page is behind the camera.
                    let [x0, y0, x1, y1] = cam.stage_box(pw, ph).unwrap_or([-sw / 2.0, -sh / 2.0, sw / 2.0, sh / 2.0]);
                    let (x0, y0) = (x0.floor(), y0.floor());
                    let (pw_, ph_, sw_, sh_) = (size(pw), size(ph), size(x1 - x0), size(y1 - y0));
                    // stage coordinates are relative to the page's centre in node space
                    let place = cur * Affine::translate(((ox + pw / 2.0 + x0) as f64, (oy + ph / 2.0 + y0) as f64));
                    frames.push(Frame {
                        scene: Scene::new(),
                        // node space (ox, oy) is the page's origin, at page pixels
                        off: Affine::translate((-ox as f64, -oy as f64)) * base.inverse(),
                        fx: Some(Close::Persp(cam, (pw_, ph_, sw_, sh_), (x0, y0), place)),
                    });
                    layers.push(true);
                }
                115 => {
                    let [ox, oy, pw, ph, cols, rows, t, amp, freq] = rd.take::<9>()?;
                    let size = |v: f32| v.ceil().clamp(1.0, 16384.0) as u16;
                    let grid = displace::Grid { cols: cols.max(1.0) as usize, rows: rows.max(1.0) as usize, t, amp, freq };
                    let m = grid.reach().ceil();
                    let (x0, y0) = (-m, -m);
                    let (pw_, ph_, sw_, sh_) = (size(pw), size(ph), size(pw + 2.0 * m), size(ph + 2.0 * m));
                    frames.push(Frame {
                        scene: Scene::new(),
                        off: Affine::translate((-ox as f64, -oy as f64)) * base.inverse(),
                        fx: Some(Close::Displace(grid, (pw_, ph_, sw_, sh_), (x0, y0),
                            cur * Affine::translate(((ox + x0) as f64, (oy + y0) as f64)))),
                    });
                    layers.push(true);
                }
                116 => {
                    let [id, frame, x, y, rw, rh, alpha] = rd.take::<7>()?;
                    let c = st.lotties.get(id as usize)?;
                    let fit = Affine::translate((x as f64, y as f64))
                        * Affine::scale_non_uniform(rw as f64 / c.width.max(1) as f64, rh as f64 / c.height.max(1) as f64);
                    lottie::draw(&mut frames.last_mut()?.scene, c, frame as f64, cur * fit, alpha as f64);
                }
                113 => {
                    // clip to everything but the box: the frame with the box cut out of it, the hole
                    // wound the other way so the nonzero rule leaves it empty
                    layers.push(false);
                    let [x, y, rw, rh, rx] = rd.take::<5>()?;
                    let r = Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64);
                    let hole = if rx > 0.0 { RoundedRect::from_rect(r, rx as f64).to_path(0.1) } else { r.to_path(0.1) };
                    let inv = cur.inverse();
                    let mut p = (inv * Rect::new(-1.0e6, -1.0e6, 1.0e6, 1.0e6).to_path(0.1)).reverse_subpaths();
                    if hole_winds_like(&hole, &p) { p = p.reverse_subpaths(); }
                    p.extend(hole);
                    frames.last_mut()?.scene.push_clip_layer(cur, &p);
                }
                111 | 112 => {
                    let (fxp, [bx, by, bw, bh]) = if op as u32 == 111 {
                        let mut p = rd.take::<9>()?;
                        p[0] *= scale; // blur radius, in pixels of the frame being drawn
                        (Fx::Effects(p), rd.take::<4>()?)
                    } else {
                        let [n, bx, by, bw, bh] = rd.take::<5>()?;
                        let mut passes = Vec::with_capacity(n as usize);
                        for _ in 0..(n as usize) {
                            let [k, a, e, x] = rd.take::<4>()?;
                            passes.push(match k as u32 {
                                // the comp's GLSL: a = string offset, e = length, x = t
                                13 => Pass::Shader(sref(a, e)?.to_string(), x),
                                // kind 0 is blur in the chain too, and its amount is a radius.
                                k => Pass::Cpu(k, if k == 0 { a * scale } else { a }, e),
                            });
                        }
                        (Fx::Chain(passes), [bx, by, bw, bh])
                    };
                    // frame-space bbox of the node box under the current affine
                    let corners = [
                        base * Point::new(bx as f64, by as f64),
                        base * Point::new((bx + bw) as f64, by as f64),
                        base * Point::new(bx as f64, (by + bh) as f64),
                        base * Point::new((bx + bw) as f64, (by + bh) as f64),
                    ];
                    let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
                    for c in corners { x0 = x0.min(c.x); y0 = y0.min(c.y); x1 = x1.max(c.x); y1 = y1.max(c.y); }
                    let ox = x0.floor() as i32;
                    let oy = y0.floor() as i32;
                    let sw = ((x1.ceil() as i32) - ox).clamp(1, 16384) as u16;
                    let sh = ((y1.ceil() as i32) - oy).clamp(1, 16384) as u16;
                    frames.push(Frame {
                        scene: Scene::new(),
                        off: Affine::translate((-ox as f64, -oy as f64)),
                        fx: Some(Close::Fx(fxp, (ox, oy, sw, sh))),
                    });
                    layers.push(true);
                }
                106 => {
                    let [amount, seed, x, y, rw, rh] = rd.take::<6>()?;
                    let p0 = base * Point::new(x as f64, y as f64);
                    let p1 = base * Point::new((x + rw) as f64, (y + rh) as f64);
                    grains.push((amount, seed as u32, p0.x.min(p1.x).max(0.0) as usize, p0.y.min(p1.y).max(0.0) as usize,
                        (p0.x.max(p1.x).min(w as f64)) as usize, (p0.y.max(p1.y).min(h as f64)) as usize));
                }
                107 => {
                    layers.push(false);
                    let [mix, compose] = rd.take::<2>()?;
                    let mix = match mix as u32 {
                        1 => Mix::Multiply, 2 => Mix::Screen, 3 => Mix::Overlay, 4 => Mix::Darken, 5 => Mix::Lighten,
                        6 => Mix::ColorDodge, 7 => Mix::ColorBurn, 8 => Mix::HardLight, 9 => Mix::SoftLight,
                        10 => Mix::Difference, 11 => Mix::Exclusion, 12 => Mix::Hue, 13 => Mix::Saturation,
                        14 => Mix::Color, 15 => Mix::Luminosity, _ => Mix::Normal,
                    };
                    let compose = match compose as u32 { 1 => Compose::Plus, _ => Compose::SrcOver };
                    frames.last_mut()?.scene.push_layer(BlendMode::new(mix, compose), 1.0, Affine::IDENTITY, &everything(), None, None);
                }
                108 => {
                    layers.push(false);
                    let [kind, amount] = rd.take::<2>()?;
                    let e = match kind as u32 {
                        // A radius is a length, so it is in scene units like every other length.
                        0 => FilterEffect::blur(amount * scale),
                        1 => FilterEffect::brightness(amount),
                        2 => FilterEffect::contrast(amount),
                        3 => FilterEffect::saturate(amount),
                        4 => FilterEffect::grayscale(amount),
                        5 => FilterEffect::sepia(amount),
                        6 => FilterEffect::invert(amount),
                        7 => FilterEffect::opacity(amount),
                        _ => FilterEffect::hue_rotate(amount.to_radians()),
                    };
                    frames.last_mut()?.scene.push_layer(Mix::Normal, 1.0, Affine::IDENTITY, &everything(),
                        Some(Arc::new(Filter::single(e))), None);
                }
                110 => {
                    layers.push(false);
                    let [a] = rd.take::<1>()?;
                    frames.last_mut()?.scene.push_layer(Mix::Normal, a, Affine::IDENTITY, &everything(), None, None);
                }
                102 => {
                    let [r, g, b, a] = rd.take::<4>()?;
                    frames.last_mut()?.scene.fill(Fill::NonZero, off, solid(r, g, b, a), None, &Rect::new(0.0, 0.0, w as f64, h as f64));
                }
                100 => {
                    let [a, b, c, d, e, f] = rd.take::<6>()?;
                    base = root * Affine::new([a as f64, b as f64, c as f64, d as f64, e as f64, f as f64]);
                }
                101 => {
                    let [font, size, x, y, ls, wrap, leading, align, ow] = rd.take::<9>()?;
                    let [or_, og, ob, oa, emb, nruns] = rd.take::<6>()?;
                    let mut runs = Vec::with_capacity(nruns as usize);
                    for _ in 0..nruns as usize {
                        let [off, len, r, g, b, a, bold, italic] = rd.take::<8>()?;
                        runs.push(TextRun { text: sref(off, len)?, color: [r, g, b, a], bold: bold > 0.5, italic: italic > 0.5 });
                    }
                    let spec = TextSpec { font: font as usize, size, ls, wrap, leading, align: align as i32, runs };
                    build_layout(st, &spec);
                    draw_text(st, &mut frames.last_mut()?.scene, cur, x, y, (ow, [or_, og, ob, oa]), emb);
                }
                _ => return None,
            }
        }
        Some(())
    })();
    let need_new = match &st.ctx {
        Some((cw, ch, ct, _)) => *cw != w || *ch != h || *ct != threads,
        None => true,
    };
    if need_new {
        st.ctx = Some((w, h, threads, RenderContext::new_with(w, h, settings(threads))));
    }
    let mut ctx = st.ctx.take()?.3;
    let result = ok.filter(|_| frames.len() == 1).map(|_| {
        let scene = frames.pop().unwrap().scene;
        let pm = paint_cpu(&mut ctx, &mut st.res, &st.ids, scene);
        out.copy_from_slice(pm.data_as_u8_slice());
        if let Some((amount, seed)) = grain {
            grains.push((amount, seed, 0, 0, w as usize, h as usize));
        }
        for (amount, seed, x0, y0, x1, y1) in grains {
            let amp = (amount * 255.0) as i32;
            if amp > 0 {
                for yy in y0..y1 { for xx in x0..x1 {
                    let i = yy * w as usize + xx;
                    let mut n = (i as u32).wrapping_mul(0x9E3779B9).wrapping_add(seed.wrapping_mul(0x85EBCA6B));
                    n ^= n >> 16;
                    n = n.wrapping_mul(0x7FEB352D);
                    n ^= n >> 15;
                    let d = ((n & 0xFF) as i32 - 128) * amp / 128;
                    for c in 0..3 {
                        out[i * 4 + c] = (out[i * 4 + c] as i32 + d).clamp(0, 255) as u8;
                    }
                } }
            }
        }
    });
    for rid in temp {
        if let Some(id) = st.ids.remove(&rid) { st.res.destroy_image(id); }
    }
    st.ctx = Some((w, h, threads, ctx));
    result
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
