//! The `s:fx` chain on the CPU: the same maths as the GLSL passes in
//! `core/runtime/fx.lua`, run over a premultiplied RGBA8 scratch frame.
//! Pass kinds (opcode 112): 1 bloom, 2 glow, 3 blur, 4 vignette, 5 chroma,
//! 6 grain, 7 tonemap, 8 pixelate, 9 posterize, 10 filmgrain, 11 kawase, 12 worley.
//! shadertoy is the comp's own GLSL and runs on the GPU (.robot/docs/engine.robot, phase 3).

type Px = [f32; 4];

struct Buf {
    w: usize,
    h: usize,
    d: Vec<Px>,
}

impl Buf {
    fn new(w: usize, h: usize) -> Self { Buf { w, h, d: vec![[0.0; 4]; w * h] } }
    fn from_u8(px: &[u8], w: usize, h: usize) -> Self {
        let mut b = Buf::new(w, h);
        for (i, p) in b.d.iter_mut().enumerate() {
            for c in 0..4 { p[c] = px[i * 4 + c] as f32 / 255.0; }
        }
        b
    }
    fn to_u8(&self, px: &mut [u8]) {
        for (i, p) in self.d.iter().enumerate() {
            for c in 0..4 { px[i * 4 + c] = (p[c].clamp(0.0, 1.0) * 255.0 + 0.5) as u8; }
        }
    }
    #[inline]
    fn at(&self, x: i64, y: i64) -> Px {
        // clamp-to-edge, like a LÖVE canvas
        let x = x.clamp(0, self.w as i64 - 1) as usize;
        let y = y.clamp(0, self.h as i64 - 1) as usize;
        self.d[y * self.w + x]
    }
    /// bilinear sample at uv (texel centres at (i+0.5)/w), like `Texel(tex, uv)`
    fn uv(&self, u: f32, v: f32) -> Px {
        let fx = u * self.w as f32 - 0.5;
        let fy = v * self.h as f32 - 0.5;
        let x0 = fx.floor();
        let y0 = fy.floor();
        let tx = fx - x0;
        let ty = fy - y0;
        let (x0, y0) = (x0 as i64, y0 as i64);
        let a = self.at(x0, y0);
        let b = self.at(x0 + 1, y0);
        let c = self.at(x0, y0 + 1);
        let d = self.at(x0 + 1, y0 + 1);
        let mut o = [0.0; 4];
        for i in 0..4 {
            o[i] = (a[i] * (1.0 - tx) + b[i] * tx) * (1.0 - ty) + (c[i] * (1.0 - tx) + d[i] * tx) * ty;
        }
        o
    }
    fn map(&self, f: impl Fn(usize, usize, Px) -> Px + Sync) -> Buf {
        let mut o = Buf::new(self.w, self.h);
        for y in 0..self.h {
            for x in 0..self.w {
                o.d[y * self.w + x] = f(x, y, self.d[y * self.w + x]);
            }
        }
        o
    }
}

#[inline]
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
#[inline]
fn luma(p: Px) -> f32 { p[0] * 0.299 + p[1] * 0.587 + p[2] * 0.114 }
#[inline]
fn fract(x: f32) -> f32 { x - x.floor() }
#[inline]
fn mix(a: f32, b: f32, t: f32) -> f32 { a + (b - a) * t }

const BLUR_W: [f32; 9] = [0.0625, 0.0938, 0.1250, 0.1562, 0.1688, 0.1562, 0.1250, 0.0938, 0.0625];

/// 9-tap separable blur with taps `radius` px apart (core/runtime/fx.lua BLUR)
fn blur(src: &Buf, radius: f32) -> Buf {
    let tot: f32 = BLUR_W.iter().sum();
    let pass = |b: &Buf, dx: f32, dy: f32| -> Buf {
        b.map(|x, y, _| {
            let (u, v) = ((x as f32 + 0.5) / b.w as f32, (y as f32 + 0.5) / b.h as f32);
            let mut s = [0.0f32; 4];
            for (i, w) in BLUR_W.iter().enumerate() {
                let o = i as f32 - 4.0;
                let p = b.uv(u + dx * o, v + dy * o);
                for c in 0..4 { s[c] += p[c] * w; }
            }
            for c in 0..4 { s[c] /= tot; }
            s
        })
    };
    let ping = pass(src, radius / src.w as f32, 0.0);
    pass(&ping, 0.0, radius / src.h as f32)
}

