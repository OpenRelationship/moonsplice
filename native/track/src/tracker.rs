//! The tracker: loading the graphs, then a track through the frames, on the host or with features
//! kept on the device between graphs (`track_bound`).

use std::collections::HashMap;
use std::path::Path;

use ort::value::Tensor;

use super::memory::{pointer_memory, spatial_memory, Memory};
use super::session::{read_f32, run, session, t, to_tokens};
use super::{pil_bilinear, upsample_bilinear, Device, Err, FrameMask, Tracker, C, CUDA, HW, IMG, MAX_PTRS, MEAN, MEM, MEM_TOKENS, NUM_MASKMEM, STD};

impl Tracker {
    pub fn load(dir: &Path, device: Device) -> Result<Tracker, Err> {
        let cache = dir.join("coreml-cache");
        let cm = match device {
            Device::Cpu => None,
            Device::Cuda => {
                CUDA.store(true, std::sync::atomic::Ordering::Relaxed);
                None
            }
            Device::CoreMl(u) => {
                std::fs::create_dir_all(&cache).map_err(|e| e.to_string())?;
                Some((u, cache.as_path()))
            }
        };
        let lean = dir.join("vision_encoder_lean.onnx").exists() && dir.join("pos2.f32").exists();
        Ok(Tracker {
            vision: session(if lean { dir.join("vision_encoder_lean.onnx") } else { dir.join("vision_encoder.onnx") }, cm)?,
            decoder: session(dir.join("mask_decoder.onnx"), None)?,
            decoder_single: session(dir.join("mask_decoder_single.onnx"), None)?,
            attention: session(dir.join("memory_attention.onnx"), None)?,
            attention_fixed: HashMap::new(),
            coreml: cm.map(|(u, c)| (u, c.to_path_buf())),
            dir: dir.to_path_buf(),
            memory: session(dir.join("memory_encoder.onnx"), cm)?,
            no_mem: read_f32(&dir.join("no_memory_embedding.f32"), C)?,
            tpos: read_f32(&dir.join("maskmem_tpos_enc.f32"), NUM_MASKMEM * MEM)?,
            pos2: if lean { Some(read_f32(&dir.join("pos2.f32"), C * HW)?) } else { None },
            attention_nchw: if lean && dir.join("memory_attention_nchw.onnx").exists()
                && (device == Device::Cuda || std::env::var("MOONSPLICE_TRACK_BOUND").as_deref() == Ok("1")) {
                Some(session(dir.join("memory_attention_nchw.onnx"), None)?)
            } else {
                None
            },
            cuda: device == Device::Cuda,
        })
    }

    fn pixels(rgb: &[u8], w: usize, h: usize) -> Vec<f32> {
        let r = pil_bilinear(rgb, w, h, IMG, IMG);
        let mut o = vec![0f32; 3 * IMG * IMG];
        for p in 0..IMG * IMG {
            for c in 0..3 {
                o[c * IMG * IMG + p] = (r[p * 3 + c] as f32 / 255.0 - MEAN[c]) / STD[c];
            }
        }
        o
    }

