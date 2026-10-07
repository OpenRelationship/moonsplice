//! A perspective plane on the CPU: flat page pixels warped through a camera, with thin-lens
//! defocus. The plane is flat, so the camera collapses to a 3x3 homography, and running it
//! backwards (stage pixel -> page pixel) is exact perspective at any angle that also hands over
//! the camera-space depth of every pixel -- which is what the defocus is computed from. The
//! maths is `core/runtime/persp.lua`'s former GLSL, pixel for pixel; the camera itself is computed in
//! Lua (`P.params`) and arrives as numbers.

pub struct Camera {
    /// inverse homography rows: stage (centred) -> page
    pub hi: [f32; 9],
    pub r20: f32,
    pub r21: f32,
    pub dz: f32,
    pub focus_w: f32,
    pub aperture: f32,
    pub maxcoc: f32,
}

struct Page<'a> {
    px: &'a [u8],
    w: usize,
    h: usize,
}

impl Page<'_> {
    #[inline]
    fn at(&self, x: i64, y: i64) -> [f32; 4] {
        let x = x.clamp(0, self.w as i64 - 1) as usize;
        let y = y.clamp(0, self.h as i64 - 1) as usize;
        let i = (y * self.w + x) * 4;
        [self.px[i] as f32, self.px[i + 1] as f32, self.px[i + 2] as f32, self.px[i + 3] as f32]
    }
    /// bilinear at uv in [0,1], texel centres at (i+0.5)/w, clamped at the edges
    fn uv(&self, u: f32, v: f32) -> [f32; 4] {
        let fx = u * self.w as f32 - 0.5;
        let fy = v * self.h as f32 - 0.5;
        let (x0, y0) = (fx.floor(), fy.floor());
        let (tx, ty) = (fx - x0, fy - y0);
        let (x0, y0) = (x0 as i64, y0 as i64);
        let (a, b, c, d) = (self.at(x0, y0), self.at(x0 + 1, y0), self.at(x0, y0 + 1), self.at(x0 + 1, y0 + 1));
        let mut o = [0.0; 4];
        for i in 0..4 {
            o[i] = (a[i] * (1.0 - tx) + b[i] * tx) * (1.0 - ty) + (c[i] * (1.0 - tx) + d[i] * tx) * ty;
        }
        o
    }
}

impl Camera {
    /// Where the page lands, as a box in stage coordinates (relative to the page's centre),
    /// padded by the widest blur: the stage is sized to the picture rather than to a guess, so
    /// a card brought close to the lens is never cut off by its own canvas. None when part of
    /// the page is behind the camera.
    pub fn stage_box(&self, pw: f32, ph: f32) -> Option<[f32; 4]> {
        let h = inv3(self.hi)?;
        let (mut x0, mut y0, mut x1, mut y1) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
        for (u, v) in [(-pw / 2.0, -ph / 2.0), (pw / 2.0, -ph / 2.0), (-pw / 2.0, ph / 2.0), (pw / 2.0, ph / 2.0)] {
            let z = h[6] * u + h[7] * v + h[8];
            if z <= 1e-6 {
                return None;
            }
            let (x, y) = ((h[0] * u + h[1] * v + h[2]) / z, (h[3] * u + h[4] * v + h[5]) / z);
            x0 = x0.min(x); y0 = y0.min(y); x1 = x1.max(x); y1 = y1.max(y);
        }
        let pad = self.maxcoc.max(0.0) + 2.0;
        // a page seen nearly edge-on projects enormous; past this it is off the frame anyway
        let lim = 8.0 * pw.max(ph);
        Some([(x0 - pad).max(-lim), (y0 - pad).max(-lim), (x1 + pad).min(lim), (y1 + pad).min(lim)])
    }

