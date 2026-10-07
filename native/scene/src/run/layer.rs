//! Opcodes that push a layer onto the current frame (clips 104 and 113, blends 107, filters 108,
//! opacity 110), and 105, which pops one or closes a scratch frame.

use std::sync::Arc;

use anyrender::filters::FilterEffect;
use anyrender::{Filter, PaintScene};
use vello_cpu::kurbo::{Affine, Rect, RoundedRect, Shape};
use vello_cpu::peniko::{BlendMode, Compose, Mix};

use super::Run;
use crate::everything;
use crate::text::hole_winds_like;

impl Run<'_> {
    pub(super) fn layer(&mut self, op: u32, cur: Affine) -> Option<()> {
        match op {
            104 => {
                self.layers.push(false);
                let [x, y, rw, rh, rx] = self.rd.take::<5>()?;
                let r = Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64);
                let sc = &mut self.frames.last_mut()?.scene;
                if rx > 0.0 { sc.push_clip_layer(cur, &RoundedRect::from_rect(r, rx as f64)); } else { sc.push_clip_layer(cur, &r); }
            }
            113 => {
                // clip to everything but the box: the frame with the box cut out of it, the hole
                // wound the other way so the nonzero rule leaves it empty
                self.layers.push(false);
                let [x, y, rw, rh, rx] = self.rd.take::<5>()?;
                let r = Rect::new(x as f64, y as f64, (x + rw) as f64, (y + rh) as f64);
                let hole = if rx > 0.0 { RoundedRect::from_rect(r, rx as f64).to_path(0.1) } else { r.to_path(0.1) };
                let inv = cur.inverse();
                let mut p = (inv * Rect::new(-1.0e6, -1.0e6, 1.0e6, 1.0e6).to_path(0.1)).reverse_subpaths();
                if hole_winds_like(&hole, &p) { p = p.reverse_subpaths(); }
                p.extend(hole);
                self.frames.last_mut()?.scene.push_clip_layer(cur, &p);
            }
            107 => {
                self.layers.push(false);
                let [mix, compose] = self.rd.take::<2>()?;
                let mix = match mix as u32 {
                    1 => Mix::Multiply, 2 => Mix::Screen, 3 => Mix::Overlay, 4 => Mix::Darken, 5 => Mix::Lighten,
                    6 => Mix::ColorDodge, 7 => Mix::ColorBurn, 8 => Mix::HardLight, 9 => Mix::SoftLight,
                    10 => Mix::Difference, 11 => Mix::Exclusion, 12 => Mix::Hue, 13 => Mix::Saturation,
                    14 => Mix::Color, 15 => Mix::Luminosity, _ => Mix::Normal,
                };
                let compose = match compose as u32 { 1 => Compose::Plus, _ => Compose::SrcOver };
                self.frames.last_mut()?.scene.push_layer(BlendMode::new(mix, compose), 1.0, Affine::IDENTITY, &everything(), None, None);
            }
            108 => {
                self.layers.push(false);
                let [kind, amount] = self.rd.take::<2>()?;
                let e = match kind as u32 {
                    // A radius is a length, so it is in scene units like every other length.
                    0 => FilterEffect::blur(amount * self.scale),
                    1 => FilterEffect::brightness(amount),
                    2 => FilterEffect::contrast(amount),
                    3 => FilterEffect::saturate(amount),
                    4 => FilterEffect::grayscale(amount),
                    5 => FilterEffect::sepia(amount),
                    6 => FilterEffect::invert(amount),
                    7 => FilterEffect::opacity(amount),
                    _ => FilterEffect::hue_rotate(amount.to_radians()),
                };
                self.frames.last_mut()?.scene.push_layer(Mix::Normal, 1.0, Affine::IDENTITY, &everything(),
                    Some(Arc::new(Filter::single(e))), None);
            }
            110 => {
                self.layers.push(false);
                let [a] = self.rd.take::<1>()?;
                self.frames.last_mut()?.scene.push_layer(Mix::Normal, a, Affine::IDENTITY, &everything(), None, None);
            }
            105 => {
                if self.layers.pop() == Some(true) {
                    self.close()?;
                } else {
                    self.frames.last_mut()?.scene.pop_layer();
                }
            }
            _ => return None,
        }
        Some(())
    }
}
