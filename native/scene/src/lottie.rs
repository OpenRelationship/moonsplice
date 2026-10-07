//! `s:lottie` through velato: the animation is drawn into the frame's own scene as vectors.
//!
//! velato walks a Lottie composition at a frame and calls a `RenderSink`; this sink records
//! those calls into the `anyrender::Scene` the rest of the stream is recorded into. So a Lottie
//! is painted by the same rasterizer as everything else (one antialiaser, in the goldens), is
//! seekable to any frame, and needs no second renderer (ThorVG went with LÖVE).

use anyrender::{PaintScene, Scene};
use velato::model::{fixed, ImageAsset};
use velato::{Composition, RenderSink, Renderer};
use vello_cpu::kurbo::{Affine, Shape};
use vello_cpu::peniko::{BlendMode, BrushRef, Fill};

struct Sink<'a>(&'a mut Scene);

impl RenderSink for Sink<'_> {
    fn push_layer(&mut self, blend: impl Into<BlendMode>, alpha: f32, transform: Affine, shape: &impl Shape) {
        self.0.push_layer(blend, alpha, transform, shape, None, None);
    }

    fn push_clip_layer(&mut self, transform: Affine, shape: &impl Shape) {
        self.0.push_clip_layer(transform, shape);
    }

    fn pop_layer(&mut self) {
        self.0.pop_layer();
    }

    fn draw(&mut self, stroke: Option<&fixed::Stroke>, transform: Affine, brush: &fixed::Brush, shape: &impl Shape) {
        match stroke {
            Some(s) => self.0.stroke(s, transform, BrushRef::from(brush), None, shape),
            None => self.0.fill(Fill::NonZero, transform, BrushRef::from(brush), None, shape),
        }
    }

    // Image layers inside a Lottie are not drawn yet; the eval suite and the skill's examples
    // are vector-only. Say so rather than guess at asset paths.
    fn draw_image(&mut self, _image: &ImageAsset, _transform: Affine, _alpha: f64) {}
}

/// Parse a Lottie, upgrading the pre-5.5 keyframe shape velato does not read: there a keyframe
/// carries its end value in `e` and the last one is a bare `{"t": n}`. lottie-web fills each
/// missing start from the previous keyframe's end; so does this.
pub fn load(bytes: &[u8]) -> Result<Composition, String> {
    let mut v: serde_json::Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    upgrade(&mut v);
    Composition::from_json(v).map_err(|e| e.to_string())
}

fn upgrade(v: &mut serde_json::Value) {
    use serde_json::Value;
    match v {
        Value::Array(items) => {
            let keyframes = items.iter().any(|k| k.get("t").is_some() && (k.get("s").is_some() || k.get("e").is_some()));
            if keyframes {
                let mut prev_end: Option<Value> = None;
                for k in items.iter_mut() {
                    if let Value::Object(o) = k {
                        if !o.contains_key("s") {
                            if let Some(e) = prev_end.clone() { o.insert("s".into(), e); }
                        }
                        prev_end = o.get("e").cloned().or_else(|| o.get("s").cloned());
                    }
                }
            }
            items.iter_mut().for_each(upgrade);
        }
        Value::Object(o) => o.values_mut().for_each(upgrade),
        _ => {}
    }
}

/// Frame range and rate, as velato reads them: frames [start, end) at `rate` per second.
pub fn info(c: &Composition) -> [f32; 5] {
    [c.frames.start as f32, c.frames.end as f32, c.frame_rate as f32, c.width as f32, c.height as f32]
}

/// Draw `c` at Lottie frame `frame`, its own (width x height) box mapped by `transform`.
pub fn draw(scene: &mut Scene, c: &Composition, frame: f64, transform: Affine, alpha: f64) {
    Renderer::new().append(c, frame, transform, alpha, &mut Sink(scene));
}
