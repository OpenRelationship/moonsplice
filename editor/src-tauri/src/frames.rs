//! Frames: the cache and the downscale.
//!
//! `project-sync` names this as the engine's real problem — "not state propagation but frame
//! cache invalidation, keyed on `(source hash, t, size)`". The hash comes free from the
//! source being the truth, so there is no invalidation code here at all: a changed
//! composition is a different key, and the old entries fall out of the back of the cache.
//!
//! The renderer paints at the composition's own size. Scaling to what the window actually
//! shows happens here, once, before the frame crosses into the webview, because a 1920×1080
//! RGBA frame is 8 MB and a scrub asks for hundreds.

use std::collections::HashMap;
use std::sync::Mutex;

use jpeg_encoder::{ColorType, Encoder, SamplingFactor};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FrameKey {
    /// Which open composition to ask. Not part of what a frame *is* -- the hash is that -- but
    /// the queue needs to know who to ask, and two variations of one file are two engines.
    pub variation: String,
    pub hash: String,
    /// Milliseconds. A scrub lands on a frame boundary far more often than not, so the
    /// quantisation is what makes the cache hit at all.
    pub t_ms: u32,
    pub w: u32,
    pub h: u32,
    /// Raw pixels for the canvas, or a JPEG. Both are asked for -- the preview takes the first
    /// and a thumbnail the second -- and they are not interchangeable, so they are different
    /// entries rather than one entry and a conversion.
    pub raw: bool,
}

/// A frame as it will be handed to the window: the bytes, and the size they really are, which
/// `fit` decided and the pane needs to be told.
#[derive(Debug, Clone)]
pub struct Frame {
    pub bytes: std::sync::Arc<Vec<u8>>,
    pub w: u32,
    pub h: u32,
}

/// A fixed-size cache with a first-in eviction order. Not an LRU: a scrub walks forward, so
/// recency and insertion order agree, and insertion order costs nothing to keep.
pub struct FrameCache {
    inner: Mutex<Inner>,
    budget: usize,
}

struct Inner {
    map: HashMap<FrameKey, Frame>,
    order: std::collections::VecDeque<FrameKey>,
    bytes: usize,
    hits: u64,
    misses: u64,
}

impl FrameCache {
    pub fn new(budget_bytes: usize) -> FrameCache {
        FrameCache {
            inner: Mutex::new(Inner {
                map: HashMap::new(),
                order: std::collections::VecDeque::new(),
                bytes: 0,
                hits: 0,
                misses: 0,
            }),
            budget: budget_bytes,
        }
    }

    pub fn get(&self, key: &FrameKey) -> Option<Frame> {
        let mut i = self.inner.lock().expect("cache");
        match i.map.get(key).cloned() {
            Some(v) => {
                i.hits += 1;
                Some(v)
            }
            None => {
                i.misses += 1;
                None
            }
        }
    }

    pub fn put(&self, key: FrameKey, bytes: Vec<u8>, w: u32, h: u32) -> Frame {
        let frame = Frame {
            bytes: std::sync::Arc::new(bytes),
            w,
            h,
        };
        let mut i = self.inner.lock().expect("cache");
        if let Some(already) = i.map.get(&key) {
            return already.clone();
        }
        i.bytes += frame.bytes.len();
        i.order.push_back(key.clone());
        i.map.insert(key, frame.clone());
        while i.bytes > self.budget {
            let Some(old) = i.order.pop_front() else { break };
            if let Some(v) = i.map.remove(&old) {
                i.bytes -= v.bytes.len();
            }
        }
        frame
    }

    /// Drop everything from one composition. Only used when a project closes; an edit needs
    /// no call here, which is the point.
    pub fn forget(&self, hash: &str) {
        let mut i = self.inner.lock().expect("cache");
        let gone: Vec<FrameKey> = i.map.keys().filter(|k| k.hash == hash).cloned().collect();
        for k in gone {
            if let Some(v) = i.map.remove(&k) {
                i.bytes -= v.bytes.len();
            }
        }
        i.order.retain(|k| k.hash != hash);
    }

    pub fn stats(&self) -> (u64, u64, usize) {
        let i = self.inner.lock().expect("cache");
        (i.hits, i.misses, i.bytes)
    }
}

