// moonsplice-layout: Taffy flexbox solver behind a tiny C ABI, for compile-time
// layout of scene children (s:flex containers). Solved once at resolve — the
// render loop never sees Taffy, so seek-safety is untouched.
//
// C ABI (all f32; NaN = auto):
//   el_flex_solve(container: *const ElContainer,
//                 items: *const ElItem, n: usize,
//                 out: *mut f32 /* n*4: x,y,w,h relative to container */) -> 0 | -1

use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use taffy::prelude::*;

#[repr(C)]
pub struct ElContainer {
    pub width: f32,
    pub height: f32,
    pub direction: c_int, // 0 row, 1 column
    pub justify: c_int,   // 0 start, 1 center, 2 end, 3 space-between, 4 space-around, 5 space-evenly
    pub align: c_int,     // 0 start, 1 center, 2 end, 3 stretch
    pub gap: f32,
    pub padding: f32,
    pub wrap: c_int, // 0 nowrap, 1 wrap
}

#[repr(C)]
pub struct ElItem {
    pub width: f32,  // NaN = auto
    pub height: f32, // NaN = auto
    pub grow: f32,
    pub shrink: f32,
    pub margin: f32,
}

fn dim(v: f32) -> Dimension {
    if v.is_nan() { Dimension::auto() } else { Dimension::length(v) }
}

#[no_mangle]
pub extern "C" fn el_flex_solve(
    container: *const ElContainer,
    items: *const ElItem,
    n: usize,
    out: *mut f32,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| -> Option<()> {
        let c = unsafe { &*container };
        let items = unsafe { std::slice::from_raw_parts(items, n) };
        let out = unsafe { std::slice::from_raw_parts_mut(out, n * 4) };

        let mut tree: TaffyTree<()> = TaffyTree::new();
        let mut children = Vec::with_capacity(n);
        for it in items {
            let style = Style {
                size: Size { width: dim(it.width), height: dim(it.height) },
                flex_grow: it.grow,
                flex_shrink: it.shrink,
                margin: Rect {
                    left: LengthPercentageAuto::length(it.margin),
                    right: LengthPercentageAuto::length(it.margin),
                    top: LengthPercentageAuto::length(it.margin),
                    bottom: LengthPercentageAuto::length(it.margin),
                },
                ..Default::default()
            };
            children.push(tree.new_leaf(style).ok()?);
        }

        let root_style = Style {
            size: Size { width: dim(c.width), height: dim(c.height) },
            flex_direction: if c.direction == 1 { FlexDirection::Column } else { FlexDirection::Row },
            justify_content: Some(match c.justify {
                1 => JustifyContent::Center,
                2 => JustifyContent::End,
                3 => JustifyContent::SpaceBetween,
                4 => JustifyContent::SpaceAround,
                5 => JustifyContent::SpaceEvenly,
                _ => JustifyContent::Start,
            }),
            align_items: Some(match c.align {
                1 => AlignItems::Center,
                2 => AlignItems::End,
                3 => AlignItems::Stretch,
                _ => AlignItems::Start,
            }),
            gap: Size { width: LengthPercentage::length(c.gap), height: LengthPercentage::length(c.gap) },
            padding: Rect {
                left: LengthPercentage::length(c.padding),
                right: LengthPercentage::length(c.padding),
                top: LengthPercentage::length(c.padding),
                bottom: LengthPercentage::length(c.padding),
            },
            flex_wrap: if c.wrap == 1 { FlexWrap::Wrap } else { FlexWrap::NoWrap },
            ..Default::default()
        };
        let root = tree.new_with_children(root_style, &children).ok()?;
        tree.compute_layout(root, Size::MAX_CONTENT).ok()?;

        for (i, child) in children.iter().enumerate() {
            let l = tree.layout(*child).ok()?;
            out[i * 4] = l.location.x;
            out[i * 4 + 1] = l.location.y;
            out[i * 4 + 2] = l.size.width;
            out[i * 4 + 3] = l.size.height;
        }
        Some(())
    }));
    match result {
        Ok(Some(())) => 0,
        _ => -1,
    }
}
