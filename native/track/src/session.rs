//! Opening the ONNX graphs (CPU, Core ML or CUDA) and running them, and the small tensor helpers
//! around that.

use std::path::{Path, PathBuf};

#[cfg(any(target_os = "macos", feature = "cuda"))]
use ort::ep;
use ort::session::{builder::GraphOptimizationLevel, Session};
use ort::value::Tensor;

use super::{Err, Units, CUDA, HW};

pub(crate) fn read_f32(p: &Path, n: usize) -> Result<Vec<f32>, Err> {
    let b = std::fs::read(p).map_err(|e| format!("{}: {e}", p.display()))?;
    if b.len() != n * 4 {
        return Err(format!("{}: {} bytes, want {}", p.display(), b.len(), n * 4));
    }
    Ok(b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect())
}

pub(crate) fn session(path: PathBuf, coreml: Option<(Units, &Path)>) -> Result<Session, Err> {
    // MOONSPLICE_TRACK_THREADS overrides the core count, e.g. to share a machine with other models.
    let threads = std::env::var("MOONSPLICE_TRACK_THREADS").ok().and_then(|v| v.parse().ok())
        .unwrap_or_else(|| std::thread::available_parallelism().map_or(4, |n| n.get()));
    (|| -> Result<Session, ort::Error> {
        let mut b = Session::builder()?
            .with_optimization_level(GraphOptimizationLevel::Level3)?
            .with_intra_threads(threads)?;
        if CUDA.load(std::sync::atomic::Ordering::Relaxed) {
            #[cfg(feature = "cuda")]
            {
                // MOONSPLICE_TRACK_CONV_SEARCH=heuristic skips cuDNN's per-shape benchmark;
                // MOONSPLICE_TRACK_TF32=0 keeps fp32 matmuls exact on Ampere and later
                // SameAsRequested: the default arena grows by powers of two and held ~1.7 GB per
                // tracker; several worker slots share one card
                let mut cuda = ep::CUDA::default().with_arena_extend_strategy(ep::ArenaExtendStrategy::SameAsRequested);
                match std::env::var("MOONSPLICE_TRACK_CONV_SEARCH").as_deref() {
                    Ok("heuristic") => cuda = cuda.with_conv_algorithm_search(ep::cuda::ConvAlgorithmSearch::Heuristic),
                    Ok("default") => cuda = cuda.with_conv_algorithm_search(ep::cuda::ConvAlgorithmSearch::Default),
                    _ => {}
                }
                if std::env::var("MOONSPLICE_TRACK_TF32").as_deref() == Ok("0") {
                    cuda = cuda.with_tf32(false);
                }
                b = b.with_execution_providers([cuda.build().error_on_failure()])?;
            }
            #[cfg(not(feature = "cuda"))]
            return Err(ort::Error::new("moonsplice-track was built without --features cuda"));
        }
        #[cfg(not(target_os = "macos"))]
        if coreml.is_some() {
            return Err(ort::Error::new("Core ML is only available on macOS"));
        }
        #[cfg(target_os = "macos")]
        if let Some((units, cache)) = coreml {
            let u = match units {
                Units::Gpu => ep::coreml::ComputeUnits::CPUAndGPU,
                Units::All => ep::coreml::ComputeUnits::All,
                Units::Ane => ep::coreml::ComputeUnits::CPUAndNeuralEngine,
            };
            b = b.with_execution_providers([ep::CoreML::default()
                .with_model_format(ep::coreml::ModelFormat::MLProgram)
                .with_compute_units(u)
                .with_model_cache_dir(cache.display())
                .build()])?;
        }
        b.commit_from_file(&path)
    })()
    .map_err(|e| format!("{}: {e}", path.display()))
}

pub(crate) fn run(s: &mut Session, inputs: Vec<(&str, Tensor<f32>)>, extra: Vec<(&str, ort::value::DynValue)>)
    -> Result<Vec<(Vec<i64>, Vec<f32>)>, Err> {
    let mut v: Vec<(std::borrow::Cow<str>, ort::session::SessionInputValue)> = Vec::new();
    for (k, t) in inputs {
        v.push((k.into(), t.into()));
    }
    for (k, t) in extra {
        v.push((k.into(), t.into()));
    }
    let out = s.run(v).map_err(|e| e.to_string())?;
    let mut r = Vec::new();
    for (_, val) in out.iter() {
        if let Ok((shape, data)) = val.try_extract_tensor::<f32>() {
            r.push((shape.iter().copied().collect(), data.to_vec()));
        } else {
            r.push((vec![], vec![]));
        }
    }
    Ok(r)
}

pub(crate) fn t(shape: &[usize], data: Vec<f32>) -> Result<Tensor<f32>, Err> {
    Tensor::from_array((shape.to_vec(), data)).map_err(|e| e.to_string())
}

/// (1, C, 64, 64) channel-major -> (4096, 1, C) token-major.
pub(crate) fn to_tokens(x: &[f32], ch: usize) -> Vec<f32> {
    let mut o = vec![0f32; HW * ch];
    for c in 0..ch {
        for p in 0..HW {
            o[p * ch + c] = x[c * HW + p];
        }
    }
    o
}
