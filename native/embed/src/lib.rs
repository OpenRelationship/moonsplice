// moonsplice-embed: in-process CLIP-family embedding inference (ONNX Runtime, no Python).
//
// Spike: proves the no-Python runtime. Loads an OpenCLIP-style ONNX export
// (vision + text encoders, MobileCLIP2-S2 by default) and embeds images/texts
// entirely in-process. CPU EP for now; CoreML EP is the follow-up.
//
// Model dir layout (RuteNL/MobileCLIP2-S2-OpenCLIP-ONNX convention):
//   visual.onnx (+ visual.onnx.data)   vision encoder
//   text.onnx   (+ text.onnx.data)     text encoder
//   tokenizer.json                     HF tokenizers file
//   open_clip_config.json              image_size / mean / std / context_length / embed_dim
//   model_config.json                  pad_id, lowercase flag
//
// C ABI:
//   ee_init(models_dir)                          -> 0 | -1
//   ee_dim()                                     -> embed dim | -1
//   ee_embed_text(text, out, dim)                -> 0 | -1   (L2-normalized)
//   ee_embed_image(rgba, w, h, out, dim)         -> 0 | -1   (L2-normalized)

use ort::session::{builder::GraphOptimizationLevel, Session};
use ort::value::Tensor;
use serde::Deserialize;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::Mutex;
use tokenizers::{PaddingParams, PaddingStrategy, Tokenizer, TruncationParams};

// ---------- config ----------

#[derive(Deserialize)]
struct VisionCfg {
    image_size: u32,
}

#[derive(Deserialize)]
struct TextCfg {
    context_length: usize,
}

#[derive(Deserialize)]
struct ModelCfg {
    embed_dim: usize,
    vision_cfg: VisionCfg,
    text_cfg: TextCfg,
}

#[derive(Deserialize)]
struct PreprocessCfg {
    mean: [f32; 3],
    std: [f32; 3],
}

#[derive(Deserialize)]
struct OpenClipConfig {
    model_cfg: ModelCfg,
    preprocess_cfg: PreprocessCfg,
}

#[derive(Deserialize)]
struct ModelConfig {
    #[serde(default)]
    pad_id: Option<u32>,
    #[serde(default)]
    tokenizer_needs_lowercase: bool,
}

// ---------- engine ----------

struct Engine {
    vision: Session,
    text: Session,
    tokenizer: Tokenizer,
    dim: usize,
    image_size: u32,
    context_length: usize,
    mean: [f32; 3],
    std: [f32; 3],
    lowercase: bool,
    vision_input: String,
    text_ids_input: String,
    text_mask_input: Option<String>,
}

static ENGINE: Mutex<Option<Engine>> = Mutex::new(None);

fn find_input(session: &Session, wanted: &[&str]) -> Option<String> {
    for w in wanted {
        if session.inputs().iter().any(|i| i.name() == *w) {
            return Some((*w).to_string());
        }
    }
    None
}

fn init_engine(models_dir: &Path) -> Result<Engine, String> {
    let occ: OpenClipConfig = serde_json::from_str(
        &std::fs::read_to_string(models_dir.join("open_clip_config.json"))
            .map_err(|e| format!("open_clip_config.json: {e}"))?,
    )
    .map_err(|e| format!("open_clip_config.json parse: {e}"))?;
    let mc: ModelConfig = serde_json::from_str(
        &std::fs::read_to_string(models_dir.join("model_config.json"))
            .map_err(|e| format!("model_config.json: {e}"))?,
    )
    .map_err(|e| format!("model_config.json parse: {e}"))?;

    let build = |file: &str| -> Result<Session, String> {
        let threads = std::thread::available_parallelism().map_or(4, |n| n.get());
        (|| -> Result<Session, ort::Error> {
            Ok(Session::builder()?
                .with_optimization_level(GraphOptimizationLevel::Level3)?
                .with_intra_threads(threads)?
                .commit_from_file(models_dir.join(file))?)
        })()
        .map_err(|e| format!("{file}: {e}"))
    };
    let vision = build("visual.onnx")?;
    let text = build("text.onnx")?;

    let vision_input = find_input(&vision, &["pixel_values", "input", "image"])
        .or_else(|| vision.inputs().first().map(|i| i.name().to_string()))
        .ok_or("vision model has no inputs")?;
    let text_ids_input = find_input(&text, &["input_ids", "text", "input"])
        .or_else(|| text.inputs().first().map(|i| i.name().to_string()))
        .ok_or("text model has no inputs")?;
    let text_mask_input = find_input(&text, &["attention_mask"]);

    let ctx_len = occ.model_cfg.text_cfg.context_length;
    let mut tokenizer = Tokenizer::from_file(models_dir.join("tokenizer.json"))
        .map_err(|e| format!("tokenizer.json: {e}"))?;
    let pad_id = mc.pad_id.unwrap_or(0);
    tokenizer.with_padding(Some(PaddingParams {
        strategy: PaddingStrategy::Fixed(ctx_len),
        pad_id,
        ..Default::default()
    }));
    tokenizer
        .with_truncation(Some(TruncationParams {
            max_length: ctx_len,
            ..Default::default()
        }))
        .map_err(|e| format!("tokenizer truncation: {e}"))?;

    Ok(Engine {
        vision,
        text,
        tokenizer,
        dim: occ.model_cfg.embed_dim,
        image_size: occ.model_cfg.vision_cfg.image_size,
        context_length: ctx_len,
        mean: occ.preprocess_cfg.mean,
        std: occ.preprocess_cfg.std,
        lowercase: mc.tokenizer_needs_lowercase,
        vision_input,
        text_ids_input,
        text_mask_input,
    })
}

