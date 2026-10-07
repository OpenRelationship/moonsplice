//! `s:displace` on the CPU: a page (image or type) as a grid mesh pushed around by f(t).
//!
//! What the GPU did, done the same way: the grid's vertices move by the former vertex shader's
//! formula, and each triangle is filled with the page under affine texture mapping. Pixel centres
//! are owned by exactly one triangle (top-left rule), so the grid has no seams; where a large
//! amplitude folds the mesh over itself, later triangles composite over earlier ones, as they did.

pub struct Grid {
    pub cols: usize,
    pub rows: usize,
    pub t: f32,
    pub amp: f32,
    pub freq: f32,
}

impl Grid {
    /// where page point (x, y) moves to -- the vertex shader, verbatim (x uses the moved y)
    fn moved(&self, x: f32, y: f32) -> (f32, f32) {
        let y2 = y + ((x * 0.031 + self.t * 2.4) * self.freq).sin() * self.amp;
        let x2 = x + ((y2 * 0.027 + self.t * 1.7) * self.freq).cos() * self.amp * 0.35;
        (x2, y2)
    }

    /// How far the mesh can reach outside the page, either way.
    pub fn reach(&self) -> f32 {
        self.amp.abs() + 2.0
    }
}

fn sample(px: &[u8], w: usize, h: usize, u: f32, v: f32) -> [f32; 4] {
    let fx = u * w as f32 - 0.5;
    let fy = v * h as f32 - 0.5;
    let (x0, y0) = (fx.floor(), fy.floor());
    let (tx, ty) = (fx - x0, fy - y0);
    let at = |x: i64, y: i64| {
        let x = x.clamp(0, w as i64 - 1) as usize;
        let y = y.clamp(0, h as i64 - 1) as usize;
        let i = (y * w + x) * 4;
        [px[i] as f32, px[i + 1] as f32, px[i + 2] as f32, px[i + 3] as f32]
    };
    let (x0, y0) = (x0 as i64, y0 as i64);
    let (a, b, c, d) = (at(x0, y0), at(x0 + 1, y0), at(x0, y0 + 1), at(x0 + 1, y0 + 1));
    let mut o = [0.0; 4];
    for k in 0..4 {
        o[k] = (a[k] * (1.0 - tx) + b[k] * tx) * (1.0 - ty) + (c[k] * (1.0 - tx) + d[k] * tx) * ty;
    }
    o
}

/// Warp a premultiplied page (pw x ph) onto a stage (sw x sh) whose top-left is page point
/// (x0, y0); premultiplied out.
pub fn warp(page: &[u8], pw: usize, ph: usize, sw: usize, sh: usize, x0: f32, y0: f32, g: &Grid) -> Vec<u8> {
    let mut out = vec![0f32; sw * sh * 4];
    let (cols, rows) = (g.cols.max(1), g.rows.max(1));
    // vertices, in stage coordinates, and their uvs
    let vert = |c: usize, r: usize| {
        let (x, y) = (c as f32 / cols as f32 * pw as f32, r as f32 / rows as f32 * ph as f32);
        let (mx, my) = g.moved(x, y);
        ((mx - x0, my - y0), (c as f32 / cols as f32, r as f32 / rows as f32))
    };
    let edge = |a: (f32, f32), b: (f32, f32), p: (f32, f32)| (b.0 - a.0) * (p.1 - a.1) - (b.1 - a.1) * (p.0 - a.0);
    let mut tri = |p: [((f32, f32), (f32, f32)); 3]| {
        let (mut a, mut b, c) = (p[0], p[1], p[2]);
        let mut area = edge(a.0, b.0, c.0);
        if area.abs() < 1e-9 {
            return;
        }
        if area < 0.0 {
            std::mem::swap(&mut a, &mut b);
            area = -area;
        }
        // top-left rule: an edge owns its pixels if it is a top edge or a left edge
        let owns = |s: (f32, f32), e: (f32, f32)| (s.1 == e.1 && e.0 < s.0) || e.1 > s.1;
        let bias = |s: (f32, f32), e: (f32, f32)| if owns(s, e) { 0.0 } else { -1e-6 };
        let (ba, bb, bc) = (bias(b.0, c.0), bias(c.0, a.0), bias(a.0, b.0));
        let xs = [a.0 .0, b.0 .0, c.0 .0];
        let ys = [a.0 .1, b.0 .1, c.0 .1];
        let lo_x = (xs.iter().cloned().fold(f32::MAX, f32::min).floor().max(0.0)) as usize;
        let hi_x = (xs.iter().cloned().fold(f32::MIN, f32::max).ceil().min(sw as f32)) as usize;
        let lo_y = (ys.iter().cloned().fold(f32::MAX, f32::min).floor().max(0.0)) as usize;
        let hi_y = (ys.iter().cloned().fold(f32::MIN, f32::max).ceil().min(sh as f32)) as usize;
        for y in lo_y..hi_y {
            for x in lo_x..hi_x {
                let p = (x as f32 + 0.5, y as f32 + 0.5);
                let (wa, wb, wc) = (edge(b.0, c.0, p), edge(c.0, a.0, p), edge(a.0, b.0, p));
                if wa + ba < 0.0 || wb + bb < 0.0 || wc + bc < 0.0 {
                    continue;
                }
                let (la, lb, lc) = (wa / area, wb / area, wc / area);
                let u = la * a.1 .0 + lb * b.1 .0 + lc * c.1 .0;
                let v = la * a.1 .1 + lb * b.1 .1 + lc * c.1 .1;
                let s = sample(page, pw, ph, u, v);
                let o = &mut out[(y * sw + x) * 4..(y * sw + x) * 4 + 4];
                let k = 1.0 - s[3] / 255.0;
                for i in 0..4 {
                    o[i] = s[i] + o[i] * k;
                }
            }
        }
    };
    // the same two triangles per cell, in the same order, as the mesh
    for r in 0..rows {
        for c in 0..cols {
            let (p00, p10, p11, p01) = (vert(c, r), vert(c + 1, r), vert(c + 1, r + 1), vert(c, r + 1));
            tri([p00, p10, p11]);
            tri([p00, p11, p01]);
        }
    }
    out.iter().map(|v| (v + 0.5).clamp(0.0, 255.0) as u8).collect()
}
