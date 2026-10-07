//! EdgeTAM video object tracking on ONNX Runtime, CPU or Core ML.
//!
//! The network is the four graphs of `jax-image-tools/edgetam-video-onnx` plus a single-mask decoder
//! exported by `tools/edgetam_onnx_setup.py`. The memory bank is not a graph: it lives here, ported
//! from transformers' `EdgeTamVideoModel` (`_prepare_memory_conditioned_features`,
//! `_gather_memory_frame_outputs`, `_get_object_pointers`, `_encode_new_memory`). The Python
//! reference it was checked against is `vision/cache/bench/edgetam_onnx_ref.py`; on the handoff clip
//! it matches transformers at mean IoU 0.9966.
//!
//! Frame 0 carries the box prompt. One object per track, forward in time -- the shape
//! `segtrack.masks` asks for; a backward pass is the caller reversing the frames.

mod memory;
mod resize;
mod session;
mod tracker;

use std::collections::HashMap;
use std::path::PathBuf;

use ort::session::Session;

pub use resize::{pil_bilinear, upsample_bilinear};

const IMG: usize = 1024;
const HW: usize = 64 * 64;
const C: usize = 256;
const MEM: usize = 64;
const MEM_TOKENS: usize = 512;
const NUM_MASKMEM: usize = 7;
const MAX_PTRS: usize = 16;
const MEAN: [f32; 3] = [0.485, 0.456, 0.406];
const STD: [f32; 3] = [0.229, 0.224, 0.225];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Device {
    Cpu,
    /// Core ML for the graphs it compiles (vision encoder, memory encoder, and the memory attention
    /// at each fixed shape); the decoders stay on the CPU, where Core ML refuses them, and so does
    /// the dynamic memory attention for any shape without a fixed graph.
    CoreMl(Units),
    /// CUDA for every graph (built with `--features cuda`, Linux).
    Cuda,
}

/// Set by `Tracker::load(.., Device::Cuda)`; every session opened after it asks for CUDA.
static CUDA: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Units {
    Gpu,
    All,
    Ane,
}

pub struct Tracker {
    vision: Session,
    decoder: Session,
    decoder_single: Session,
    attention: Session,
    /// Core ML sessions of fixed-shape memory attentions (`memory_attention_s{S}_p{P}.onnx`), by
    /// (spatial memories, pointers), opened the first time a track reaches that shape. The setup
    /// ships only the steady state, s7_p16: fixing every warm-up shape too was slower end to end.
    attention_fixed: HashMap<(usize, usize), Session>,
    coreml: Option<(Units, PathBuf)>,
    dir: PathBuf,
    memory: Session,
    no_mem: Vec<f32>,
    tpos: Vec<f32>,
    /// The vision encoder's pos2, which does not depend on the image: read once from `pos2.f32` when
    /// the lean encoder (feats0-2 only, `tools/edgetam_onnx_setup.py`) is present.
    pos2: Option<Vec<f32>>,
    /// Device-resident path (`track_bound`): features stay on the device between graphs. Used on CUDA
    /// when `memory_attention_nchw.onnx` is present; `MOONSPLICE_TRACK_BOUND=1` forces it on the CPU.
    ///
    /// NOT default on Core ML, and measured: the device-resident half is CUDA-only (the allocation
    /// device falls back to the host), leaving only the transposes the NCHW graph avoids, and those
    /// do not pay. Base M4, handoff clip, two A/B pairs, normalised per tracker call because the
    /// seeder's call count varies run to run (18 vs 14) and wall-clock comparisons are meaningless
    /// without it: 8.11 -> 8.30 s/call and 7.05 -> 7.36 s/call. Slower in both pairs, ~3-4%.
    attention_nchw: Option<Session>,
    cuda: bool,
}

pub struct FrameMask {
    pub mask: Vec<u8>, // (h, w), 1 = object
    pub score: f32,    // object score logit; > 0 ~ present
}

type Err = String;
