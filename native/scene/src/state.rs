//! The renderer's one state: fonts and the layout context, the paint context, image slots and
//! Lottie compositions; and the reader over the command stream.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use anyrender::ResourceId;
use parley::fontique::{Blob, CollectionOptions, FontInfoOverride};
use parley::{FontContext, Layout, LayoutContext};
use vello_common::paint::ImageId;
use vello_cpu::color::{AlphaColor, Srgb};
use vello_cpu::{RenderContext, Resources};

const DEFAULT_FONT: &[u8] = include_bytes!("../fonts/NotoSans-Regular.ttf");

#[derive(Clone, PartialEq, Default, Debug)]
pub(crate) struct Brush(pub(crate) [f32; 4]);

pub(crate) struct State {
    pub(crate) fcx: FontContext,
    pub(crate) lcx: LayoutContext<Brush>,
    pub(crate) families: Vec<String>,
    pub(crate) by_path: HashMap<String, i32>,
    pub(crate) ctx: Option<(u16, u16, u16, RenderContext)>,
    pub(crate) res: Resources,
    pub(crate) layout: Layout<Brush>,
    pub(crate) cache: HashMap<String, Layout<Brush>>,
    /// Image slots as the stream names them, and what each slot is to the CPU painter.
    pub(crate) images: Vec<(ResourceId, u16, u16)>,
    pub(crate) ids: HashMap<ResourceId, ImageId>,
    /// Lottie compositions as the stream names them (opcode 116).
    pub(crate) lotties: Vec<velato::Composition>,
}

pub(crate) fn state() -> &'static Mutex<State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(|| {
        let mut fcx = FontContext {
            collection: parley::fontique::Collection::new(CollectionOptions {
                shared: false,
                system_fonts: false,
                ..Default::default()
            }),
            source_cache: Default::default(),
        };
        let mut st = State {
            lcx: LayoutContext::new(),
            families: Vec::new(),
            by_path: HashMap::new(),
            ctx: None,
            res: Resources::new(),
            layout: Layout::new(),
            cache: HashMap::new(),
            images: Vec::new(),
            ids: HashMap::new(),
            lotties: Vec::new(),
            fcx: FontContext::new(),
        };
        std::mem::swap(&mut st.fcx, &mut fcx);
        register(&mut st, Arc::new(DEFAULT_FONT.to_vec()));
        Mutex::new(st)
    })
}

pub(crate) fn register(st: &mut State, bytes: Arc<Vec<u8>>) -> i32 {
    let id = st.families.len() as i32;
    let name = format!("moonsplice-font-{id}");
    let blob = Blob::new(bytes);
    let fams = st.fcx.collection.register_fonts(
        blob,
        Some(FontInfoOverride { family_name: Some(&name), ..Default::default() }),
    );
    if fams.is_empty() {
        return -1;
    }
    st.families.push(name);
    id
}

pub(crate) fn color(r: f32, g: f32, b: f32, a: f32) -> AlphaColor<Srgb> {
    AlphaColor::<Srgb>::new([r, g, b, a])
}

pub(crate) struct Reader<'a> {
    pub(crate) d: &'a [f32],
    pub(crate) i: usize,
}
impl<'a> Reader<'a> {
    pub(crate) fn next(&mut self) -> Option<f32> {
        let v = self.d.get(self.i).copied();
        self.i += 1;
        v
    }
    pub(crate) fn take<const N: usize>(&mut self) -> Option<[f32; N]> {
        let mut out = [0f32; N];
        for s in out.iter_mut() {
            *s = self.next()?;
        }
        Some(out)
    }
}
