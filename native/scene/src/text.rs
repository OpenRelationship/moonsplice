//! Text: a run of styled strings shaped and broken into lines (cached, since comps draw the same
//! strings every frame), then drawn as glyphs.

use anyrender::{Glyph, PaintScene, Scene};
use parley::{Alignment, AlignmentOptions, FontFamily, FontStyle, FontWeight, LineHeight, PositionedLayoutItem, StyleProperty};
use vello_cpu::kurbo::{Affine, BezPath, Shape, Stroke, Vec2};
use vello_cpu::peniko::{Fill, FontData};

use crate::state::{color, Brush, State};

pub(crate) struct TextRun<'a> {
    pub(crate) text: &'a str,
    pub(crate) color: [f32; 4],
    pub(crate) bold: bool,
    pub(crate) italic: bool,
}

pub(crate) struct TextSpec<'a> {
    pub(crate) font: usize,
    pub(crate) size: f32,
    pub(crate) ls: f32,
    pub(crate) wrap: f32,
    pub(crate) leading: f32,
    pub(crate) align: i32,
    pub(crate) runs: Vec<TextRun<'a>>,
}

fn spec_key(spec: &TextSpec) -> String {
    let mut k = format!("{}|{}|{}|{}|{}|{}", spec.font, spec.size, spec.ls, spec.wrap, spec.leading, spec.align);
    for r in &spec.runs {
        k.push('\u{1}');
        k.push_str(r.text);
        k.push_str(&format!("|{:?}|{}|{}", r.color, r.bold, r.italic));
    }
    k
}

// Shaping + line breaking is the expensive half of text; comps re-draw the same
// strings every frame, so keep built layouts (bounded) and swap them in.
pub(crate) fn build_layout(st: &mut State, spec: &TextSpec) {
    let key = spec_key(spec);
    if let Some(l) = st.cache.get(&key) {
        st.layout = l.clone();
        return;
    }
    build_layout_uncached(st, spec);
    if st.cache.len() > 4096 {
        st.cache.clear();
    }
    st.cache.insert(key, st.layout.clone());
}

fn build_layout_uncached(st: &mut State, spec: &TextSpec) {
    let State { fcx, lcx, families, layout, .. } = st;
    let mut text = String::new();
    let mut ranges = Vec::with_capacity(spec.runs.len());
    for r in &spec.runs {
        let s = text.len();
        text.push_str(r.text);
        ranges.push(s..text.len());
    }
    let family = families.get(spec.font).cloned().unwrap_or_else(|| families[0].clone());
    let mut b = lcx.ranged_builder(fcx, &text, 1.0, false);
    b.push_default(FontFamily::named(&family));
    b.push_default(StyleProperty::FontSize(spec.size));
    b.push_default(StyleProperty::LetterSpacing(spec.ls));
    b.push_default(StyleProperty::LineHeight(if spec.leading > 0.0 {
        LineHeight::MetricsRelative(spec.leading)
    } else {
        LineHeight::MetricsRelative(1.0)
    }));
    b.push_default(StyleProperty::Brush(Brush([1.0, 1.0, 1.0, 1.0])));
    for (r, range) in spec.runs.iter().zip(ranges) {
        b.push(StyleProperty::Brush(Brush(r.color)), range.clone());
        if r.bold {
            b.push(StyleProperty::FontWeight(FontWeight::BOLD), range.clone());
        }
        if r.italic {
            b.push(StyleProperty::FontStyle(FontStyle::Italic), range.clone());
        }
    }
    b.build_into(layout, &text);
    layout.break_all_lines(if spec.wrap > 0.0 { Some(spec.wrap) } else { None });
    let al = match spec.align {
        1 => Alignment::Center,
        2 => Alignment::End,
        _ => Alignment::Start,
    };
    layout.align(al, AlignmentOptions::default());
}

pub(crate) fn draw_text(
    st: &State,
    sc: &mut Scene,
    base: Affine,
    x: f32,
    y: f32,
    outline: (f32, [f32; 4]),
    embolden: f32,
) {
    let xf = base * Affine::translate((x as f64, y as f64));
    for line in st.layout.lines() {
        for item in line.items() {
            let PositionedLayoutItem::GlyphRun(gr) = item else { continue };
            let run = gr.run();
            let font: &FontData = run.font();
            let size = run.font_size();
            let skew = run.synthesis().skew().map(|a| Affine::skew((a.to_radians()).tan() as f64, 0.0));
            let emb = if run.synthesis().embolden() { size * 0.03 } else { 0.0 } + embolden;
            let glyphs = gr.positioned_glyphs().map(|g| Glyph { id: g.id, x: g.x, y: g.y }).collect::<Vec<_>>();
            if outline.0 > 0.0 {
                let c = outline.1;
                sc.draw_glyphs(font, size, false, run.normalized_coords(), Vec2::ZERO,
                    &Stroke::new(outline.0 as f64), color(c[0], c[1], c[2], c[3]), 1.0, xf, skew, glyphs.iter().copied());
            }
            let c = gr.style().brush.0;
            sc.draw_glyphs(font, size, true, run.normalized_coords(), Vec2::new(emb as f64, emb as f64 * 0.8),
                Fill::NonZero, color(c[0], c[1], c[2], c[3]), 1.0, xf, skew, glyphs.iter().copied());
        }
    }
}

/// Whether two closed paths wind the same way (signed area has the same sign).
pub(crate) fn hole_winds_like(a: &BezPath, b: &BezPath) -> bool {
    (a.area() > 0.0) == (b.area() > 0.0)
}