/// Premultiplied RGBA at `sw×sh` to a JPEG at up to `tw×th`, keeping the aspect.
///
/// The renderer clears to an opaque background, so alpha is 1 across the frame and dropping
/// it loses nothing. Compositing a checkerboard for a transparent comp would be a lie about
/// what the render is.
///
/// 4:2:0, like every video this preview is made of. Chroma at half resolution is a quarter of
/// the colour work and, measured against 4:4:4 on the eval suite, both smaller and faster --
/// and the one thing a preview must not spend time on is colour precision nobody can see at
/// pane size.
pub fn rgba_to_jpeg(rgba: &[u8], sw: u32, sh: u32, tw: u32, th: u32, quality: u8) -> Option<Vec<u8>> {
    if sw == 0 || sh == 0 || rgba.len() < (sw as usize * sh as usize * 4) {
        return None;
    }
    let (dw, dh) = fit(sw, sh, tw.max(1), th.max(1));
    let scaled = box_down(rgba, sw, sh, dw, dh);
    encode_rgb(&scaled, dw, dh, quality)
}

/// RGB at exactly `dw×dh` to a JPEG. Split out because the scale and the encode are the two
/// halves of the frame budget and are measured separately.
pub fn encode_rgb(rgb: &[u8], dw: u32, dh: u32, quality: u8) -> Option<Vec<u8>> {
    if rgb.len() < dw as usize * dh as usize * 3 || dw > u16::MAX as u32 || dh > u16::MAX as u32 {
        return None;
    }
    let mut out = Vec::with_capacity(96 * 1024);
    let mut e = Encoder::new(&mut out, quality);
    e.set_sampling_factor(SamplingFactor::R_4_2_0);
    e.encode(rgb, dw as u16, dh as u16, ColorType::Rgb).ok()?;
    Some(out)
}

/// The frame the preview actually paints: scaled, still RGBA, no codec anywhere.
///
/// This is the measurement that decided the shape of the whole path. A JPEG of one 960x540 frame
/// costs tens of milliseconds to encode here and a few more to decode in the window -- most of a
/// 33 ms budget spent turning pixels into pixels. Handing the window the pixels costs the scale
/// (about 2 ms across the cores) and a copy, and a canvas takes `ImageData` without decoding
/// anything. Alpha is kept rather than dropped for exactly one reason: `ImageData` wants four
/// channels, and converting three into four in JavaScript, per frame, is the cost we just
/// removed reappearing somewhere worse.
pub fn scale_rgba(rgba: &[u8], sw: u32, sh: u32, tw: u32, th: u32) -> Option<(Vec<u8>, u32, u32)> {
    if sw == 0 || sh == 0 || rgba.len() < (sw as usize * sh as usize * 4) {
        return None;
    }
    let (dw, dh) = fit(sw, sh, tw.max(1), th.max(1));
    Some((box_down_to::<4>(rgba, sw, sh, dw, dh), dw, dh))
}

/// Drop the alpha and shrink, in one pass over the *destination*.
///
/// The obvious way -- convert 1280x720 RGBA to RGB, then run a filtered resize over it -- walks
/// a million source pixels twice to produce half a million. This walks the output once and
/// averages the source rectangle behind each pixel, which is an area filter: the right one for
/// a downscale, and the only one for a preview that has to keep up with playback.
///
/// The frame is opaque by construction -- the renderer composites onto the composition's own
/// background -- so the alpha channel is dropped, not blended.
fn box_down(rgba: &[u8], sw: u32, sh: u32, dw: u32, dh: u32) -> Vec<u8> {
    box_down_to::<3>(rgba, sw, sh, dw, dh)
}

