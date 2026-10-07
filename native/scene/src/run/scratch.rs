//! Scratch frames: what is drawn until the 105 that closes one is painted on its own and worked on
//! before it is put back -- effects and shader chains (111, 112), perspective (114), displacement
//! (115) and track mattes (117, 118) -- and film grain over a region (106).

use std::sync::Arc;

use anyrender::{PaintScene, ResourceId, Scene};
use vello_cpu::kurbo::{Affine, Point, Rect};
use vello_cpu::peniko::{Extend, Fill, ImageBrush, ImageQuality, ImageSampler};
use vello_cpu::RenderContext;

use super::{Close, Frame, Fx, Pass, Run};
use crate::{displace, effects, paint_cpu, persp, premul_pixmap, set_error, settings};

impl Run<'_> {
    pub(super) fn scratch(&mut self, op: u32, cur: Affine) -> Option<()> {
        match op {
            106 => {
                let [amount, seed, x, y, rw, rh] = self.rd.take::<6>()?;
                let p0 = self.base * Point::new(x as f64, y as f64);
                let p1 = self.base * Point::new((x + rw) as f64, (y + rh) as f64);
                self.grains.push((amount, seed as u32, p0.x.min(p1.x).max(0.0) as usize, p0.y.min(p1.y).max(0.0) as usize,
                    (p0.x.max(p1.x).min(self.w as f64)) as usize, (p0.y.max(p1.y).min(self.h as f64)) as usize));
            }
            111 | 112 => {
                let (fxp, [bx, by, bw, bh]) = if op as u32 == 111 {
                    let mut p = self.rd.take::<9>()?;
                    p[0] *= self.scale; // blur radius, in pixels of the frame being drawn
                    (Fx::Effects(p), self.rd.take::<4>()?)
                } else {
                    let [n, bx, by, bw, bh] = self.rd.take::<5>()?;
                    let mut passes = Vec::with_capacity(n as usize);
                    for _ in 0..(n as usize) {
                        let [k, a, e, x] = self.rd.take::<4>()?;
                        passes.push(match k as u32 {
                            // the comp's GLSL: a = string offset, e = length, x = t
                            13 => Pass::Shader(self.sref(a, e)?.to_string(), x),
                            // kind 0 is blur in the chain too, and its amount is a radius.
                            k => Pass::Cpu(k, if k == 0 { a * self.scale } else { a }, e),
                        });
                    }
                    (Fx::Chain(passes), [bx, by, bw, bh])
                };
                // frame-space bbox of the node box under the current affine
                let corners = [
                    self.base * Point::new(bx as f64, by as f64),
                    self.base * Point::new((bx + bw) as f64, by as f64),
                    self.base * Point::new(bx as f64, (by + bh) as f64),
                    self.base * Point::new((bx + bw) as f64, (by + bh) as f64),
                ];
                let (mut x0, mut y0, mut x1, mut y1) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
                for c in corners { x0 = x0.min(c.x); y0 = y0.min(c.y); x1 = x1.max(c.x); y1 = y1.max(c.y); }
                let ox = x0.floor() as i32;
                let oy = y0.floor() as i32;
                let sw = ((x1.ceil() as i32) - ox).clamp(1, 16384) as u16;
                let sh = ((y1.ceil() as i32) - oy).clamp(1, 16384) as u16;
                self.frames.push(Frame {
                    scene: Scene::new(),
                    off: Affine::translate((-ox as f64, -oy as f64)),
                    fx: Some(Close::Fx(fxp, (ox, oy, sw, sh))),
                });
                self.layers.push(true);
            }
            114 => {
                let [ox, oy, pw, ph, sw, sh] = self.rd.take::<6>()?;
                let hi = self.rd.take::<9>()?;
                let [r20, r21, dz, focus_w, aperture, maxcoc] = self.rd.take::<6>()?;
                let size = |v: f32| v.ceil().clamp(1.0, 16384.0) as u16;
                let cam = persp::Camera { hi, r20, r21, dz, focus_w, aperture, maxcoc };
                // The stage is the box the page projects into; the authored margin
                // (sw x sh, centred) only when part of the page is behind the camera.
                let [x0, y0, x1, y1] = cam.stage_box(pw, ph).unwrap_or([-sw / 2.0, -sh / 2.0, sw / 2.0, sh / 2.0]);
                let (x0, y0) = (x0.floor(), y0.floor());
                let (pw_, ph_, sw_, sh_) = (size(pw), size(ph), size(x1 - x0), size(y1 - y0));
                // stage coordinates are relative to the page's centre in node space
                let place = cur * Affine::translate(((ox + pw / 2.0 + x0) as f64, (oy + ph / 2.0 + y0) as f64));
                self.frames.push(Frame {
                    scene: Scene::new(),
                    // node space (ox, oy) is the page's origin, at page pixels
                    off: Affine::translate((-ox as f64, -oy as f64)) * self.base.inverse(),
                    fx: Some(Close::Persp(cam, (pw_, ph_, sw_, sh_), (x0, y0), place)),
                });
                self.layers.push(true);
            }
            115 => {
                let [ox, oy, pw, ph, cols, rows, t, amp, freq] = self.rd.take::<9>()?;
                let size = |v: f32| v.ceil().clamp(1.0, 16384.0) as u16;
                let grid = displace::Grid { cols: cols.max(1.0) as usize, rows: rows.max(1.0) as usize, t, amp, freq };
                let m = grid.reach().ceil();
                let (x0, y0) = (-m, -m);
                let (pw_, ph_, sw_, sh_) = (size(pw), size(ph), size(pw + 2.0 * m), size(ph + 2.0 * m));
                self.frames.push(Frame {
                    scene: Scene::new(),
                    off: Affine::translate((-ox as f64, -oy as f64)) * self.base.inverse(),
                    fx: Some(Close::Displace(grid, (pw_, ph_, sw_, sh_), (x0, y0),
                        cur * Affine::translate(((ox + x0) as f64, (oy + y0) as f64)))),
                });
                self.layers.push(true);
            }
            117 => {
                // the matte draws into the parent's pixel space, the size of the output
                let [mode] = self.rd.take::<1>()?;
                let off = self.frames.last()?.off;
                self.frames.push(Frame { scene: Scene::new(), off, fx: Some(Close::MatteSource(mode as u32)) });
            }
            118 => {
                let fr = self.frames.pop()?;
                let Some(Close::MatteSource(mode)) = fr.fx else { return None };
                let mut sub = RenderContext::new_with(self.w, self.h, settings(self.threads));
                let mask = paint_cpu(&mut sub, &mut self.st.res, &self.st.ids, fr.scene);
                self.frames.push(Frame { scene: Scene::new(), off: fr.off, fx: Some(Close::Matte(mask, mode)) });
                self.layers.push(true);
            }
            _ => return None,
        }
        Some(())
    }

    /// A 105 that closes a scratch frame.
    pub(super) fn close(&mut self) -> Option<()> {
        // close the scratch frame: render, run the effect chain, composite
        let fr = self.frames.pop()?;
        let (pm, place, (ox, oy, sw, sh)) = match fr.fx? {
            Close::Fx(fx, (ox, oy, sw, sh)) => {
                let mut sub = RenderContext::new_with(sw, sh, settings(self.threads));
                let mut pm = paint_cpu(&mut sub, &mut self.st.res, &self.st.ids, fr.scene);
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
                (pm, self.frames.last()?.off, (ox, oy, sw, sh))
            }
            Close::Persp(cam, (pw, ph, sw, sh), (x0, y0), place) => {
                let mut sub = RenderContext::new_with(pw, ph, settings(self.threads));
                let page = paint_cpu(&mut sub, &mut self.st.res, &self.st.ids, fr.scene);
                let stage = persp::warp(page.data_as_u8_slice(), pw as usize, ph as usize, sw as usize, sh as usize, x0, y0, &cam);
                (premul_pixmap(stage, sw, sh), place, (0, 0, sw, sh))
            }
            Close::Displace(grid, (pw, ph, sw, sh), (x0, y0), place) => {
                let mut sub = RenderContext::new_with(pw, ph, settings(self.threads));
                let page = paint_cpu(&mut sub, &mut self.st.res, &self.st.ids, fr.scene);
                let stage = displace::warp(page.data_as_u8_slice(), pw as usize, ph as usize, sw as usize, sh as usize, x0, y0, &grid);
                (premul_pixmap(stage, sw, sh), place, (0, 0, sw, sh))
            }
            Close::Matte(mask, mode) => {
                // the layer, in the parent's pixels, times the matte, put back in place
                let mut sub = RenderContext::new_with(self.w, self.h, settings(self.threads));
                let layer = paint_cpu(&mut sub, &mut self.st.res, &self.st.ids, fr.scene);
                let mut px = layer.data_as_u8_slice().to_vec();
                apply_matte(&mut px, mask.data_as_u8_slice(), mode);
                (premul_pixmap(px, self.w, self.h), Affine::IDENTITY, (0, 0, self.w, self.h))
            }
            // a 105 never closes a matte's source: 118 does
            Close::MatteSource(_) => return None,
        };
        let rid = ResourceId::new();
        self.st.ids.insert(rid, self.st.res.register_image(Arc::new(pm)));
        self.temp.push(rid);
        let parent = self.frames.last_mut()?;
        parent.scene.fill(Fill::NonZero, place,
            anyrender::Paint::Resource(ImageBrush {
                image: rid,
                sampler: ImageSampler { x_extend: Extend::Pad, y_extend: Extend::Pad, quality: ImageQuality::Low, alpha: 1.0 },
            }),
            Some(Affine::translate((ox as f64, oy as f64))),
            &Rect::new(ox as f64, oy as f64, (ox + sw as i32) as f64, (oy + sh as i32) as f64));
        Some(())
    }
}