fn bloom(src: &Buf, strength: f32) -> Buf {
    let bright = src.map(|_, _, c| {
        let k = smoothstep(0.35, 0.60, luma(c));
        [c[0] * k, c[1] * k, c[2] * k, c[3]]
    });
    let b = blur(&bright, 8.0);
    src.map(|x, y, c| {
        let g = b.d[y * b.w + x];
        [c[0] + g[0] * strength, c[1] + g[1] * strength, c[2] + g[2] * strength, c[3]]
    })
}

fn glow(src: &Buf, strength: f32) -> Buf {
    let b = blur(src, 10.0);
    src.map(|x, y, c| {
        let g = b.d[y * b.w + x];
        [c[0].max(g[0] * strength), c[1].max(g[1] * strength), c[2].max(g[2] * strength), c[3]]
    })
}

fn vignette(src: &Buf, opacity: f32) -> Buf {
    src.map(|x, y, c| {
        let (u, v) = ((x as f32 + 0.5) / src.w as f32 - 0.5, (y as f32 + 0.5) / src.h as f32 - 0.5);
        let d = (u * u + v * v).sqrt();
        let dark = smoothstep(0.55, 1.0, d * 1.45);
        let k = 1.0 - opacity * dark;
        [c[0] * k, c[1] * k, c[2] * k, c[3]]
    })
}

fn chroma(src: &Buf, amount: f32) -> Buf {
    src.map(|x, y, c| {
        let (u, v) = ((x as f32 + 0.5) / src.w as f32, (y as f32 + 0.5) / src.h as f32);
        let (dx, dy) = ((u - 0.5) * amount * 0.004, (v - 0.5) * amount * 0.004);
        let r = src.uv(u + dx, v + dy)[0];
        let b = src.uv(u - dx, v - dy)[2];
        [r, c[1], b, c[3]]
    })
}

fn noise(x: f32, y: f32, t: f32, rate: f32) -> f32 {
    let sx = x + 0.5 + t * rate;
    let sy = y + 0.5 + t * rate;
    fract((sx * 12.9898 + sy * 78.233).sin() * 43758.5453)
}

fn grain(src: &Buf, amount: f32, t: f32) -> Buf {
    src.map(|x, y, c| {
        let n = noise(x as f32, y as f32, t, 19.0) - 0.5;
        [c[0] + n * amount, c[1] + n * amount, c[2] + n * amount, c[3]]
    })
}

fn filmgrain(src: &Buf, amount: f32, t: f32) -> Buf {
    src.map(|x, y, c| {
        let n = (noise(x as f32, y as f32, t, 13.0) - 0.5) * amount * (0.55 + 0.45 * luma(c));
        [c[0] + n, c[1] + n, c[2] + n, c[3]]
    })
}

fn aces(x: f32) -> f32 {
    let (a, b, c, d, e) = (2.51, 0.03, 2.43, 0.59, 0.14);
    ((x * (a * x + b)) / (x * (c * x + d) + e)).clamp(0.0, 1.0)
}

fn tonemap(src: &Buf, amount: f32) -> Buf {
    src.map(|_, _, c| [
        mix(c[0], aces(c[0] * 1.12), amount),
        mix(c[1], aces(c[1] * 1.12), amount),
        mix(c[2], aces(c[2] * 1.12), amount),
        c[3],
    ])
}

fn pixelate(src: &Buf, amount: f32) -> Buf {
    let n = mix(1.0, 48.0, amount);
    src.map(|x, y, _| {
        let (u, v) = ((x as f32 + 0.5) / src.w as f32, (y as f32 + 0.5) / src.h as f32);
        let (cu, cv) = (n / src.w as f32, n / src.h as f32);
        src.uv((u / cu).floor() * cu + cu * 0.5, (v / cv).floor() * cv + cv * 0.5)
    })
}

fn posterize(src: &Buf, amount: f32) -> Buf {
    let levels = mix(12.0, 3.0, amount);
    src.map(|_, _, c| [
        (c[0] * levels + 0.5).floor() / levels,
        (c[1] * levels + 0.5).floor() / levels,
        (c[2] * levels + 0.5).floor() / levels,
        c[3],
    ])
}