/// `C` is 3 for the codec and 4 for the canvas; the walk is the same either way, and a fourth
/// channel is written opaque because the renderer already composited onto the background.
fn box_down_to<const C: usize>(rgba: &[u8], sw: u32, sh: u32, dw: u32, dh: u32) -> Vec<u8> {
    let (sw_u, dw_u, dh_u) = (sw as usize, dw as usize, dh as usize);
    let mut out = vec![255u8; dw_u * dh_u * C];
    if dw == sw && dh == sh {
        for i in 0..(dw_u * dh_u) {
            let (o, p) = (i * 4, i * C);
            out[p] = rgba[o];
            out[p + 1] = rgba[o + 1];
            out[p + 2] = rgba[o + 2];
        }
        return out;
    }
    // Exact source bounds per destination pixel, in fixed point, so the last row and column
    // are covered and nothing is sampled twice.
    let xs: Vec<(usize, usize)> = (0..dw_u)
        .map(|x| {
            let a = x * sw as usize / dw_u;
            let b = ((x + 1) * sw as usize / dw_u).max(a + 1).min(sw as usize);
            (a, b)
        })
        .collect();

    // Destination rows are independent, and every core on the machine is idle while one of them
    // does this. Split by rows rather than by pixels: each strip reads its own band of the
    // source, so nothing is shared and nothing is locked. One strip per core, but never fewer
    // than 64 rows in a strip -- below that the threads cost more than the work.
    let lanes = lanes_for(dh_u);
    if lanes < 2 {
        rows::<C>(rgba, sw_u, sh as usize, dw_u, dh_u, &xs, 0, dh_u, &mut out);
        return out;
    }
    let per = dh_u.div_ceil(lanes);
    let sh_u = sh as usize;
    std::thread::scope(|scope| {
        let mut rest: &mut [u8] = &mut out;
        let mut y0 = 0usize;
        while y0 < dh_u {
            let y1 = (y0 + per).min(dh_u);
            let (mine, tail) = rest.split_at_mut((y1 - y0) * dw_u * C);
            rest = tail;
            let xs = &xs;
            scope.spawn(move || {
                rows::<C>(rgba, sw_u, sh_u, dw_u, dh_u, xs, y0, y1, mine);
            });
            y0 = y1;
        }
    });
    out
}

/// How many strips to cut the destination into. Kept here so the test can state the rule
/// rather than infer it from timings.
fn lanes_for(dh: usize) -> usize {
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    (dh / 64).clamp(1, cores.max(1))
}

/// Destination rows `y0..y1` of the scale, written to `out` starting at its own first row.
#[allow(clippy::too_many_arguments)]
fn rows<const C: usize>(
    rgba: &[u8],
    sw_u: usize,
    sh_u: usize,
    dw_u: usize,
    dh_u: usize,
    xs: &[(usize, usize)],
    y0: usize,
    y1: usize,
    out: &mut [u8],
) {
    for y in y0..y1 {
        let sy0 = y * sh_u / dh_u;
        let sy1 = ((y + 1) * sh_u / dh_u).max(sy0 + 1).min(sh_u);
        let row = (y - y0) * dw_u * C;
        for x in 0..dw_u {
            let (x0, x1) = xs[x];
            let mut r = 0u32;
            let mut g = 0u32;
            let mut b = 0u32;
            for sy in sy0..sy1 {
                let base = (sy * sw_u + x0) * 4;
                for px in 0..(x1 - x0) {
                    let o = base + px * 4;
                    r += rgba[o] as u32;
                    g += rgba[o + 1] as u32;
                    b += rgba[o + 2] as u32;
                }
            }
            let n = ((x1 - x0) * (sy1 - sy0)) as u32;
            let p = row + x * C;
            out[p] = (r / n) as u8;
            out[p + 1] = (g / n) as u8;
            out[p + 2] = (b / n) as u8;
        }
    }
}

