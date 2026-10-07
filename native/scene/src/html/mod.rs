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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::path::Path;

    fn px(buf: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
        let i = ((y * w + x) * 4) as usize;
        [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
    }

    #[test]
    fn fragment_inline_css_still_paints() {
        let html = r#"<div style="width:100%;height:100%;background:#151c2c"></div>"#;
        let buf = paint(html, None, 64, 32, 1.0, false).expect("fragment paint");
        assert_eq!(buf.len(), 64 * 32 * 4);
    }

    #[test]
    fn page_loads_linked_css_and_image() {
        let dir = std::env::temp_dir().join(format!("moonsplice-html-page-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("style.css"),
            "html,body{margin:0;background:#0b1220}\
             .hero{width:100%;height:40px;background:#3ee0c6}\
             img{display:block;width:16px;height:16px}",
        )
        .unwrap();
        // 1×1 opaque red PNG.
        let png: &[u8] = &[
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00,
            0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08,
            0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xfe,
            0xd4, 0xef, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
        ];
        fs::write(dir.join("mark.png"), png).unwrap();
        let mut index = fs::File::create(dir.join("index.html")).unwrap();
        write!(
            index,
            "<!DOCTYPE html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head>\
             <body><div class=\"hero\"></div><img src=\"mark.png\" alt=\"\"></body></html>"
        )
        .unwrap();

        let html = fs::read_to_string(dir.join("index.html")).unwrap();
        let base = dir.join("index.html").to_string_lossy().into_owned();
        let buf = paint(&html, Some(&base), 80, 80, 1.0, false).expect("page paint");
        let hero = px(&buf, 80, 40, 10);
        assert!(
            hero[1] > 160 && hero[2] > 140 && hero[0] < 120,
            "linked CSS should paint teal hero, got {hero:?}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn page_woff2_font_face_changes_glyphs() {
        let woff = Path::new(env!("CARGO_MANIFEST_DIR")).join("../evals/assets/page/face.woff2");
        if !woff.exists() {
            eprintln!("skip font-face: {} missing", woff.display());
            return;
        }
        let dir = std::env::temp_dir().join(format!("moonsplice-html-font-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::copy(&woff, dir.join("face.woff2")).unwrap();
        let html = r#"<!DOCTYPE html><html><head>
<style>
@font-face { font-family: "MoonspliceFace"; src: url("face.woff2") format("woff2"); }
html,body { margin:0; background:#0b1220; }
.a { font-family: MoonspliceFace, monospace; font-size: 64px; color:#e8edf7; }
.b { font-family: Helvetica, Arial, sans-serif; font-size: 64px; color:#e8edf7; }
</style></head><body>
<div class="a">Ill</div>
</body></html>"#;
        let html_sans = html.replace("MoonspliceFace, monospace", "Helvetica, Arial, sans-serif");
        let base = dir.join("index.html").to_string_lossy().into_owned();
        let with_face = paint(html, Some(&base), 240, 80, 1.0, false).expect("font paint");
        let sans = paint(&html_sans, Some(&base), 240, 80, 1.0, false).expect("sans paint");
        assert_ne!(
            with_face, sans,
            "woff2 @font-face should change glyph pixels vs Helvetica"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn bake_runs_script_then_paints() {
        let html = r#"<!DOCTYPE html><html><head>
<style>
html,body{margin:0;background:#0b1220}
h1{margin:0;font-size:48px;color:#ff3366;font-family:Helvetica,Arial,sans-serif}
.ready h1{color:#3ee0c6}
</style></head>
<body>
<h1 id="title">loading</h1>
<script>
document.getElementById("title").textContent = "Baked";
document.body.classList.add("ready");
</script>
</body></html>"#;
        let baked = paint(html, Some(""), 200, 80, 1.0, true).expect("bake paint");
        let raw = paint(html, Some(""), 200, 80, 1.0, false).expect("raw paint");
        assert_ne!(baked, raw, "script bake should change pixels");
        let dumped = crate::bake::bake(html, None).expect("dump");
        assert!(dumped.contains("Baked"), "dumped DOM: {dumped}");
        assert!(!dumped.contains("loading"), "dumped DOM still has loading");
        assert!(dumped.contains("ready"), "body class missing: {dumped}");
    }
}