fn l2_normalize(v: &mut [f32]) {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if n > 0.0 {
        for x in v.iter_mut() {
            *x /= n;
        }
    }
}

// Bilinear resize (shortest side -> S) + center crop S x S + (p/255 - mean)/std, NCHW.
fn preprocess_rgba(rgba: &[u8], w: u32, h: u32, s: u32, mean: [f32; 3], std: [f32; 3]) -> Vec<f32> {
    let (w, h, s) = (w as usize, h as usize, s as usize);
    let scale = s as f32 / w.min(h) as f32;
    let sw = ((w as f32 * scale).round() as usize).max(s);
    let sh = ((h as f32 * scale).round() as usize).max(s);
    let x0 = (sw - s) / 2;
    let y0 = (sh - s) / 2;

    let mut out = vec![0f32; 3 * s * s];
    let plane = s * s;
    for oy in 0..s {
        // dst pixel center in scaled space -> src coords
        let fy = ((y0 + oy) as f32 + 0.5) / scale - 0.5;
        let fy = fy.clamp(0.0, (h - 1) as f32);
        let iy0 = fy.floor() as usize;
        let iy1 = (iy0 + 1).min(h - 1);
        let dy = fy - iy0 as f32;
        for ox in 0..s {
            let fx = ((x0 + ox) as f32 + 0.5) / scale - 0.5;
            let fx = fx.clamp(0.0, (w - 1) as f32);
            let ix0 = fx.floor() as usize;
            let ix1 = (ix0 + 1).min(w - 1);
            let dx = fx - ix0 as f32;

            let p00 = (iy0 * w + ix0) * 4;
            let p01 = (iy0 * w + ix1) * 4;
            let p10 = (iy1 * w + ix0) * 4;
            let p11 = (iy1 * w + ix1) * 4;
            for c in 0..3 {
                let v = rgba[p00 + c] as f32 * (1.0 - dx) * (1.0 - dy)
                    + rgba[p01 + c] as f32 * dx * (1.0 - dy)
                    + rgba[p10 + c] as f32 * (1.0 - dx) * dy
                    + rgba[p11 + c] as f32 * dx * dy;
                out[c * plane + oy * s + ox] = (v / 255.0 - mean[c]) / std[c];
            }
        }
    }
    out
}

fn embed_text_inner(eng: &mut Engine, text: &str, out: &mut [f32]) -> Result<(), String> {
    let text_owned;
    let text = if eng.lowercase {
        text_owned = text.to_lowercase();
        &text_owned
    } else {
        text
    };
    let enc = eng
        .tokenizer
        .encode(text, true)
        .map_err(|e| format!("tokenize: {e}"))?;
    let ids: Vec<i64> = enc.get_ids().iter().map(|&x| x as i64).collect();
    let ctx = eng.context_length;
    if ids.len() != ctx {
        return Err(format!("tokenizer produced {} ids, expected {ctx}", ids.len()));
    }
    let ids_t = Tensor::from_array(([1usize, ctx], ids)).map_err(|e| e.to_string())?;

    let outputs = if let Some(mask_name) = eng.text_mask_input.clone() {
        let mask: Vec<i64> = enc.get_attention_mask().iter().map(|&x| x as i64).collect();
        let mask_t = Tensor::from_array(([1usize, ctx], mask)).map_err(|e| e.to_string())?;
        eng.text
            .run(ort::inputs![eng.text_ids_input.as_str() => ids_t, mask_name.as_str() => mask_t])
    } else {
        eng.text.run(ort::inputs![eng.text_ids_input.as_str() => ids_t])
    }
    .map_err(|e| format!("text run: {e}"))?;

    let (_, data) = outputs[0]
        .try_extract_tensor::<f32>()
        .map_err(|e| format!("text output: {e}"))?;
    if data.len() < out.len() {
        return Err(format!("text output len {} < dim {}", data.len(), out.len()));
    }
    out.copy_from_slice(&data[..out.len()]);
    l2_normalize(out);
    Ok(())
}

