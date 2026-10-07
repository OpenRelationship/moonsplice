// html: Blitz (Stylo CSS + Taffy) headless HTML→pixels, painted by the scene's own CPU painter.
// Folded in from the moonsplice-html crate; behind the `html` feature so Blitz stays fenced here.
//
// Three rungs, same dylib:
//   Fragment — el_html_render: inline CSS snippets, no network. Unchanged ABI.
//   Page     — el_html_render_page: base URL + blocking NetProvider so linked
//              CSS/images/fonts resolve. woff2/woff decode to sfnt for Parley.
//   Bake     — classic <script> runs once (QuickJS + tiny document), dump HTML, paint.
//              Never during evaluate(t). StarlingMonkey still has no document;
//              this crate supplies one.
//
// Output premultiplied RGBA. Full parse+style+layout+paint per call.

mod bake;
#[cfg(test)]
mod tests;


use blitz_dom::DocumentConfig;
use blitz_html::HtmlDocument;
use blitz_paint::paint_scene;
use blitz_traits::net::{Bytes, NetHandler, NetProvider, Request};
use blitz_traits::shell::{ColorScheme, Viewport};
use data_url::DataUrl;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use url::Url;

const USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36";
const FETCH_TIMEOUT: Duration = Duration::from_secs(20);
const RESOLVE_PASSES: usize = 32;

struct BlockingNet {
    fetches: AtomicUsize,
}

impl BlockingNet {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            fetches: AtomicUsize::new(0),
        })
    }
}

impl NetProvider for BlockingNet {
    fn fetch(&self, _doc_id: usize, request: Request, handler: Box<dyn NetHandler>) {
        self.fetches.fetch_add(1, Ordering::SeqCst);
        match load_request(&request) {
            Ok((resolved, bytes)) => handler.bytes(resolved, bytes),
            Err(err) => eprintln!("moonsplice-html: fetch {} failed: {err}", request.url),
        }
    }
}

pub(crate) fn load_url(url: &Url) -> Result<(String, Bytes), String> {
    let mut body = match url.scheme() {
        "data" => {
            let data = DataUrl::process(url.as_str()).map_err(|e| format!("{e:?}"))?;
            let (body, _) = data.decode_to_vec().map_err(|e| format!("{e:?}"))?;
            body
        }
        "file" => {
            let path = url
                .to_file_path()
                .map_err(|_| format!("bad file url {url}"))?;
            std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?
        }
        "http" | "https" => {
            let resp = ureq::get(url.as_str())
                .set("User-Agent", USER_AGENT)
                .timeout(FETCH_TIMEOUT)
                .call()
                .map_err(|e| e.to_string())?;
            let mut body = Vec::new();
            resp.into_reader()
                .read_to_end(&mut body)
                .map_err(|e| e.to_string())?;
            body
        }
        other => return Err(format!("unsupported scheme {other}")),
    };
    body = decode_font_bytes(&body);
    Ok((url.to_string(), Bytes::from(body)))
}

fn load_request(request: &Request) -> Result<(String, Bytes), String> {
    load_url(&request.url)
}

/// Parley wants sfnt. Decode WOFF/WOFF2 so @font-face webfonts paint in Blitz.
fn decode_font_bytes(bytes: &[u8]) -> Vec<u8> {
    if bytes.starts_with(b"wOF2") {
        wuff::decompress_woff2(bytes).unwrap_or_else(|_| bytes.to_vec())
    } else if bytes.starts_with(b"wOFF") {
        wuff::decompress_woff1(bytes).unwrap_or_else(|_| bytes.to_vec())
    } else {
        bytes.to_vec()
    }
}

fn normalize_base(base: &str) -> Option<String> {
    let base = base.trim();
    if base.is_empty() {
        return None;
    }
    if let Ok(url) = Url::parse(base) {
        if matches!(url.scheme(), "http" | "https" | "file" | "data") {
            return Some(url.to_string());
        }
    }
    let path = Path::new(base);
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    Url::from_file_path(&abs)
        .ok()
        .map(|u| u.to_string())
        .or_else(|| Some(format!("file://{}", abs.display())))
}