/// A chain over a premultiplied frame: runs of CPU passes together (one conversion each way),
/// shader passes on the GPU between them.
fn run_passes(px: &mut [u8], w: usize, h: usize, passes: &[Pass]) -> Result<(), String> {
    let mut cpu: Vec<(u32, f32, f32)> = Vec::new();
    for p in passes {
        match p {
            Pass::Cpu(k, a, e) => cpu.push((*k, *a, *e)),
            Pass::Shader(src, t) => {
                crate::fx::run_chain(px, w, h, &cpu);
                cpu.clear();
                shader(src, px, w, h, *t)?;
            }
        }
    }
    crate::fx::run_chain(px, w, h, &cpu);
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

/// A track matte on a premultiplied layer: every channel times the matte's alpha or luma (the
/// matte over black, as a track matte reads it), inverted for modes 1 and 3.
fn apply_matte(px: &mut [u8], mask: &[u8], mode: u32) {
    for (p, m) in px.chunks_exact_mut(4).zip(mask.chunks_exact(4)) {
        let k = match mode {
            0 | 1 => m[3] as u32,
            // BT.709 weights in 256ths: 54 + 183 + 19 = 256, so white is 255
            _ => (m[0] as u32 * 54 + m[1] as u32 * 183 + m[2] as u32 * 19 + 128) >> 8,
        };
        let k = if mode == 1 || mode == 3 { 255 - k } else { k };
        for c in p.iter_mut() {
            *c = ((*c as u32 * k + 127) / 255) as u8;
        }
    }
}
