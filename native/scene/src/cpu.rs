//! anyrender (0.13, the version Blitz paints with) on vello_cpu 0.3, owned here rather than taken from `anyrender_vello_cpu`.
//!
//! The scene stream (lib.rs) is recorded into an `anyrender::Scene`, which says nothing about
//! who paints it. This is the painter for the CPU: the one the goldens are taken from, and the
//! one that runs where there is no GPU. A GPU backend replays the same `Scene` (.robot/docs/engine.robot).
//!
//! Three things the stock backend does differently, and why they matter here:
//! - the thread count is the caller's. Multithreaded tiling changes rounding in a few pixels,
//!   so determinism is scoped to it, and a backend that picks its own breaks the goldens;
//! - filters are kept when the build has threads. vello_cpu filters only run single-threaded,
//!   so the caller pins threads to 0 for a frame with a filter in it instead;
//! - images are resources: a slot is registered once and a video frame replaces its pixels,
//!   where a blob cache would copy every frame into a new pixmap.

use std::collections::HashMap;
use std::sync::Arc;

use anyrender::{Filter, Glyph, NormalizedCoord, Paint, PaintRef, PaintScene, RenderContext as AnyContext, ResourceId};
use vello_common::filter_effects::{EdgeMode, Filter as VFilter, FilterPrimitive};
use vello_common::paint::ImageId;
use vello_cpu::kurbo::{Affine, Diagonal2, Rect, Shape, Stroke, Vec2};
use vello_cpu::peniko::{BlendMode, Color, Fill, FontData, ImageAlphaType, ImageBrush, ImageData, ImageFormat, StyleRef};
use vello_cpu::{ImageSource, PaintType, RenderContext, Resources};

const TOLERANCE: f64 = 0.1;

pub struct CpuPainter<'a> {
    pub ctx: &'a mut RenderContext,
    pub res: &'a mut Resources,
    pub images: &'a HashMap<ResourceId, ImageId>,
    /// Images handed over as pixels rather than by slot (Blitz's `<img>`), registered for this
    /// painting only; whoever renders the painting frees them.
    pub inline: Vec<ImageId>,
}

impl CpuPainter<'_> {
    fn inline_image(&mut self, img: &ImageData) -> Option<ImageId> {
        let (w, h) = (u16::try_from(img.width).ok()?, u16::try_from(img.height).ok()?);
        let bytes = img.data.data();
        let n = w as usize * h as usize;
        if bytes.len() < n * 4 {
            return None;
        }
        let bgra = img.format == ImageFormat::Bgra8;
        let premul = img.alpha_type == ImageAlphaType::AlphaPremultiplied;
        let px = (0..n)
            .map(|i| {
                let p = &bytes[i * 4..i * 4 + 4];
                let (r, g, b, a) = if bgra { (p[2], p[1], p[0], p[3]) } else { (p[0], p[1], p[2], p[3]) };
                let m = |c: u8| if premul || a == 255 { c } else { ((c as u32 * a as u32 + 127) / 255) as u8 };
                [m(r), m(g), m(b), a]
            })
            .collect::<Vec<_>>()
            .concat();
        let id = self.res.register_image(Arc::new(crate::premul_pixmap(px, w, h)));
        self.inline.push(id);
        Some(id)
    }

    fn paint(&mut self, paint: PaintRef<'_>) -> PaintType {
        match paint {
            Paint::Solid(c) => PaintType::Solid(c),
            Paint::Gradient(g) => PaintType::Gradient(g.clone()),
            Paint::Resource(b) => match self.images.get(&b.image) {
                Some(&id) => PaintType::Image(ImageBrush { image: ImageSource::opaque_id(id), sampler: b.sampler }),
                None => PaintType::Solid(Color::TRANSPARENT),
            },
            Paint::Image(b) => match self.inline_image(b.image) {
                Some(id) => PaintType::Image(ImageBrush { image: ImageSource::opaque_id(id), sampler: b.sampler }),
                None => PaintType::Solid(Color::TRANSPARENT),
            },
            Paint::Custom(_) => PaintType::Solid(Color::TRANSPARENT),
        }
    }

    /// A layer whose clip is the whole frame is a layer with no clip: vello_cpu then skips the
    /// clip mask, which is both cheaper and the drawing the stream meant.
    fn is_whole_frame(&self, transform: Affine, clip: &impl Shape) -> bool {
        let b = (transform * clip.into_path(TOLERANCE)).bounding_box();
        b.x0 <= 0.0 && b.y0 <= 0.0 && b.x1 >= self.ctx.width() as f64 && b.y1 >= self.ctx.height() as f64
    }
}

/// anyrender's filter graph, as far as vello_cpu runs one: a single primitive.
fn filter(f: &Filter) -> Option<VFilter> {
    use anyrender::filters::FilterEffect as E;
    let node = f.nodes().first()?;
    let p = match &node.effect {
        E::GaussianBlur(b) => FilterPrimitive::GaussianBlur { std_deviation: b.std_deviation, edge_mode: EdgeMode::None },
        E::ColorMatrix(m) => FilterPrimitive::ColorMatrix { matrix: m.0 },
        E::Offset(o) => FilterPrimitive::Offset { dx: o.x as f32, dy: o.y as f32 },
        E::Flood(c) => FilterPrimitive::Flood { color: *c },
        _ => return None,
    };
    Some(VFilter::from_primitive(p))
}

