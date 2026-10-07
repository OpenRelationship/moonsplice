//! moonsplice-effects: deterministic RGBA adjustment passes for Lua-owned surfaces.
//!
//! The host supplies premultiplied RGBA8 pixels. Blur is performed in that
//! representation (avoids dark transparent fringes); colour operations are
//! performed on unpremultiplied RGB and premultiplied again before storage.

use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};

fn gaussian_kernel(sigma: f32) -> Vec<f32> {
    if sigma <= 0.01 {
        return vec![1.0];
    }
    let radius = (sigma * 3.0).ceil() as i32;
    let mut kernel = Vec::with_capacity((radius * 2 + 1) as usize);
    let mut sum = 0.0;
    for i in -radius..=radius {
        let weight = (-(i * i) as f32 / (2.0 * sigma * sigma)).exp();
        kernel.push(weight);
        sum += weight;
    }
    for weight in &mut kernel {
        *weight /= sum;
    }
    kernel
}

fn blur_rgba(pixels: &mut [u8], width: usize, height: usize, sigma: f32) {
    if sigma <= 0.01 || width == 0 || height == 0 {
        return;
    }
    let kernel = gaussian_kernel(sigma);
    let radius = (kernel.len() / 2) as isize;
    let mut tmp = vec![0.0f32; pixels.len()];
    let src: Vec<f32> = pixels.iter().map(|&v| v as f32 / 255.0).collect();

    for y in 0..height {
        for x in 0..width {
            for channel in 0..4 {
                let mut sum = 0.0;
                for (index, weight) in kernel.iter().enumerate() {
                    let sx = (x as isize + index as isize - radius)
                        .clamp(0, width.saturating_sub(1) as isize)
                        as usize;
                    sum += src[(y * width + sx) * 4 + channel] * weight;
                }
                tmp[(y * width + x) * 4 + channel] = sum;
            }
        }
    }

    for y in 0..height {
        for x in 0..width {
            for channel in 0..4 {
                let mut sum = 0.0;
                for (index, weight) in kernel.iter().enumerate() {
                    let sy = (y as isize + index as isize - radius)
                        .clamp(0, height.saturating_sub(1) as isize)
                        as usize;
                    sum += tmp[(sy * width + x) * 4 + channel] * weight;
                }
                pixels[(y * width + x) * 4 + channel] = (sum.clamp(0.0, 1.0) * 255.0) as u8;
            }
        }
    }
}