    /// Track the object in `box_px` (x0, y0, x1, y1, source pixels, on frame 0) through `n` RGB
    /// frames of `w` x `h`. `frame(i)` returns frame i; `emit(i, mask)` receives each result in order.
    pub fn track(&mut self, n: usize, w: usize, h: usize, box_px: [f32; 4],
                 mut frame: impl FnMut(usize) -> Vec<u8>,
                 mut emit: impl FnMut(usize, FrameMask) -> Result<(), Err>) -> Result<(), Err> {
        if self.attention_nchw.is_some() {
            return self.track_bound(n, w, h, box_px, frame, emit);
        }
        let (sx, sy) = (IMG as f32 / w as f32, IMG as f32 / h as f32);
        let mut bank: HashMap<usize, Memory> = HashMap::new();
        let max_ptrs = n.min(MAX_PTRS);
        // MOONSPLICE_TRACK_PROFILE=1: seconds per stage and per frame, as one JSON line on stderr
        let prof = std::env::var("MOONSPLICE_TRACK_PROFILE").as_deref() == Ok("1");
        let mut st = [0f64; 7];
        let mut per_frame = Vec::with_capacity(n);
        let mut clock = std::time::Instant::now();
        let mut lap = |i: usize, st: &mut [f64; 7]| {
            let now = std::time::Instant::now();
            st[i] += (now - clock).as_secs_f64();
            clock = now;
        };
        // Frame f+1 is resized on a second thread while the graphs run on frame f.
        let mut next: Option<std::thread::JoinHandle<Vec<f32>>> = None;
        for f in 0..n {
            if f == 5 && n > 10 {
                st = [0f64; 7]; // stage totals cover frames 5.. (steady state), per_frame covers all
            }
            let t_frame = std::time::Instant::now();
            let px = match next.take() {
                Some(h) => h.join().map_err(|_| "resize thread panicked".to_string())?,
                None => Self::pixels(&frame(f), w, h),
            };
            if f + 1 < n {
                let rgb = frame(f + 1);
                next = Some(std::thread::spawn(move || Self::pixels(&rgb, w, h)));
            }
            lap(0, &mut st);
            let v = run(&mut self.vision, vec![("pixel_values", t(&[1, 3, IMG, IMG], px)?)], vec![])?;
            let (f0, f1, f2) = (&v[0].1, &v[1].1, &v[2].1);
            let p2 = match &self.pos2 {
                Some(p) => p,
                None => &v[5].1,
            };
            lap(1, &mut st);

            let (pix, points, labels, single) = if f == 0 {
                // no_memory_embedding is added by the caller: the graph starts after it.
                let mut pix = f2.clone();
                for c in 0..C {
                    for p in 0..HW {
                        pix[c * HW + p] += self.no_mem[c];
                    }
                }
                let b = box_px;
                (pix, vec![b[0] * sx, b[1] * sy, b[2] * sx, b[3] * sy], vec![2i32, 3], true)
            } else {
                let (spatial, spatial_pos) = self.spatial_memory(&bank, f);
                let ptr = self.pointer_memory(&bank, f, max_ptrs);
                let (s_len, p_len) = (spatial.len() / MEM, ptr.len() / MEM);
                let shape = (s_len / MEM_TOKENS, p_len / 4);
                let fixed = self.dir.join(format!("memory_attention_s{}_p{}.onnx", shape.0, shape.1));
                if let Some((u, cache)) = &self.coreml {
                    if !self.attention_fixed.contains_key(&shape) && fixed.exists() {
                        let s = session(fixed, Some((*u, cache.as_path())))?;
                        self.attention_fixed.insert(shape, s);
                    }
                }
                let sess = match self.attention_fixed.get_mut(&shape) {
                    Some(s) => s,
                    None => &mut self.attention,
                };
                let a = run(sess, vec![
                    ("current_vision_features", t(&[HW, 1, C], to_tokens(f2, C))?),
                    ("current_vision_position_embeddings", t(&[HW, 1, C], to_tokens(p2, C))?),
                    ("spatial_memory", t(&[s_len, 1, MEM], spatial)?),
                    ("spatial_memory_position_embeddings", t(&[s_len, 1, MEM], spatial_pos)?),
                    ("pointer_memory", t(&[p_len, 1, MEM], ptr)?),
                    ("pointer_memory_position_embeddings", t(&[p_len, 1, MEM], vec![0f32; p_len * MEM])?),
                ], vec![])?;
                lap(2, &mut st);
                // (1, 1, 4096, 256) -> (1, 256, 64, 64)
                let cond = &a[0].1;
                let mut pix = vec![0f32; C * HW];
                for p in 0..HW {
                    for c in 0..C {
                        pix[c * HW + p] = cond[p * C + c];
                    }
                }
                // EdgeTAM's own empty prompt: one (0, 0) point labelled -1.
                (pix, vec![0.0, 0.0], vec![-1i32], false)
            };
            lap(3, &mut st);
            let np = labels.len();
            let dec = if single { &mut self.decoder_single } else { &mut self.decoder };
            let lab = Tensor::from_array((vec![1usize, 1, np], labels)).map_err(|e| e.to_string())?;
            let d = run(dec, vec![
                ("feats0", t(&[1, 32, 256, 256], f0.clone())?),
                ("feats1", t(&[1, 64, 128, 128], f1.clone())?),
                ("feats2", t(&[1, C, 64, 64], pix)?),
                ("input_points", t(&[1, 1, np, 2], points)?),
            ], vec![("input_labels", lab.into_dyn())])?;
            let (low, high, ptr, score) = (&d[0].1, &d[1].1, &d[3].1, d[4].1[0]);
            lap(4, &mut st);

            let from_pts = Tensor::from_array((vec![1usize], vec![f == 0])).map_err(|e| e.to_string())?;
            let m = run(&mut self.memory, vec![
                ("vision_features", t(&[1, C, 64, 64], f2.clone())?),
                ("pred_masks_high_res", t(&[1, 1, IMG, IMG], high.clone())?),
            ], vec![("is_mask_from_pts", from_pts.into_dyn())])?;
            bank.insert(f, Memory { tokens: m[0].1.clone(), pos: m[1].1.clone(), ptr: ptr[..C].to_vec() });
            // cond frame 0 is kept; non-cond frames older than the pointer window are never read again
            if f > MAX_PTRS {
                bank.remove(&(f - MAX_PTRS));
            }

            lap(5, &mut st);
            let up = upsample_bilinear(low, 256, 256, w, h);
            emit(f, FrameMask { mask: up.iter().map(|&x| (x > 0.0) as u8).collect(), score })?;
            lap(6, &mut st);
            per_frame.push((t_frame.elapsed().as_secs_f64() * 1000.0).round() / 1000.0);
        }
        if prof {
            let names = ["pixels", "vision", "attention", "attention_host", "decoder", "memory", "emit"];
            let parts: Vec<String> = names.iter().zip(st).map(|(k, v)| format!("\"{k}\": {v:.3}")).collect();
            eprintln!("{{\"profile\": {{{}}}, \"per_frame\": {:?}}}", parts.join(", "), per_frame);
        }
        Ok(())
    }

