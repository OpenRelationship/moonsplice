// Paint tests: a fragment, a page with linked CSS and an image, a woff2 @font-face, and a script bake.

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
    let dumped = super::bake::bake(html, None).expect("dump");
    assert!(dumped.contains("Baked"), "dumped DOM: {dumped}");
    assert!(!dumped.contains("loading"), "dumped DOM still has loading");
    assert!(dumped.contains("ready"), "body class missing: {dumped}");
}