/// Premultiplied RGBA8 in place: blur then the colour chain (CSS filter order).
#[allow(clippy::too_many_arguments)]
pub fn apply(
    pixels: &mut [u8],
    width: usize,
    height: usize,
    blur: f32,
    brightness: f32,
    contrast: f32,
    saturate: f32,
    grayscale: f32,
    sepia: f32,
    invert: f32,
    opacity: f32,
    hue_rotate_degrees: f32,
) {
    blur_rgba(pixels, width, height, blur.max(0.0));
    let grayscale = grayscale.clamp(0.0, 1.0);
    let sepia = sepia.clamp(0.0, 1.0);
    let invert = invert.clamp(0.0, 1.0);
    let (sin_a, cos_a) = hue_rotate_degrees.to_radians().sin_cos();

    for px in pixels.chunks_exact_mut(4) {
        let alpha = px[3] as f32 / 255.0;
        if alpha <= 0.0 {
            continue;
        }
        let mut r = (px[0] as f32 / 255.0 / alpha).clamp(0.0, 1.0);
        let mut g = (px[1] as f32 / 255.0 / alpha).clamp(0.0, 1.0);
        let mut b = (px[2] as f32 / 255.0 / alpha).clamp(0.0, 1.0);

        r *= brightness;
        g *= brightness;
        b *= brightness;
        r = (r - 0.5) * contrast + 0.5;
        g = (g - 0.5) * contrast + 0.5;
        b = (b - 0.5) * contrast + 0.5;
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        r = luma + (r - luma) * saturate;
        g = luma + (g - luma) * saturate;
        b = luma + (b - luma) * saturate;
        r += (luma - r) * grayscale;
        g += (luma - g) * grayscale;
        b += (luma - b) * grayscale;
        let sr = 0.393 * r + 0.769 * g + 0.189 * b;
        let sg = 0.349 * r + 0.686 * g + 0.168 * b;
        let sb = 0.272 * r + 0.534 * g + 0.131 * b;
        r += (sr - r) * sepia;
        g += (sg - g) * sepia;
        b += (sb - b) * sepia;
        r += (1.0 - 2.0 * r) * invert;
        g += (1.0 - 2.0 * g) * invert;
        b += (1.0 - 2.0 * b) * invert;

        let hr = r * (0.213 + cos_a * 0.787 - sin_a * 0.213)
            + g * (0.715 - cos_a * 0.715 - sin_a * 0.715)
            + b * (0.072 - cos_a * 0.072 + sin_a * 0.928);
        let hg = r * (0.213 - cos_a * 0.213 + sin_a * 0.143)
            + g * (0.715 + cos_a * 0.285 + sin_a * 0.140)
            + b * (0.072 - cos_a * 0.072 - sin_a * 0.283);
        let hb = r * (0.213 - cos_a * 0.213 - sin_a * 0.787)
            + g * (0.715 - cos_a * 0.715 + sin_a * 0.715)
            + b * (0.072 + cos_a * 0.928 + sin_a * 0.072);
        let final_alpha = alpha * opacity;
        px[0] = (hr.clamp(0.0, 1.0) * final_alpha * 255.0) as u8;
        px[1] = (hg.clamp(0.0, 1.0) * final_alpha * 255.0) as u8;
        px[2] = (hb.clamp(0.0, 1.0) * final_alpha * 255.0) as u8;
        px[3] = (final_alpha.clamp(0.0, 1.0) * 255.0) as u8;
    }
}

/// Applies a deterministic CSS-style adjustment chain to premultiplied RGBA8.
/// Returns 0 on success and -1 for invalid buffers or panic isolation.
#[no_mangle]
pub extern "C" fn el_fx_apply_rgba(
    pixels: *mut u8,
    width: u32,
    height: u32,
    len: usize,
    blur: f32,
    brightness: f32,
    contrast: f32,
    saturate: f32,
    grayscale: f32,
    sepia: f32,
    invert: f32,
    opacity: f32,
    hue_rotate_degrees: f32,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let expected = width as usize * height as usize * 4;
        if pixels.is_null() || len != expected {
            return None;
        }
        let pixels = unsafe { std::slice::from_raw_parts_mut(pixels, len) };
        apply(
            pixels,
            width as usize,
            height as usize,
            blur,
            brightness,
            contrast,
            saturate,
            grayscale,
            sepia,
            invert,
            opacity,
            hue_rotate_degrees,
        );
        Some(())
    }));
    if matches!(result, Ok(Some(()))) {
        0
    } else {
        -1
    }
}

#[cfg(test)]
mod tests {
    use super::apply;

    #[test]
    fn brightness_and_opacity_preserve_premultiplication() {
        let mut pixels = vec![64, 32, 16, 128];
        apply(
            &mut pixels,
            1,
            1,
            0.0,
            2.0,
            1.0,
            1.0,
            0.0,
            0.0,
            0.0,
            0.5,
            0.0,
        );
        assert_eq!(pixels[3], 64);
        assert_eq!(pixels[0], 64);
        assert_eq!(pixels[1], 32);
        assert_eq!(pixels[2], 16);
    }

    #[test]
    fn blur_spreads_premultiplied_alpha() {
        let mut pixels = vec![0; 3 * 4];
        pixels[4..8].copy_from_slice(&[255, 255, 255, 255]);
        apply(
            &mut pixels,
            3,
            1,
            1.0,
            1.0,
            1.0,
            1.0,
            0.0,
            0.0,
            0.0,
            1.0,
            0.0,
        );
        assert!(pixels[3] > 0);
        assert!(pixels[11] > 0);
    }
}
