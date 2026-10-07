//! moonsplice-track --models DIR --frames F.rgb --width W --height H --count N --box x0,y0,x1,y1
//!               --out M.bin [--device cpu|coreml|cuda] [--units gpu|all|ane]
//! moonsplice-track resize --frames F.rgb --width W --height H --out R.rgb     (1024x1024, PIL bilinear)
//! moonsplice-track serve --models DIR [--device ...] [--units ...]
//!     keeps the sessions loaded (Core ML's cached load is ~2 s a process) and reads one request per
//!     stdin line, `frames width height count x0,y0,x1,y1 out`, answering one JSON line each.
//!
//! Frames: N*H*W*3 bytes of RGB, frame 0 carrying the box (source pixels). Output: N*H*W bytes,
//! 1 = object, in frame order, and M.bin.scores = N little-endian f32 object-score logits.
//! One JSON line on stdout at the end.
use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::time::Instant;

use moonsplice_track::{pil_bilinear, Device, Tracker, Units};

fn main() {
    if let Err(e) = real_main() {
        eprintln!("moonsplice-track: {e}");
        std::process::exit(2);
    }
}

fn real_main() -> Result<(), String> {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mode = match args.first().map(String::as_str) {
        Some("resize") | Some("serve") => args.remove(0),
        _ => String::new(),
    };
    let resize_only = mode == "resize";
    let mut o: HashMap<String, String> = HashMap::new();
    let mut it = args.into_iter();
    while let Some(k) = it.next() {
        let k = k.strip_prefix("--").ok_or(format!("unexpected {k}"))?.to_string();
        o.insert(k.clone(), it.next().ok_or(format!("--{k} needs a value"))?);
    }
    let get = |k: &str| o.get(k).cloned().ok_or(format!("missing --{k}"));
    let num = |k: &str| -> Result<usize, String> { get(k)?.parse().map_err(|_| format!("--{k} is not a number")) };
    let units = match o.get("units").map(String::as_str).unwrap_or("gpu") {
        "gpu" => Units::Gpu,
        "all" => Units::All,
        "ane" => Units::Ane,
        u => return Err(format!("--units {u}: gpu, all or ane")),
    };
    let dev_name = o.get("device").cloned().unwrap_or_else(|| "cpu".into());
    let device = match dev_name.as_str() {
        "cpu" => Device::Cpu,
        "coreml" => Device::CoreMl(units),
        "cuda" => Device::Cuda,
        d => return Err(format!("--device {d}: cpu, coreml or cuda")),
    };
    if mode == "serve" {
        return serve(&PathBuf::from(get("models")?), device, &dev_name);
    }
    let (w, h) = (num("width")?, num("height")?);
    let frames = std::fs::read(get("frames")?).map_err(|e| format!("frames: {e}"))?;

    if resize_only {
        let r = pil_bilinear(&frames[..w * h * 3], w, h, 1024, 1024);
        return std::fs::write(get("out")?, r).map_err(|e| e.to_string());
    }

    let n = num("count")?;
    if frames.len() != n * w * h * 3 {
        return Err(format!("frames file is {} bytes, want {}", frames.len(), n * w * h * 3));
    }
    let b: Vec<f32> = get("box")?.split(',').map(|v| v.parse::<f32>()).collect::<Result<_, _>>()
        .map_err(|_| "--box is x0,y0,x1,y1".to_string())?;
    if b.len() != 4 {
        return Err("--box is x0,y0,x1,y1".into());
    }
    let t0 = Instant::now();
    let mut tr = Tracker::load(&PathBuf::from(get("models")?), device)?;
    let load = t0.elapsed().as_secs_f64();
    let secs = track_one(&mut tr, &frames, w, h, n, [b[0], b[1], b[2], b[3]], &get("out")?)?;
    println!("{{\"frames\": {n}, \"load_seconds\": {load:.3}, \"track_seconds\": {secs:.3}, \"seconds_per_frame\": {:.4}, \"device\": \"{dev_name}\"}}",
             secs / n as f64);
    Ok(())
}

fn track_one(tr: &mut Tracker, frames: &[u8], w: usize, h: usize, n: usize, b: [f32; 4], out_path: &str)
    -> Result<f64, String> {
    if frames.len() != n * w * h * 3 {
        return Err(format!("frames file is {} bytes, want {}", frames.len(), n * w * h * 3));
    }
    let mut out = std::io::BufWriter::new(std::fs::File::create(out_path).map_err(|e| e.to_string())?);
    let mut scores = Vec::with_capacity(n * 4);
    let t1 = Instant::now();
    let fs = w * h * 3;
    tr.track(n, w, h, b, |i| frames[i * fs..(i + 1) * fs].to_vec(), |_, m| {
        out.write_all(&m.mask).map_err(|e| e.to_string())?;
        scores.extend_from_slice(&m.score.to_le_bytes());
        Ok(())
    })?;
    out.flush().map_err(|e| e.to_string())?;
    std::fs::write(format!("{out_path}.scores"), scores).map_err(|e| e.to_string())?;
    Ok(t1.elapsed().as_secs_f64())
}

fn serve(models: &std::path::Path, device: Device, dev_name: &str) -> Result<(), String> {
    use std::io::BufRead;
    let t0 = Instant::now();
    let mut tr = Tracker::load(models, device)?;
    let mut stdout = std::io::stdout();
    writeln!(stdout, "{{\"ready\": true, \"load_seconds\": {:.3}, \"device\": \"{dev_name}\"}}", t0.elapsed().as_secs_f64())
        .and_then(|_| stdout.flush()).map_err(|e| e.to_string())?;
    for line in std::io::stdin().lock().lines() {
        let line = line.map_err(|e| e.to_string())?;
        if line.trim().is_empty() {
            continue;
        }
        let res = (|| -> Result<String, String> {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() != 6 {
                return Err("want: frames width height count x0,y0,x1,y1 out".into());
            }
            let p = |s: &str| s.parse::<usize>().map_err(|_| format!("{s} is not a number"));
            let (w, h, n) = (p(f[1])?, p(f[2])?, p(f[3])?);
            let b: Vec<f32> = f[4].split(',').map(|v| v.parse::<f32>()).collect::<Result<_, _>>()
                .map_err(|_| "box is x0,y0,x1,y1".to_string())?;
            if b.len() != 4 {
                return Err("box is x0,y0,x1,y1".into());
            }
            let frames = std::fs::read(f[0]).map_err(|e| format!("frames: {e}"))?;
            let secs = track_one(&mut tr, &frames, w, h, n, [b[0], b[1], b[2], b[3]], f[5])?;
            Ok(format!("{{\"frames\": {n}, \"track_seconds\": {secs:.3}}}"))
        })();
        let reply = match res {
            Ok(s) => s,
            Err(e) => format!("{{\"error\": {:?}}}", e),
        };
        writeln!(stdout, "{reply}").and_then(|_| stdout.flush()).map_err(|e| e.to_string())?;
    }
    Ok(())
}