/// The largest `w×h` inside the box that keeps the source aspect, never upscaling.
pub fn fit(sw: u32, sh: u32, bw: u32, bh: u32) -> (u32, u32) {
    let s = (bw as f64 / sw as f64).min(bh as f64 / sh as f64).min(1.0);
    (
            ((sw as f64 * s).round() as u32).max(1),
            ((sh as f64 * s).round() as u32).max(1),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(h: &str, t: u32) -> FrameKey {
        FrameKey {
            variation: "v1".into(),
            hash: h.into(),
            t_ms: t,
            w: 640,
            h: 360,
            raw: true,
        }
    }

    #[test]
    fn a_changed_source_is_simply_a_different_key() {
        let c = FrameCache::new(1024 * 1024);
        c.put(key("aaa", 0), vec![0; 100], 640, 360);
        assert!(c.get(&key("aaa", 0)).is_some());
        // the edit lands; nothing tells the cache anything
        assert!(c.get(&key("bbb", 0)).is_none());
    }

    #[test]
    fn the_cache_stays_inside_its_budget() {
        let c = FrameCache::new(250);
        for t in 0..10 {
            c.put(key("aaa", t), vec![0; 100], 640, 360);
        }
        let (_, _, bytes) = c.stats();
        assert!(bytes <= 250, "{bytes} over budget");
        assert!(c.get(&key("aaa", 9)).is_some(), "the newest survived");
        assert!(c.get(&key("aaa", 0)).is_none(), "the oldest went first");
    }

    #[test]
    fn forgetting_one_composition_leaves_the_other() {
        let c = FrameCache::new(1024 * 1024);
        c.put(key("aaa", 0), vec![0; 10], 640, 360);
        c.put(key("bbb", 0), vec![0; 10], 640, 360);
        c.forget("aaa");
        assert!(c.get(&key("aaa", 0)).is_none());
        assert!(c.get(&key("bbb", 0)).is_some());
    }

    #[test]
    fn a_frame_fits_its_box_without_upscaling() {
        assert_eq!(fit(1920, 1080, 960, 540), (960, 540));
        assert_eq!(fit(1920, 1080, 960, 200), (356, 200));
        assert_eq!(fit(640, 360, 1920, 1080), (640, 360));
    }

    #[test]
    fn rgba_encodes_to_a_jpeg_of_the_asked_size() {
        let (w, h) = (64u32, 36u32);
        let rgba: Vec<u8> = (0..w * h)
            .flat_map(|i| [(i % 255) as u8, 30, 200, 255])
            .collect();
        let jpg = rgba_to_jpeg(&rgba, w, h, 32, 32, 85).expect("encoded");
        assert_eq!(&jpg[..2], &[0xff, 0xd8], "a JPEG starts with SOI");
        let got = image::load_from_memory(&jpg).unwrap();
        assert_eq!((got.width(), got.height()), (32, 18));
    }

    #[test]
    fn the_raw_frame_is_four_channels_and_opaque() {
        // What a canvas takes, with no conversion in the window: RGBA, alpha already 1.
        let (w, h) = (8u32, 4u32);
        let rgba: Vec<u8> = (0..w * h).flat_map(|_| [10, 20, 30, 128]).collect();
        let (out, dw, dh) = scale_rgba(&rgba, w, h, 4, 2).expect("scaled");
        assert_eq!((dw, dh), (4, 2));
        assert_eq!(out.len(), 4 * 2 * 4);
        assert_eq!(&out[..4], &[10, 20, 30, 255], "opaque, whatever the source alpha was");
    }

    #[test]
    fn a_short_buffer_is_refused_rather_than_read_past() {
        assert!(rgba_to_jpeg(&[0; 8], 64, 36, 64, 36, 85).is_none());
    }
}

#[cfg(test)]
mod bench {
    use super::*;

    /// Not a correctness test: a measurement, printed, so the number in a commit message is one
    /// somebody took rather than guessed. Split, because "encode" is two very different jobs and
    /// only one of them was ever the expensive one.
    ///
    /// Noise is the worst case for a JPEG and for this scale both -- a real frame is cheaper on
    /// both counts -- so these numbers are a ceiling, not a typical frame.
    #[test]
    fn how_long_a_frame_takes_to_encode() {
        eprintln!("load average: {:.1}", crate::perf::load_average());
        for (sw, sh, tw, th) in [(1280u32, 720u32, 960u32, 540u32), (1920, 1080, 1280, 720)] {
            let rgba: Vec<u8> = (0..(sw as usize * sh as usize * 4))
                .map(|i| (i % 251) as u8)
                .collect();
            let (dw, dh) = fit(sw, sh, tw, th);
            let n = 20;

            let _ = rgba_to_jpeg(&rgba, sw, sh, tw, th, 82);
            let t = std::time::Instant::now();
            let mut bytes = 0;
            for _ in 0..n {
                bytes = rgba_to_jpeg(&rgba, sw, sh, tw, th, 82).unwrap().len();
            }
            let each = t.elapsed().as_secs_f64() * 1000.0 / n as f64;

            let t = std::time::Instant::now();
            let mut scaled = Vec::new();
            for _ in 0..n {
                scaled = box_down(&rgba, sw, sh, dw, dh);
            }
            let scale = t.elapsed().as_secs_f64() * 1000.0 / n as f64;

            let t = std::time::Instant::now();
            for _ in 0..n {
                encode_rgb(&scaled, dw, dh, 82).unwrap();
            }
            let jpeg = t.elapsed().as_secs_f64() * 1000.0 / n as f64;

            eprintln!(
                "{sw}x{sh} -> {dw}x{dh}: {each:.2} ms/frame ({:.0} fps), {} KB  [scale {scale:.2} over {} lanes + jpeg {jpeg:.2}]",
                1000.0 / each,
                bytes / 1024,
                lanes_for(dh as usize),
            );
        }
    }
}