    /// stage pixel centre -> page uv in [0,1] and camera-space depth, or None off the page.
    /// (x0, y0) is where the stage's top-left sits relative to the page centre.
    #[inline]
    fn project(&self, x: f32, y: f32, x0: f32, y0: f32, pw: f32, ph: f32) -> Option<(f32, f32, f32)> {
        let (sx, sy) = (x + x0, y + y0);
        let h = &self.hi;
        let pz = h[6] * sx + h[7] * sy + h[8];
        if pz.abs() < 1e-7 {
            return None;
        }
        let u = (h[0] * sx + h[1] * sy + h[2]) / pz;
        let v = (h[3] * sx + h[4] * sy + h[5]) / pz;
        let w = u * self.r20 + v * self.r21 + self.dz;
        if w <= 0.0001 {
            return None; // behind the camera
        }
        let (u01, v01) = (u / pw + 0.5, v / ph + 0.5);
        ((0.0..=1.0).contains(&u01) && (0.0..=1.0).contains(&v01)).then_some((u01, v01, w))
    }
}

fn inv3(m: [f32; 9]) -> Option<[f32; 9]> {
    let [a, b, c, d, e, f, g, h, i] = m.map(|v| v as f64);
    let (ca, cb, cc) = (e * i - f * h, -(d * i - f * g), d * h - e * g);
    let det = a * ca + b * cb + c * cc;
    if det.abs() < 1e-12 {
        return None;
    }
    let id = 1.0 / det;
    Some([
        ca * id, -(b * i - c * h) * id, (b * f - c * e) * id,
        cb * id, (a * i - c * g) * id, -(a * f - c * d) * id,
        cc * id, -(a * h - b * g) * id, (a * e - b * d) * id,
    ].map(|v| v as f32))
}

/// Warp a premultiplied page (pw x ph) onto a stage (sw x sh) whose top-left is at (x0, y0)
/// relative to the page centre; premultiplied out. Rows are independent, so they are split
/// across threads: the result does not depend on how many.
pub fn warp(page: &[u8], pw: usize, ph: usize, sw: usize, sh: usize, x0: f32, y0: f32, cam: &Camera) -> Vec<u8> {
    let mut out = vec![0u8; sw * sh * 4];
    if sw == 0 || sh == 0 {
        return out;
    }
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).min(16);
    if threads <= 1 {
        // one thread, or none to spawn (wasm32)
        warp_rows(page, pw, ph, sw, 0, &mut out, x0, y0, cam);
        return out;
    }
    let rows_per = sh.div_ceil(threads).max(1);
    std::thread::scope(|s| {
        for (k, band) in out.chunks_mut(rows_per * sw * 4).enumerate() {
            s.spawn(move || warp_rows(page, pw, ph, sw, k * rows_per, band, x0, y0, cam));
        }
    });
    out
}

#[allow(clippy::too_many_arguments)]
fn warp_rows(page: &[u8], pw: usize, ph: usize, sw: usize, first: usize, band: &mut [u8], x0: f32, y0: f32, cam: &Camera) {
    let src = Page { px: page, w: pw, h: ph };
    let (pwf, phf) = (pw as f32, ph as f32);
    let put = |o: &mut [u8], c: [f32; 4]| {
        for k in 0..4 {
            o[k] = (c[k] + 0.5).clamp(0.0, 255.0) as u8;
        }
    };
    for (r, row) in band.chunks_exact_mut(sw * 4).enumerate() {
        let y = first + r;
        for x in 0..sw {
            let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
            let Some((u0, v0, w0)) = cam.project(px, py, x0, y0, pwf, phf) else { continue };
            let o = &mut row[x * 4..x * 4 + 4];
            let coc = (cam.aperture * (w0 - cam.focus_w).abs() / cam.focus_w.max(1e-4)).clamp(0.0, cam.maxcoc);
            if coc < 0.75 {
                put(o, src.uv(u0, v0));
                continue;
            }
            // golden-angle spiral: even coverage, no visible tap pattern
            let (mut acc, mut n) = ([0.0f32; 4], 0.0f32);
            for i in 0..20 {
                let t = (i as f32 + 0.5) / 20.0;
                let ang = i as f32 * 2.399963;
                let r = t.sqrt() * coc;
                if let Some((u, v, _)) = cam.project(px + ang.cos() * r, py + ang.sin() * r, x0, y0, pwf, phf) {
                    let c = src.uv(u, v);
                    for k in 0..4 {
                        acc[k] += c[k];
                    }
                    n += 1.0;
                }
            }
            if n < 0.5 {
                put(o, src.uv(u0, v0));
            } else {
                put(o, [acc[0] / n, acc[1] / n, acc[2] / n, acc[3] / n]);
            }
        }
    }
}
