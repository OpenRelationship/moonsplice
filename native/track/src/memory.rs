//! The memory bank: what each tracked frame leaves behind, and how the spatial memories and object
//! pointers are gathered from it for the next frame.

use std::collections::HashMap;

use super::{Tracker, MEM, MEM_TOKENS, NUM_MASKMEM};

pub(crate) struct Memory {
    pub(crate) tokens: Vec<f32>, // (512, 1, 64)
    pub(crate) pos: Vec<f32>,    // (512, 1, 64)
    pub(crate) ptr: Vec<f32>,    // (256)
}

impl Tracker {
    pub(crate) fn spatial_memory(&self, bank: &HashMap<usize, Memory>, f: usize) -> (Vec<f32>, Vec<f32>) {
        spatial_memory(&self.tpos, bank, f)
    }

    pub(crate) fn pointer_memory(&self, bank: &HashMap<usize, Memory>, f: usize, max_ptrs: usize) -> Vec<f32> {
        pointer_memory(bank, f, max_ptrs)
    }
}

/// Conditioning frame first (temporal slot 0 -> tpos[6]), then up to six previous frames,
/// oldest first (offset r -> tpos[r - 1]). Each memory is 512 tokens of 64.
pub(crate) fn spatial_memory(tpos: &[f32], bank: &HashMap<usize, Memory>, f: usize) -> (Vec<f32>, Vec<f32>) {
    {
        let mut slots: Vec<(usize, &Memory)> = vec![(0, &bank[&0])];
        for r in (1..NUM_MASKMEM).rev() {
            if f > r {
                if let Some(m) = bank.get(&(f - r)) {
                    slots.push((r, m));
                }
            }
        }
        let mut mem = Vec::with_capacity(slots.len() * MEM_TOKENS * MEM);
        let mut pos = Vec::with_capacity(mem.capacity());
        for (r, m) in slots {
            let ti = if r == 0 { NUM_MASKMEM - 1 } else { r - 1 };
            let tp = &tpos[ti * MEM..(ti + 1) * MEM];
            mem.extend_from_slice(&m.tokens);
            for tok in 0..MEM_TOKENS {
                for c in 0..MEM {
                    pos.push(m.pos[tok * MEM + c] + tp[c]);
                }
            }
        }
        (mem, pos)
    }

}

/// The conditioning frame's pointer, then up to `max_ptrs - 1` previous frames' (nearest first).
/// Each 256-wide pointer becomes four consecutive 64-wide tokens; their positions are zero
/// (`enable_temporal_pos_encoding_for_object_pointers` is off for EdgeTAM).
pub(crate) fn pointer_memory(bank: &HashMap<usize, Memory>, f: usize, max_ptrs: usize) -> Vec<f32> {
    {
        let mut out = bank[&0].ptr.clone();
        for d in 1..max_ptrs {
            if d >= f {
                break;
            }
            if let Some(m) = bank.get(&(f - d)) {
                out.extend_from_slice(&m.ptr);
            }
        }
        out
    }
}