    /// Conditioning frame first (temporal slot 0 -> tpos[6]), then up to six previous frames,
    /// oldest first (offset r -> tpos[r - 1]). Each memory is 512 tokens of 64.
    /// `track` with the features kept on the device: the encoder's feats0-2 go straight into the
    /// attention, decoder and memory encoder, the decoder's 1024x1024 mask straight into the memory
    /// encoder, and the position embedding is uploaded once. The host sees only what it must read:
    /// the low-res mask, the object pointer and score, and the memory tokens the bank keeps. Frame 0
    /// reads feats2 back once, to add no_memory_embedding. Same arithmetic as `track`, in the same order.
    fn track_bound(&mut self, n: usize, w: usize, h: usize, box_px: [f32; 4],
                   mut frame: impl FnMut(usize) -> Vec<u8>,
                   mut emit: impl FnMut(usize, FrameMask) -> Result<(), Err>) -> Result<(), Err> {
        use ort::memory::{AllocationDevice, AllocatorType, MemoryInfo, MemoryType};
        let e = |x: ort::Error| x.to_string();
        let dev = if self.cuda { AllocationDevice::CUDA } else { AllocationDevice::CPU };
        let on_dev = MemoryInfo::new(dev, 0, AllocatorType::Device, MemoryType::Default).map_err(e)?;
        let on_host = MemoryInfo::new(AllocationDevice::CPU, 0, AllocatorType::Device, MemoryType::Default).map_err(e)?;
        let host = |v: &ort::value::DynValue| -> Result<Vec<f32>, Err> {
            Ok(v.try_extract_tensor::<f32>().map_err(|x| x.to_string())?.1.to_vec())
        };
        let (sx, sy) = (IMG as f32 / w as f32, IMG as f32 / h as f32);
        let max_ptrs = n.min(MAX_PTRS);
        let (tpos, no_mem) = (self.tpos.clone(), self.no_mem.clone());
        let pos_tok = t(&[HW, 1, C], to_tokens(self.pos2.as_ref().ok_or("pos2.f32 missing")?, C))?;
        let pos_dev = if self.cuda { pos_tok.to(dev, 0).map_err(e)? } else { pos_tok };
        let Tracker { vision, decoder, decoder_single, memory, attention_nchw, .. } = self;
        let attention = attention_nchw.as_mut().ok_or("memory_attention_nchw.onnx missing")?;
        let mut bv = vision.create_binding().map_err(e)?;
        let mut ba = attention.create_binding().map_err(e)?;
        let mut bd = decoder.create_binding().map_err(e)?;
        let mut bds = decoder_single.create_binding().map_err(e)?;
        let mut bm = memory.create_binding().map_err(e)?;
        ba.bind_input("current_vision_position_embeddings", &pos_dev).map_err(e)?;
        ba.bind_output_to_device("conditioned_features_nchw", &on_dev).map_err(e)?;
        for b in [&mut bd, &mut bds] {
            b.bind_output_to_device("pred_masks", &on_host).map_err(e)?;
            b.bind_output_to_device("high_res_masks", &on_dev).map_err(e)?;
            b.bind_output_to_device("iou_scores", &on_host).map_err(e)?;
            b.bind_output_to_device("object_pointer", &on_host).map_err(e)?;
            b.bind_output_to_device("object_score_logits", &on_host).map_err(e)?;
        }
        bm.bind_output_to_device("memory_tokens", &on_host).map_err(e)?;
        bm.bind_output_to_device("memory_pos_enc", &on_host).map_err(e)?;

        let prof = std::env::var("MOONSPLICE_TRACK_PROFILE").as_deref() == Ok("1");
        let mut st = [0f64; 7];
        let mut per_frame = Vec::with_capacity(n);
        let mut clock = std::time::Instant::now();
        let mut lap = |i: usize, st: &mut [f64; 7]| {
            let now = std::time::Instant::now();
            st[i] += (now - clock).as_secs_f64();
            clock = now;
        };
        let mut bank: HashMap<usize, Memory> = HashMap::new();
        let mut next: Option<std::thread::JoinHandle<Vec<f32>>> = None;
        for f in 0..n {
            if f == 5 && n > 10 {
                st = [0f64; 7]; // stage totals cover frames 5.. (steady state), per_frame covers all
            }
            let t_frame = std::time::Instant::now();
            let px = match next.take() {
                Some(hd) => hd.join().map_err(|_| "resize thread panicked".to_string())?,
                None => Self::pixels(&frame(f), w, h),
            };
            if f + 1 < n {
                let rgb = frame(f + 1);
                next = Some(std::thread::spawn(move || Self::pixels(&rgb, w, h)));
            }
            lap(0, &mut st);
            let pxt = t(&[1, 3, IMG, IMG], px)?;
            bv.bind_input("pixel_values", &pxt).map_err(e)?;
            bv.clear_outputs();
            bv.bind_output_to_device("feats0", &on_dev).map_err(e)?;
            bv.bind_output_to_device("feats1", &on_dev).map_err(e)?;
            bv.bind_output_to_device("feats2", if f == 0 { &on_host } else { &on_dev }).map_err(e)?;
            let mut vo = vision.run_binding(&bv).map_err(e)?;
            let f0 = vo.remove("feats0").ok_or("no feats0")?;
            let f1 = vo.remove("feats1").ok_or("no feats1")?;
            let f2 = vo.remove("feats2").ok_or("no feats2")?;
            drop(vo);
            lap(1, &mut st);

            let (dec, bdec) = if f == 0 { (&mut *decoder_single, &mut bds) } else { (&mut *decoder, &mut bd) };
            let mut hold: Vec<ort::value::DynValue> = Vec::new();
            if f == 0 {
                // no_memory_embedding is added by the caller: the graph starts after it.
                let mut pix = host(&f2)?;
                for c in 0..C {
                    for q in 0..HW {
                        pix[c * HW + q] += no_mem[c];
                    }
                }
                let b = box_px;
                hold.push(t(&[1, C, 64, 64], pix)?.into_dyn());
                hold.push(t(&[1, 1, 2, 2], vec![b[0] * sx, b[1] * sy, b[2] * sx, b[3] * sy])?.into_dyn());
                hold.push(Tensor::from_array((vec![1usize, 1, 2], vec![2i32, 3])).map_err(e)?.into_dyn());
                lap(2, &mut st);
            } else {
                let (spatial, spatial_pos) = spatial_memory(&tpos, &bank, f);
                let ptr = pointer_memory(&bank, f, max_ptrs);
                let (s_len, p_len) = (spatial.len() / MEM, ptr.len() / MEM);
                let sm = t(&[s_len, 1, MEM], spatial)?;
                let sp = t(&[s_len, 1, MEM], spatial_pos)?;
                let pm = t(&[p_len, 1, MEM], ptr)?;
                let pp = t(&[p_len, 1, MEM], vec![0f32; p_len * MEM])?;
                ba.bind_input("vision_features_nchw", &f2).map_err(e)?;
                ba.bind_input("spatial_memory", &sm).map_err(e)?;
                ba.bind_input("spatial_memory_position_embeddings", &sp).map_err(e)?;
                ba.bind_input("pointer_memory", &pm).map_err(e)?;
                ba.bind_input("pointer_memory_position_embeddings", &pp).map_err(e)?;
                lap(3, &mut st);
                let mut ao = attention.run_binding(&ba).map_err(e)?;
                hold.push(ao.remove("conditioned_features_nchw").ok_or("no conditioned features")?);
                drop(ao);
                // EdgeTAM's own empty prompt: one (0, 0) point labelled -1.
                hold.push(t(&[1, 1, 1, 2], vec![0.0, 0.0])?.into_dyn());
                hold.push(Tensor::from_array((vec![1usize, 1, 1], vec![-1i32])).map_err(e)?.into_dyn());
                lap(2, &mut st);
            }
            bdec.bind_input("feats0", &f0).map_err(e)?;
            bdec.bind_input("feats1", &f1).map_err(e)?;
            bdec.bind_input("feats2", &hold[0]).map_err(e)?;
            bdec.bind_input("input_points", &hold[1]).map_err(e)?;
            bdec.bind_input("input_labels", &hold[2]).map_err(e)?;
            let mut d = dec.run_binding(bdec).map_err(e)?;
            let low = host(d.get("pred_masks").ok_or("no pred_masks")?)?;
            let ptr = host(d.get("object_pointer").ok_or("no object_pointer")?)?;
            let score = host(d.get("object_score_logits").ok_or("no score")?)?[0];
            let high = d.remove("high_res_masks").ok_or("no high_res_masks")?;
            drop(d);
            lap(4, &mut st);

            let from_pts = Tensor::from_array((vec![1usize], vec![f == 0])).map_err(e)?;
            bm.bind_input("vision_features", &f2).map_err(e)?;
            bm.bind_input("pred_masks_high_res", &high).map_err(e)?;
            bm.bind_input("is_mask_from_pts", &from_pts).map_err(e)?;
            let mo = memory.run_binding(&bm).map_err(e)?;
            let tokens = host(mo.get("memory_tokens").ok_or("no memory_tokens")?)?;
            let pos = host(mo.get("memory_pos_enc").ok_or("no memory_pos_enc")?)?;
            drop(mo);
            bank.insert(f, Memory { tokens, pos, ptr: ptr[..C].to_vec() });
            if f > MAX_PTRS {
                bank.remove(&(f - MAX_PTRS));
            }
            lap(5, &mut st);

            let up = upsample_bilinear(&low, 256, 256, w, h);
            emit(f, FrameMask { mask: up.iter().map(|&x| (x > 0.0) as u8).collect(), score })?;
            lap(6, &mut st);
            per_frame.push((t_frame.elapsed().as_secs_f64() * 1000.0).round() / 1000.0);
        }
        if prof {
            let names = ["pixels", "vision", "attention", "attention_host", "decoder", "memory", "emit"];
            let parts: Vec<String> = names.iter().zip(st).map(|(k, v)| format!("\"{k}\": {v:.3}")).collect();
            eprintln!("{{\"profile\": {{{}}}, \"per_frame\": {:?}, \"bound\": true}}", parts.join(", "), per_frame);
        }
        Ok(())
    }
}
