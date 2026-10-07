//! The eight bytes on the front of a frame, which are the only thing telling the window how big
//! the picture is.
//!
//! They are written in `framing.rs` (`stamped`) and read in `editor/src/player.ts`, and nothing
//! between the two checks that they agree -- so both sides assert the layout against a literal. If either one
//! ever changes, one of the two tests goes red instead of the preview quietly going blank, which
//! is what happened when the size travelled in a header the window was not allowed to read.

use super::stamped;
use crate::frames::Frame;

#[test]
fn a_frame_says_how_big_it_is_in_its_first_eight_bytes() {
    let frame = Frame {
        bytes: std::sync::Arc::new(vec![9u8; 4]),
        w: 1920,
        h: 1080,
    };
    let out = stamped(&frame);
    // 1920 = 0x780, 1080 = 0x438, little-endian, four bytes each.
    assert_eq!(&out[..8], &[0x80, 0x07, 0x00, 0x00, 0x38, 0x04, 0x00, 0x00]);
    assert_eq!(&out[8..], &[9, 9, 9, 9]);
    assert_eq!(out.len(), 8 + 4);
}

#[test]
fn a_frame_of_nothing_is_still_the_right_shape() {
    let frame = Frame {
        bytes: std::sync::Arc::new(Vec::new()),
        w: 0,
        h: 0,
    };
    // Zero is what the window reads as "this is not a frame", and it refuses it rather than
    // painting a guess -- so the shape has to survive even when there is nothing in it.
    assert_eq!(stamped(&frame), vec![0u8; 8]);
}