fn embed_image_inner(eng: &mut Engine, rgba: &[u8], w: u32, h: u32, out: &mut [f32]) -> Result<(), String> {
    let s = eng.image_size;
    let pixels = preprocess_rgba(rgba, w, h, s, eng.mean, eng.std);
    let t = Tensor::from_array(([1usize, 3, s as usize, s as usize], pixels)).map_err(|e| e.to_string())?;
    let outputs = eng
        .vision
        .run(ort::inputs![eng.vision_input.as_str() => t])
        .map_err(|e| format!("vision run: {e}"))?;
    let (_, data) = outputs[0]
        .try_extract_tensor::<f32>()
        .map_err(|e| format!("vision output: {e}"))?;
    if data.len() < out.len() {
        return Err(format!("vision output len {} < dim {}", data.len(), out.len()));
    }
    out.copy_from_slice(&data[..out.len()]);
    l2_normalize(out);
    Ok(())
}

// ---------- C ABI ----------

#[no_mangle]
pub extern "C" fn ee_init(models_dir: *const c_char) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let dir = unsafe { CStr::from_ptr(models_dir) }.to_str().ok()?;
        match init_engine(Path::new(dir)) {
            Ok(eng) => {
                *ENGINE.lock().unwrap() = Some(eng);
                Some(())
            }
            Err(e) => {
                eprintln!("moonsplice-embed: init failed: {e}");
                None
            }
        }
    }));
    match result {
        Ok(Some(())) => 0,
        _ => -1,
    }
}

#[no_mangle]
pub extern "C" fn ee_dim() -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        ENGINE.lock().unwrap().as_ref().map(|e| e.dim as i32)
    }));
    match result {
        Ok(Some(d)) => d,
        _ => -1,
    }
}

#[no_mangle]
pub extern "C" fn ee_embed_text(text: *const c_char, out: *mut f32, dim: usize) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let text = unsafe { CStr::from_ptr(text) }.to_str().ok()?;
        let mut guard = ENGINE.lock().unwrap();
        let eng = guard.as_mut()?;
        if dim != eng.dim {
            eprintln!("moonsplice-embed: dim mismatch: got {dim}, model {}", eng.dim);
            return None;
        }
        let out = unsafe { std::slice::from_raw_parts_mut(out, dim) };
        match embed_text_inner(eng, text, out) {
            Ok(()) => Some(()),
            Err(e) => {
                eprintln!("moonsplice-embed: embed_text failed: {e}");
                None
            }
        }
    }));
    match result {
        Ok(Some(())) => 0,
        _ => -1,
    }
}

#[no_mangle]
pub extern "C" fn ee_embed_image(rgba: *const u8, w: u32, h: u32, out: *mut f32, dim: usize) -> i32 {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if rgba.is_null() || w == 0 || h == 0 {
            return None;
        }
        let mut guard = ENGINE.lock().unwrap();
        let eng = guard.as_mut()?;
        if dim != eng.dim {
            eprintln!("moonsplice-embed: dim mismatch: got {dim}, model {}", eng.dim);
            return None;
        }
        let n = (w as usize) * (h as usize) * 4;
        let rgba = unsafe { std::slice::from_raw_parts(rgba, n) };
        let out = unsafe { std::slice::from_raw_parts_mut(out, dim) };
        match embed_image_inner(eng, rgba, w, h, out) {
            Ok(()) => Some(()),
            Err(e) => {
                eprintln!("moonsplice-embed: embed_image failed: {e}");
                None
            }
        }
    }));
    match result {
        Ok(Some(())) => 0,
        _ => -1,
    }
}