impl AnyContext for CpuPainter<'_> {}

impl PaintScene for CpuPainter<'_> {
    fn reset(&mut self) {
        self.ctx.reset();
    }

    fn push_layer(
        &mut self,
        blend: impl Into<BlendMode>,
        alpha: f32,
        transform: Affine,
        clip: &impl Shape,
        filter_: Option<Arc<Filter>>,
        _backdrop: Option<Arc<Filter>>,
    ) {
        let path = (!self.is_whole_frame(transform, clip)).then(|| clip.into_path(TOLERANCE));
        self.ctx.set_transform(transform);
        self.ctx.set_fill_rule(Fill::NonZero);
        let blend = blend.into();
        let f = filter_.as_deref().and_then(filter);
        self.ctx.push_layer(
            path.as_ref(),
            (blend != BlendMode::default()).then_some(blend),
            (alpha < 1.0).then_some(alpha),
            None,
            f,
        );
    }

    fn push_clip_layer(&mut self, transform: Affine, clip: &impl Shape) {
        self.ctx.set_transform(transform);
        self.ctx.set_fill_rule(Fill::NonZero);
        self.ctx.push_clip_layer(&clip.into_path(TOLERANCE));
    }

    fn pop_layer(&mut self) {
        self.ctx.pop_layer();
    }

    fn stroke<'b>(
        &mut self,
        style: &Stroke,
        transform: Affine,
        paint: impl Into<PaintRef<'b>>,
        brush_transform: Option<Affine>,
        shape: &impl Shape,
    ) {
        let p = self.paint(paint.into());
        self.ctx.set_transform(transform);
        self.ctx.set_stroke(style.clone());
        self.ctx.set_paint(p);
        self.ctx.set_paint_transform(brush_transform.unwrap_or(Affine::IDENTITY));
        self.ctx.stroke_path(&shape.into_path(TOLERANCE));
    }

    fn fill<'b>(
        &mut self,
        style: Fill,
        transform: Affine,
        paint: impl Into<PaintRef<'b>>,
        brush_transform: Option<Affine>,
        shape: &impl Shape,
    ) {
        let p = self.paint(paint.into());
        self.ctx.set_transform(transform);
        self.ctx.set_fill_rule(style);
        self.ctx.set_paint(p);
        self.ctx.set_paint_transform(brush_transform.unwrap_or(Affine::IDENTITY));
        // A rect has its own fast path in vello_cpu; the recording turns every shape into a path.
        match shape.as_rect() {
            Some(r) => self.ctx.fill_rect(&r),
            None => self.ctx.fill_path(&shape.into_path(TOLERANCE)),
        }
    }

    fn draw_glyphs<'b, 's: 'b>(
        &'s mut self,
        font: &'b FontData,
        font_size: f32,
        hint: bool,
        normalized_coords: &'b [NormalizedCoord],
        embolden: Vec2,
        style: impl Into<StyleRef<'b>>,
        paint: impl Into<PaintRef<'b>>,
        _brush_alpha: f32,
        transform: Affine,
        glyph_transform: Option<Affine>,
        glyphs: impl Iterator<Item = Glyph> + Clone,
    ) {
        let p = self.paint(paint.into());
        self.ctx.set_transform(transform);
        self.ctx.set_paint(p);
        let glyphs = glyphs.map(|g| vello_cpu::Glyph { id: g.id, x: g.x, y: g.y });
        match style.into() {
            StyleRef::Fill(fill) => {
                self.ctx.set_fill_rule(fill);
                let mut b = self
                    .ctx
                    .glyph_run(self.res, font)
                    .font_size(font_size)
                    .hint(hint)
                    .normalized_coords(normalized_coords)
                    .glyph_transform(glyph_transform.unwrap_or_default());
                if embolden != Vec2::ZERO {
                    b = b.font_embolden(glifo::FontEmbolden::new(Diagonal2::new(embolden.x, embolden.y)));
                }
                let _ = b.fill_glyphs(glyphs);
            }
            StyleRef::Stroke(stroke) => {
                self.ctx.set_stroke(stroke.clone());
                let _ = self
                    .ctx
                    .glyph_run(self.res, font)
                    .font_size(font_size)
                    .hint(hint)
                    .normalized_coords(normalized_coords)
                    .glyph_transform(glyph_transform.unwrap_or_default())
                    .stroke_glyphs(glyphs);
            }
        }
    }

    fn draw_box_shadow(&mut self, transform: Affine, rect: Rect, color: Color, radius: f64, std_dev: f64) {
        self.ctx.set_transform(transform);
        self.ctx.set_paint(PaintType::Solid(color));
        self.ctx.reset_paint_transform();
        self.ctx.fill_blurred_rounded_rect(&rect, radius as f32, std_dev as f32, false);
    }
}