fn kawase(src: &Buf, iters: f32) -> Buf {
    let iters = (iters + 0.5).floor().clamp(1.0, 4.0) as usize;
    let (hw, hh) = ((src.w / 2).max(1), (src.h / 2).max(1));
    let mut cur = Buf { w: src.w, h: src.h, d: src.d.clone() };
    for i in 1..=iters {
        let (px, py) = ((0.5 + (i - 1) as f32) / src.w as f32, (0.5 + (i - 1) as f32) / src.h as f32);
        let lo = Buf::new(hw, hh).map(|x, y, _| {
            let (u, v) = ((x as f32 + 0.5) / hw as f32, (y as f32 + 0.5) / hh as f32);
            let mut s = cur.uv(u, v);
            for c in 0..4 { s[c] *= 4.0; }
            for (ox, oy) in [(-px, -py), (px, -py), (-px, py), (px, py)] {
                let p = cur.uv(u + ox, v + oy);
                for c in 0..4 { s[c] += p[c]; }
            }
            for c in 0..4 { s[c] /= 8.0; }
            s
        });
        let (ox, oy) = (px * 0.5, py * 0.5);
        cur = Buf::new(src.w, src.h).map(|x, y, _| {
            let (u, v) = ((x as f32 + 0.5) / src.w as f32, (y as f32 + 0.5) / src.h as f32);
            let taps: [(f32, f32, f32); 8] = [
                (-ox * 2.0, 0.0, 1.0), (-ox, -oy, 2.0), (0.0, -oy * 2.0, 1.0), (ox, -oy, 2.0),
                (ox * 2.0, 0.0, 1.0), (ox, oy, 2.0), (0.0, oy * 2.0, 1.0), (-ox, oy, 2.0),
            ];
            let mut s = [0.0f32; 4];
            for (tx, ty, w) in taps {
                let p = lo.uv(u + tx, v + ty);
                for c in 0..4 { s[c] += p[c] * w; }
            }
            for c in 0..4 { s[c] /= 12.0; }
            s
        });
    }
    cur
}

/// lygia's worley at `uv`, as the GLSL pass computed it.
fn worley_at(u: f32, v: f32, t: f32) -> f32 {
    let (px, py) = (u * 6.0, v * 6.0);
    let (ix, iy) = (px.floor(), py.floor());
    let (fx, fy) = (px - ix, py - iy);
    let mut d = 1.0f32;
    for y in -1..=1 {
        for x in -1..=1 {
            let (gx, gy) = (x as f32, y as f32);
            let (cx, cy) = (ix + gx, iy + gy);
            let ox = fract(((cx * 127.1 + cy * 311.7) + t).sin() * 43758.5453);
            let oy = fract(((cx * 269.5 + cy * 183.3) + t * 1.3).sin() * 43758.5453);
            let (rx, ry) = (gx + ox - fx, gy + oy - fy);
            d = d.min(rx * rx + ry * ry);
        }
    }
    d.sqrt()
}

fn worley(src: &Buf, amount: f32, t: f32) -> Buf {
    src.map(|x, y, c| {
        let (u, v) = ((x as f32 + 0.5) / src.w as f32, (y as f32 + 0.5) / src.h as f32);
        let k = 0.85 + worley_at(u + t * 0.03, v, t);
        [mix(c[0], c[0] * k, amount), mix(c[1], c[1] * k, amount), mix(c[2], c[2] * k, amount), c[3]]
    })
}

/// Run `passes` (kind, amount, extra) over a premultiplied RGBA8 frame in place.
pub fn run_chain(px: &mut [u8], w: usize, h: usize, passes: &[(u32, f32, f32)]) {
    if w == 0 || h == 0 || passes.is_empty() { return; }
    let mut cur = Buf::from_u8(px, w, h);
    for &(kind, amount, extra) in passes {
        cur = match kind {
            1 => bloom(&cur, amount),
            2 => glow(&cur, amount),
            3 => blur(&cur, amount),
            4 => vignette(&cur, amount),
            5 => chroma(&cur, amount),
            6 => grain(&cur, amount, extra),
            7 => tonemap(&cur, amount),
            8 => pixelate(&cur, amount),
            9 => posterize(&cur, amount),
            10 => filmgrain(&cur, amount, extra),
            11 => kawase(&cur, amount),
            12 => worley(&cur, amount, extra),
            _ => cur,
        };
    }
    cur.to_u8(px);
}
