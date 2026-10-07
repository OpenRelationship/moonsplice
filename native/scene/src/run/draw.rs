//! Opcodes that draw into the current frame: paths and fills (0-10), the transform (100), text
//! (101), the background (102), images (103) and Lottie (116).

use anyrender::PaintScene;
use vello_cpu::color::DynamicColor;
use vello_cpu::kurbo::{Affine, BezPath, Circle, Point, Rect, RoundedRect, Stroke};
use vello_cpu::peniko::{ColorStop, Extend, Fill, Gradient, ImageBrush, ImageQuality, ImageSampler, Mix};

use super::Run;
use crate::lottie;
use crate::state::color;
use crate::text::{build_layout, draw_text, TextRun, TextSpec};
use crate::everything;

impl Run<'_> {
    pub(super) fn draw(&mut self, op: u32, off: Affine, cur: Affine) -> Option<()> {
        match op {
            0 => {
                let [x, y, rw, rh, r, g, b, a] = self.rd.take::<8>()?;
                self.frames.last_mut()?.scene.fill(Fill::NonZero, cur, color(r, g, b, a), None,
                    &Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64));
            }
            1 => {
                let [x, y, rw, rh, rad, r, g, b, a] = self.rd.take::<9>()?;
                let rr = RoundedRect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64, rad as f64);
                self.frames.last_mut()?.scene.fill(Fill::NonZero, cur, color(r, g, b, a), None, &rr);
            }
            2 => {
                let [cx, cy, rad, r, g, b, a] = self.rd.take::<7>()?;
                self.frames.last_mut()?.scene.fill(Fill::NonZero, cur, color(r, g, b, a), None,
                    &Circle::new(Point::new(cx as f64, cy as f64), rad as f64));
            }
            3 => {
                let [x, y] = self.rd.take::<2>()?;
                self.path.move_to(Point::new(x as f64, y as f64));
            }
            4 => {
                let [x, y] = self.rd.take::<2>()?;
                self.path.line_to(Point::new(x as f64, y as f64));
            }
            5 => {
                let [x1, y1, x2, y2, x, y] = self.rd.take::<6>()?;
                self.path.curve_to(Point::new(x1 as f64, y1 as f64), Point::new(x2 as f64, y2 as f64), Point::new(x as f64, y as f64));
            }
            6 => {
                let [r, g, b, a] = self.rd.take::<4>()?;
                self.path.close_path();
                self.frames.last_mut()?.scene.fill(Fill::NonZero, cur, color(r, g, b, a), None, &self.path);
                self.path = BezPath::new();
            }
            7 => {
                let [width, r, g, b, a] = self.rd.take::<5>()?;
                self.frames.last_mut()?.scene.stroke(&Stroke::new(width as f64), cur, color(r, g, b, a), None, &self.path);
                self.path = BezPath::new();
            }
            8 => {
                let [x, y, rw, rh, x0, y0, x1, y1] = self.rd.take::<8>()?;
                let [r0, g0, b0, a0, r1, g1, b1, a1] = self.rd.take::<8>()?;
                let grad = Gradient::new_linear(Point::new(x0 as f64, y0 as f64), Point::new(x1 as f64, y1 as f64)).with_stops([
                    ColorStop { offset: 0.0, color: DynamicColor::from_alpha_color(color(r0, g0, b0, a0)) },
                    ColorStop { offset: 1.0, color: DynamicColor::from_alpha_color(color(r1, g1, b1, a1)) },
                ]);
                self.frames.last_mut()?.scene.fill(Fill::NonZero, cur, &grad, None,
                    &Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64));
            }
            9 => {
                let [cx, cy, rad] = self.rd.take::<3>()?;
                let [r0, g0, b0, a0, r1, g1, b1, a1] = self.rd.take::<8>()?;
                let grad = Gradient::new_radial(Point::new(cx as f64, cy as f64), rad).with_stops([
                    ColorStop { offset: 0.0, color: DynamicColor::from_alpha_color(color(r0, g0, b0, a0)) },
                    ColorStop { offset: 1.0, color: DynamicColor::from_alpha_color(color(r1, g1, b1, a1)) },
                ]);
                self.frames.last_mut()?.scene.fill(Fill::NonZero, cur, &grad, None,
                    &Rect::new((cx - rad) as f64, (cy - rad) as f64, (cx + rad) as f64, (cy + rad) as f64));
            }
            10 => {
                let [amount, seed] = self.rd.take::<2>()?;
                self.grain = Some((amount, seed as u32));
            }
            100 => {
                let [a, b, c, d, e, f] = self.rd.take::<6>()?;
                self.base = self.root * Affine::new([a as f64, b as f64, c as f64, d as f64, e as f64, f as f64]);
            }
            101 => {
                let [font, size, x, y, ls, wrap, leading, align, ow] = self.rd.take::<9>()?;
                let [or_, og, ob, oa, emb, nruns] = self.rd.take::<6>()?;
                let mut runs = Vec::with_capacity(nruns as usize);
                for _ in 0..nruns as usize {
                    let [off, len, r, g, b, a, bold, italic] = self.rd.take::<8>()?;
                    runs.push(TextRun { text: self.sref(off, len)?, color: [r, g, b, a], bold: bold > 0.5, italic: italic > 0.5 });
                }
                let spec = TextSpec { font: font as usize, size, ls, wrap, leading, align: align as i32, runs };
                build_layout(self.st, &spec);
                draw_text(self.st, &mut self.frames.last_mut()?.scene, cur, x, y, (ow, [or_, og, ob, oa]), emb);
            }
            102 => {
                let [r, g, b, a] = self.rd.take::<4>()?;
                self.frames.last_mut()?.scene.fill(Fill::NonZero, off, color(r, g, b, a), None, &Rect::new(0.0, 0.0, self.w as f64, self.h as f64));
            }
            103 => {
                let [id, x, y, rw, rh, rx, alpha] = self.rd.take::<7>()?;
                let (rid, iw, ih) = *self.st.images.get(id as usize)?;
                let brush = anyrender::Paint::Resource(ImageBrush {
                    image: rid,
                    sampler: ImageSampler { x_extend: Extend::Pad, y_extend: Extend::Pad, quality: ImageQuality::Medium, alpha: 1.0 },
                });
                let sc = &mut self.frames.last_mut()?.scene;
                let layered = alpha < 0.999;
                if layered { sc.push_layer(Mix::Normal, alpha.max(0.0), Affine::IDENTITY, &everything(), None, None); }
                let bt = Affine::translate((x as f64, y as f64)) * Affine::scale_non_uniform(rw as f64 / iw as f64, rh as f64 / ih as f64);
                let r = Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64);
                if rx > 0.0 { sc.fill(Fill::NonZero, cur, brush, Some(bt), &RoundedRect::from_rect(r, rx as f64)); }
                else { sc.fill(Fill::NonZero, cur, brush, Some(bt), &r); }
                if layered { sc.pop_layer(); }
            }
            116 => {
                let [id, frame, x, y, rw, rh, alpha] = self.rd.take::<7>()?;
                let c = self.st.lotties.get(id as usize)?;
                let fit = Affine::translate((x as f64, y as f64))
                    * Affine::scale_non_uniform(rw as f64 / c.width.max(1) as f64, rh as f64 / c.height.max(1) as f64);
                lottie::draw(&mut self.frames.last_mut()?.scene, c, frame as f64, cur * fit, alpha as f64);
            }
            _ => return None,
        }
        Some(())
    }
}