/// Paint HTML into a premultiplied RGBA buffer of size (w*scale)×(h*scale).
/// `base_url = None` is the fragment path: no net provider (hash-stable).
/// `bake` runs classic scripts once, then paints the dumped DOM.
pub fn paint(
    html: &str,
    base_url: Option<&str>,
    w: u32,
    h: u32,
    scale: f32,
    bake: bool,
) -> Option<Vec<u8>> {
    let owned;
    let html = if bake {
        match bake::bake(html, base_url) {
            Ok(h) => {
                owned = h;
                owned.as_str()
            }
            Err(e) => {
                eprintln!("moonsplice-html: bake failed ({e}); painting source HTML");
                html
            }
        }
    } else {
        html
    };
    let (rw, rh) = ((w as f32 * scale) as u32, (h as f32 * scale) as u32);
    let page = base_url.is_some();
    let net = if page { Some(BlockingNet::new()) } else { None };
    let mut document = HtmlDocument::from_html(
        html,
        DocumentConfig {
            viewport: Some(Viewport::new(
                rw,
                rh,
                scale,
                if page {
                    ColorScheme::Light
                } else {
                    ColorScheme::Dark
                },
            )),
            base_url: base_url.and_then(normalize_base),
            net_provider: net
                .as_ref()
                .map(|n| Arc::clone(n) as Arc<dyn NetProvider>),
            ..Default::default()
        },
    );
    if let Some(net) = net.as_ref() {
        let mut last = 0;
        for _ in 0..RESOLVE_PASSES {
            document.as_mut().resolve(0.0);
            let n = net.fetches.load(Ordering::SeqCst);
            if n == last {
                break;
            }
            last = n;
        }
    } else {
        document.as_mut().resolve(0.0);
    }
    // Blitz paints into the same kind of scene the frame is, and the same painter rasterises it.
    let mut scene = anyrender::Scene::new();
    paint_scene(&mut scene, document.as_mut(), scale as f64, rw, rh, 0, 0);
    Some(crate::paint_cpu_scene(u16::try_from(rw).ok()?, u16::try_from(rh).ok()?, scene).data_as_u8_slice().to_vec())
}

pub fn write_png(path: &str, rgba: &[u8], w: u32, h: u32) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut encoder = png::Encoder::new(file, w, h);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(rgba).map_err(|e| e.to_string())?;
    Ok(())
}

fn cstr<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

fn render_into(
    html: *const c_char,
    base_url: Option<*const c_char>,
    w: u32,
    h: u32,
    scale: f32,
    bake: bool,
    out: *mut u8,
    out_len: usize,
) -> Option<()> {
    let html = cstr(html)?;
    let base = base_url.and_then(cstr);
    let out = unsafe { std::slice::from_raw_parts_mut(out, out_len) };
    let (rw, rh) = ((w as f32 * scale) as u32, (h as f32 * scale) as u32);
    if out_len != (rw * rh * 4) as usize {
        eprintln!(
            "moonsplice-html: buffer size mismatch {} != {}",
            out_len,
            rw * rh * 4
        );
        return None;
    }
    let buffer = paint(html, base, w, h, scale, bake)?;
    if buffer.len() != out_len {
        eprintln!(
            "moonsplice-html: paint size mismatch {} != {}",
            buffer.len(),
            out_len
        );
        return None;
    }
    out.copy_from_slice(&buffer);
    Some(())
}

#[no_mangle]
pub extern "C" fn el_html_render(
    html: *const c_char,
    w: u32,
    h: u32,
    scale: f32,
    out: *mut u8,
    out_len: usize,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| {
        render_into(html, None, w, h, scale, false, out, out_len)
    }));
    match result {
        Ok(Some(())) => 0,
        _ => -1,
    }
}

#[no_mangle]
pub extern "C" fn el_html_render_page(
    html: *const c_char,
    base_url: *const c_char,
    w: u32,
    h: u32,
    scale: f32,
    bake: c_int,
    out: *mut u8,
    out_len: usize,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| {
        render_into(html, Some(base_url), w, h, scale, bake != 0, out, out_len)
    }));
    match result {
        Ok(Some(())) => 0,
        _ => -1,
    }
}

#[no_mangle]
pub extern "C" fn el_html_render_page_png(
    html: *const c_char,
    base_url: *const c_char,
    w: u32,
    h: u32,
    scale: f32,
    bake: c_int,
    path: *const c_char,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| -> Option<()> {
        let html = cstr(html)?;
        let base = cstr(base_url);
        let path = cstr(path)?;
        let (rw, rh) = ((w as f32 * scale) as u32, (h as f32 * scale) as u32);
        let buffer = paint(html, base, w, h, scale, bake != 0)?;
        write_png(path, &buffer, rw, rh).ok()?;
        Some(())
    }));
    match result {
        Ok(Some(())) => 0,
        _ => -1,
    }
}
