//! The opcode interpreter: one pass over the command stream, recording into a stack of scenes (the
//! frame, and a scratch frame for each effect, perspective, displacement or matte being drawn),
//! then the frame painted and film grain laid over it. The opcodes themselves are in draw.rs
//! (paths, fills, text, images), layer.rs (clips, blends, filters, opacity) and scratch.rs (the
//! scratch frames, and what a 105 does when it closes one).

mod draw;
mod layer;
mod scratch;

use anyrender::{ResourceId, Scene};
use vello_cpu::kurbo::{Affine, BezPath};
use vello_cpu::{Pixmap, RenderContext};

use crate::state::{Reader, State};
use crate::{displace, paint_cpu, persp, settings};

/// What a 105 closes, and for a scratch frame, what to do with it.
enum Fx { Effects([f32; 9]), Chain(Vec<Pass>) }
/// One pass of an `s:fx` chain: the CPU maths in fx.rs, or the comp's own GLSL on the GPU.
enum Pass { Cpu(u32, f32, f32), Shader(String, f32) }
enum Close {
    /// run the effects on the scratch frame (sw x sh at frame-space ox, oy) and put it back
    Fx(Fx, (i32, i32, u16, u16)),
    /// warp the flat page (pw x ph) onto a stage (sw x sh) and draw the stage with `place`
    Persp(persp::Camera, (u16, u16, u16, u16), (f32, f32), Affine),
    /// displace the flat page (pw x ph) as a grid onto a stage (sw x sh), drawn with `place`
    Displace(displace::Grid, (u16, u16, u16, u16), (f32, f32), Affine),
    /// a matte being drawn (117 until 118): its mode
    MatteSource(u32),
    /// the layer a matte shows (118 until 105): the matte's pixels and its mode
    Matte(Pixmap, u32),
}

struct Frame {
    scene: Scene,
    /// the transform from what the stream says to this frame's pixels (identity for the frame)
    off: Affine,
    fx: Option<Close>,
}

/// Everything the stream changes as it is read: the frames being drawn, what each 105 pops, the
/// current transform and path, and the grain to lay over the result.
struct Run<'a> {
    st: &'a mut State,
    rd: Reader<'a>,
    strings: &'a [u8],
    w: u16,
    h: u16,
    scale: f32,
    threads: u16,
    frames: Vec<Frame>,
    // whether a 105 pops a layer (false) or closes a scratch frame (true)
    layers: Vec<bool>,
    temp: Vec<ResourceId>,
    // Scene units onto output pixels. Every transform is composed from this, so a scaled preview
    // is the same drawing seen from further away rather than a different drawing.
    root: Affine,
    base: Affine,
    path: BezPath,
    grain: Option<(f32, u32)>,
    grains: Vec<(f32, u32, usize, usize, usize, usize)>,
}

impl<'a> Run<'a> {
    /// A string from the stream's string table.
    fn sref(&self, off: f32, len: f32) -> Option<&'a str> {
        let strings: &'a [u8] = self.strings;
        let (o, l) = (off as usize, len as usize);
        std::str::from_utf8(strings.get(o..o + l)?).ok()
    }

    /// Every opcode in the stream, in order; None at the first one that is malformed.
    fn read(&mut self) -> Option<()> {
        while let Some(op) = self.rd.next() {
            let off = self.frames.last()?.off;
            let cur = off * self.base;
            match op as u32 {
                op @ (0..=10 | 100..=103 | 116) => self.draw(op, off, cur)?,
                op @ (104 | 105 | 107 | 108 | 110 | 113) => self.layer(op, cur)?,
                op @ (106 | 111 | 112 | 114 | 115 | 117 | 118) => self.scratch(op, cur)?,
                _ => return None,
            }
        }
        Some(())
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn run(st: &mut State, cmds: &[f32], strings: &[u8], w: u16, h: u16, scale: f32, threads: u16, out: &mut [u8]) -> Option<()> {
    if out.len() != w as usize * h as usize * 4 {
        return None;
    }
    // vello_cpu filters are single-threaded only: any 108 in the stream pins threads to 0
    let has_filter = {
        let mut r = Reader { d: cmds, i: 0 };
        let mut found = false;
        while let Some(op) = r.next() {
            let n = match op as u32 { 0 => 8, 1 => 9, 2 => 7, 3 | 4 => 2, 5 => 6, 6 => 4, 7 => 5, 8 => 16, 9 => 11, 10 => 2,
                100 => 6, 101 => { let hdr = r.take::<15>(); match hdr { Some(h) => (h[14] as usize) * 8, None => 0 } }, 102 => 4, 103 => 7, 104 => 5, 105 => 0,
                106 => 6, 107 => 2, 108 => { found = true; 2 }, 110 => 1, 111 => 13, 113 => 5, 114 => 21, 115 => 9, 116 => 7, 117 => 1, 118 => 0, 112 => { let hdr = r.take::<5>(); match hdr { Some(h) => (h[0] as usize) * 4, None => 0 } }, _ => 0 };
            r.i += n;
        }
        found
    };
    let threads = if has_filter { 0 } else { threads };

    let root = if scale == 1.0 { Affine::IDENTITY } else { Affine::scale(scale as f64) };
    let mut r = Run {
        st,
        rd: Reader { d: cmds, i: 0 },
        strings,
        w,
        h,
        scale,
        threads,
        frames: vec![Frame { scene: Scene::new(), off: Affine::IDENTITY, fx: None }],
        layers: Vec::new(),
        temp: Vec::new(),
        root,
        base: root,
        path: BezPath::new(),
        grain: None,
        grains: Vec::new(),
    };
    let ok = r.read();
    let Run { st, mut frames, grain, mut grains, temp, .. } = r;
    let need_new = match &st.ctx {
        Some((cw, ch, ct, _)) => *cw != w || *ch != h || *ct != threads,
        None => true,
    };
    if need_new {
        st.ctx = Some((w, h, threads, RenderContext::new_with(w, h, settings(threads))));
    }
    let mut ctx = st.ctx.take()?.3;
    let result = ok.filter(|_| frames.len() == 1).map(|_| {
        let scene = frames.pop().unwrap().scene;
        let pm = paint_cpu(&mut ctx, &mut st.res, &st.ids, scene);
        out.copy_from_slice(pm.data_as_u8_slice());
        if let Some((amount, seed)) = grain {
            grains.push((amount, seed, 0, 0, w as usize, h as usize));
        }
        for (amount, seed, x0, y0, x1, y1) in grains {
            let amp = (amount * 255.0) as i32;
            if amp > 0 {
                for yy in y0..y1 { for xx in x0..x1 {
                    let i = yy * w as usize + xx;
                    let mut n = (i as u32).wrapping_mul(0x9E3779B9).wrapping_add(seed.wrapping_mul(0x85EBCA6B));
                    n ^= n >> 16;
                    n = n.wrapping_mul(0x7FEB352D);
                    n ^= n >> 15;
                    let d = ((n & 0xFF) as i32 - 128) * amp / 128;
                    for c in 0..3 {
                        out[i * 4 + c] = (out[i * 4 + c] as i32 + d).clamp(0, 255) as u8;
                    }
                } }
            }
        }
    });
    for rid in temp {
        if let Some(id) = st.ids.remove(&rid) { st.res.destroy_image(id); }
    }
    st.ctx = Some((w, h, threads, ctx));
    result
}

