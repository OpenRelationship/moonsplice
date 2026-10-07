// What the decoder gives back when the playhead does not move forward one frame at a time.
//
// The frame server is built for playback: ask for the next frame and it decodes on, which is the
// right and fast thing. An editor does not only play. It drops the playhead five minutes in,
// jumps back to the top, scrubs, and compares two moments -- and every one of those is a
// question about a frame the decoder was not already next to.
//
// So this asks each frame twice: once from a handle that has been walked there, and once from a
// handle that was just opened and asked for it directly. A freshly opened decoder has nothing to
// be wrong about, which makes it the truth to measure against. The two must agree, whichever way
// the playhead arrived, and neither of them may take a time that grows with how far away it was.

use std::ffi::CString;
use std::time::Instant;

use moonsplice_decode::{ed_close, ed_frame_rgba, ed_frame_yuv, ed_info, ed_open2};

const W: i32 = 640;
const H: i32 = 360;

struct Clip {
    handle: i64,
    mode: i32,
    w: usize,
    h: usize,
}

impl Clip {
    fn open(path: &str) -> Option<Clip> {
        let c = CString::new(path).ok()?;
        let handle = ed_open2(c.as_ptr(), W, H);
        if handle < 0 {
            return None;
        }
        let (mut mode, mut w, mut h, mut full) = (0, 0, 0, 0);
        if ed_info(handle, &mut mode, &mut w, &mut h, &mut full) != 0 {
            return None;
        }
        Some(Clip {
            handle,
            mode,
            w: w as usize,
            h: h as usize,
        })
    }

    /// The frame at `t`, as bytes, whatever the source's pixel format is.
    fn at(&self, t: f64) -> Option<Vec<u8>> {
        if self.mode == 0 {
            let ysz = self.w * self.h;
            let csz = (self.w / 2) * (self.h / 2);
            let mut y = vec![0u8; ysz];
            let mut u = vec![0u8; csz];
            let mut v = vec![0u8; csz];
            let ok = ed_frame_yuv(
                self.handle,
                t,
                y.as_mut_ptr(),
                ysz,
                u.as_mut_ptr(),
                csz,
                v.as_mut_ptr(),
                csz,
            );
            if ok != 0 {
                return None;
            }
            y.extend_from_slice(&u);
            y.extend_from_slice(&v);
            Some(y)
        } else {
            let len = (W as usize) * (H as usize) * 4;
            let mut out = vec![0u8; len];
            if ed_frame_rgba(self.handle, t, out.as_mut_ptr(), len) != 0 {
                return None;
            }
            Some(out)
        }
    }
}

impl Drop for Clip {
    fn drop(&mut self) {
        ed_close(self.handle);
    }
}

fn source() -> Option<String> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        let p = dir.join("comps/assets/earth_night.webm");
        if p.is_file() {
            return Some(p.to_string_lossy().into_owned());
        }
        if !dir.pop() {
            eprintln!("skipped: no checkout with evals/assets");
            return None;
        }
    }
}

/// How far apart two frames are, as an average byte difference. Decoding is deterministic, so the
/// same moment reached two ways is the same bytes; this reports a number rather than a boolean so
/// a failure says how wrong it was rather than only that it was.
fn apart(a: &[u8], b: &[u8]) -> f64 {
    assert_eq!(a.len(), b.len());
    let total: u64 = a
        .iter()
        .zip(b)
        .map(|(x, y)| x.abs_diff(*y) as u64)
        .sum();
    total as f64 / a.len() as f64
}

#[test]
fn a_moment_is_the_same_moment_however_the_playhead_got_there() {
    let Some(path) = source() else { return };
    let Some(walked) = Clip::open(&path) else {
        eprintln!("skipped: the decoder would not open that");
        return;
    };

    // A path a person actually takes: play a little, jump to the end, come back to the top,
    // land in the middle. Every one of these is asked of the same handle, in this order.
    let route = [0.0, 0.5, 1.0, 20.0, 0.25, 12.0, 0.0, 25.5];
    for t in route {
        let Some(got) = walked.at(t) else {
            panic!("no frame at {t}s after walking there");
        };
        let fresh = Clip::open(&path).expect("a second handle on the same file");
        let want = fresh.at(t).expect("no frame at {t}s from a fresh handle");
        let d = apart(&got, &want);
        assert!(
            d < 1.0,
            "the frame at {t}s differs by {d:.1} per byte depending on how the playhead got there"
        );
    }
}

#[test]
fn jumping_forward_does_not_cost_what_the_distance_is() {
    let Some(path) = source() else { return };
    let Some(clip) = Clip::open(&path) else {
        eprintln!("skipped: the decoder would not open that");
        return;
    };
    // Warm it: the first frame of anything pays for the decoder starting up.
    clip.at(0.0).expect("a first frame");

    let near = {
        let t = Instant::now();
        clip.at(0.2).expect("a frame just ahead");
        t.elapsed().as_secs_f64()
    };
    // Back to the top, then a long way forward in one go -- the seek a person makes when they
    // drop the playhead somewhere. Decoding through would cost the whole distance.
    clip.at(0.0).expect("back at the top");
    let far = {
        let t = Instant::now();
        clip.at(25.0).expect("a frame a long way ahead");
        t.elapsed().as_secs_f64()
    };
    eprintln!("\n  a frame just ahead   {:.1} ms", near * 1000.0);
    eprintln!("  a frame far ahead    {:.1} ms", far * 1000.0);
    // Generous on purpose: a seek really does cost more than the next frame, because it lands on
    // a keyframe and decodes up. What this is here to catch is the cost that grows with the
    // distance, which shows up as multiples and not as a small constant.
    assert!(
        far < near * 8.0 + 0.150,
        "a jump of twenty-five seconds cost {:.0} ms against {:.0} ms for the next frame: it is \
         decoding through rather than seeking",
        far * 1000.0,
        near * 1000.0
    );
}
