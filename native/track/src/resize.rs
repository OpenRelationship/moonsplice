//! Pillow's `Image.resize(..., BILINEAR)` for 8-bit RGB, reproduced exactly.
//!
//! EdgeTAM's processor (transformers `Sam2VideoVideoProcessor`) resizes with PIL, and the model is
//! sensitive to it: torch's bilinear interpolate lands 1.7e-2 away from PIL on normalized pixels,
//! which moved the frame-0 memory tokens by 2.8. This is PIL's `ImagingResample`: separable
//! triangle-filter convolution, horizontal pass first, 22-bit fixed-point coefficients, and the
//! intermediate image rounded and clipped to u8 between the passes.

const PRECISION_BITS: u32 = 32 - 8 - 2;

fn coeffs(in_size: usize, out_size: usize) -> (Vec<(usize, usize)>, Vec<i32>, usize) {
    let scale = in_size as f64 / out_size as f64;
    let filterscale = scale.max(1.0);
    let support = 1.0 * filterscale;
    let ksize = support.ceil() as usize * 2 + 1;
    let mut bounds = Vec::with_capacity(out_size);
    let mut kk = vec![0i32; out_size * ksize];
    for xx in 0..out_size {
        let center = (xx as f64 + 0.5) * scale;
        let ss = 1.0 / filterscale;
        let xmin = ((center - support + 0.5) as i64).max(0) as usize;
        let xmax = (((center + support + 0.5) as i64).min(in_size as i64) as usize) - xmin;
        let mut k = vec![0f64; xmax];
        let mut ww = 0.0;
        for (x, w) in k.iter_mut().enumerate() {
            let d = ((x + xmin) as f64 - center + 0.5) * ss;
            *w = (1.0 - d.abs()).max(0.0);
            ww += *w;
        }
        for (x, w) in k.iter().enumerate() {
            let v = if ww != 0.0 { w / ww } else { 0.0 };
            let f = v * (1i64 << PRECISION_BITS) as f64;
            kk[xx * ksize + x] = if v < 0.0 { (-0.5 + f) as i32 } else { (0.5 + f) as i32 };
        }
        bounds.push((xmin, xmax));
    }
    (bounds, kk, ksize)
}

fn clip8(v: i64) -> u8 {
    (v >> PRECISION_BITS).clamp(0, 255) as u8
}

/// RGB u8 (h, w) -> RGB u8 (oh, ow).
pub fn pil_bilinear(src: &[u8], w: usize, h: usize, ow: usize, oh: usize) -> Vec<u8> {
    let (bx, kx, sx) = coeffs(w, ow);
    let mut mid = vec![0u8; h * ow * 3];
    for y in 0..h {
        for (xx, &(xmin, n)) in bx.iter().enumerate() {
            for c in 0..3 {
                let mut ss: i64 = 1 << (PRECISION_BITS - 1);
                for x in 0..n {
                    ss += src[(y * w + xmin + x) * 3 + c] as i64 * kx[xx * sx + x] as i64;
                }
                mid[(y * ow + xx) * 3 + c] = clip8(ss);
            }
        }
    }
    let (by, ky, sy) = coeffs(h, oh);
    let mut out = vec![0u8; oh * ow * 3];
    for (yy, &(ymin, n)) in by.iter().enumerate() {
        for x in 0..ow {
            for c in 0..3 {
                let mut ss: i64 = 1 << (PRECISION_BITS - 1);
                for y in 0..n {
                    ss += mid[((ymin + y) * ow + x) * 3 + c] as i64 * ky[yy * sy + y] as i64;
                }
                out[(yy * ow + x) * 3 + c] = clip8(ss);
            }
        }
    }
    out
}

/// torch `F.interpolate(mode="bilinear", align_corners=False)` for one channel, f32 -> f32.
pub fn upsample_bilinear(src: &[f32], w: usize, h: usize, ow: usize, oh: usize) -> Vec<f32> {
    let axis = |o: usize, n_in: usize, n_out: usize| -> (usize, usize, f32) {
        let s = ((o as f32 + 0.5) * (n_in as f32 / n_out as f32) - 0.5).max(0.0);
        let i0 = (s.floor() as usize).min(n_in - 1);
        let i1 = (i0 + 1).min(n_in - 1);
        (i0, i1, s - i0 as f32)
    };
    let xs: Vec<_> = (0..ow).map(|x| axis(x, w, ow)).collect();
    let mut out = vec![0f32; ow * oh];
    for y in 0..oh {
        let (y0, y1, ly) = axis(y, h, oh);
        for (x, &(x0, x1, lx)) in xs.iter().enumerate() {
            let a = src[y0 * w + x0] * (1.0 - lx) + src[y0 * w + x1] * lx;
            let b = src[y1 * w + x0] * (1.0 - lx) + src[y1 * w + x1] * lx;
            out[y * ow + x] = a * (1.0 - ly) + b * ly;
        }
    }
    out
}
