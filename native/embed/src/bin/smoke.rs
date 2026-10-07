// smoke: extract one frame from the dubbing promo, embed it + three texts
// through the C ABI, print cosines and latency.

use std::ffi::CString;
use std::process::Command;
use std::time::Instant;

use moonsplice_embed::{ee_dim, ee_embed_image, ee_embed_text, ee_init};

const VIDEO: &str = "/Users/shinyobjectz/11l/moonsplice/examples/dubbing_promo_v4.mp4";
const T: f64 = 12.0;

fn video_dims(path: &str) -> (u32, u32) {
    let out = Command::new("ffprobe")
        .args([
            "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
            "-of", "csv=s=x:p=0", path,
        ])
        .output()
        .expect("ffprobe");
    let s = String::from_utf8_lossy(&out.stdout);
    let mut it = s.trim().split('x');
    (
        it.next().unwrap().parse().expect("width"),
        it.next().unwrap().parse().expect("height"),
    )
}

fn extract_rgba(path: &str, t: f64, w: u32, h: u32) -> Vec<u8> {
    let out = Command::new("ffmpeg")
        .args([
            "-v", "error", "-ss", &t.to_string(), "-i", path,
            "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "-",
        ])
        .output()
        .expect("ffmpeg");
    let want = (w * h * 4) as usize;
    assert_eq!(out.stdout.len(), want, "raw frame size mismatch");
    out.stdout
}

fn cosine(a: &[f32], b: &[f32]) -> f32 {
    // embeddings are L2-normalized: cosine == dot
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

fn main() {
    let models_dir = std::env::args().nth(1).unwrap_or_else(|| {
        format!(
            "{}/.cache/moonsplice/models/mobileclip2-s2",
            std::env::var("HOME").unwrap()
        )
    });

    let t0 = Instant::now();
    let cdir = CString::new(models_dir.clone()).unwrap();
    assert_eq!(ee_init(cdir.as_ptr()), 0, "ee_init failed");
    let dim = ee_dim();
    assert!(dim > 0, "ee_dim failed");
    let dim = dim as usize;
    println!("init: {:?}  dim={dim}  models={models_dir}", t0.elapsed());

    let (w, h) = video_dims(VIDEO);
    let rgba = extract_rgba(VIDEO, T, w, h);
    println!("frame: {w}x{h} @ t={T}s ({} bytes rgba)", rgba.len());

    let mut img = vec![0f32; dim];
    let t1 = Instant::now();
    assert_eq!(
        ee_embed_image(rgba.as_ptr(), w, h, img.as_mut_ptr(), dim),
        0,
        "ee_embed_image failed"
    );
    println!("first image embed: {:?}", t1.elapsed());

    let texts = [
        "a video player interface with people",
        "a red sports car",
        "minimal white design",
    ];
    let mut txt_embs: Vec<Vec<f32>> = Vec::new();
    for t in &texts {
        let ct = CString::new(*t).unwrap();
        let mut e = vec![0f32; dim];
        let t2 = Instant::now();
        assert_eq!(
            ee_embed_text(ct.as_ptr(), e.as_mut_ptr(), dim),
            0,
            "ee_embed_text failed for {t:?}"
        );
        println!("text embed {:?}: {:?}", t, t2.elapsed());
        txt_embs.push(e);
    }

    println!("\ncosine(frame, text):");
    for (t, e) in texts.iter().zip(&txt_embs) {
        println!("  {:<40} {:+.4}", t, cosine(&img, e));
    }

    // latency: 100 image embeds
    let n = 100;
    let t3 = Instant::now();
    for _ in 0..n {
        ee_embed_image(rgba.as_ptr(), w, h, img.as_mut_ptr(), dim);
    }
    let per = t3.elapsed() / n;
    println!("\nimage embed latency ({n} runs, incl. preprocess): {per:?}/embed");

    let ct = CString::new(texts[0]).unwrap();
    let t4 = Instant::now();
    for _ in 0..n {
        ee_embed_text(ct.as_ptr(), img.as_mut_ptr(), dim);
    }
    println!("text embed latency ({n} runs): {:?}/embed", t4.elapsed() / n);
}
