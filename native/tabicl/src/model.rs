//! TabICLv2's forward pass (tabicl 2.0.2, `TabICL._inference_forward`), as the classifier runs it:
//! column-wise embedding (an induced set transformer per feature group, target-aware) -> row-wise
//! interaction (a RoPE transformer over each row's groups, read out through 4 CLS tokens) ->
//! dataset-wise in-context learning (a transformer whose keys are the training rows only).
//! Inference only, eval mode, float32. Names follow the checkpoint's state dict.

use anyhow::{bail, Result};
use candle_core::{DType, Device, Tensor, D};
use candle_nn::VarBuilder;

pub struct Config {
    pub max_classes: usize,
    pub embed_dim: usize,
    pub col_num_blocks: usize,
    pub col_nhead: usize,
    pub col_num_inds: usize,
    pub group_size: usize,
    pub row_num_blocks: usize,
    pub row_nhead: usize,
    pub row_num_cls: usize,
    pub icl_num_blocks: usize,
    pub icl_nhead: usize,
}

impl Config {
    /// tabicl-v2.config.json, the only checkpoint we carry; anything else is refused at load
    pub fn v2() -> Self {
        Config {
            max_classes: 10,
            embed_dim: 128,
            col_num_blocks: 3,
            col_nhead: 8,
            col_num_inds: 128,
            group_size: 3,
            row_num_blocks: 3,
            row_nhead: 8,
            row_num_cls: 4,
            icl_num_blocks: 12,
            icl_nhead: 8,
        }
    }
}

const SKIP: f32 = -100.0;
const LN_EPS: f64 = 1e-5;

struct Linear {
    w: Tensor,
    b: Tensor,
}

impl Linear {
    fn load(vb: &VarBuilder, i: usize, o: usize) -> Result<Self> {
        Ok(Linear { w: vb.get((o, i), "weight")?, b: vb.get(o, "bias")? })
    }
    fn fwd(&self, x: &Tensor) -> Result<Tensor> {
        Ok(x.broadcast_matmul(&self.w.t()?)?.broadcast_add(&self.b)?)
    }
}

struct LayerNorm {
    w: Tensor,
    b: Tensor,
}

impl LayerNorm {
    fn load(vb: &VarBuilder, d: usize) -> Result<Self> {
        Ok(LayerNorm { w: vb.get(d, "weight")?, b: vb.get(d, "bias")? })
    }
    fn fwd(&self, x: &Tensor) -> Result<Tensor> {
        let mean = x.mean_keepdim(D::Minus1)?;
        let xc = x.broadcast_sub(&mean)?;
        let var = xc.sqr()?.mean_keepdim(D::Minus1)?;
        let y = xc.broadcast_div(&(var + LN_EPS)?.sqrt()?)?;
        Ok(y.broadcast_mul(&self.w)?.broadcast_add(&self.b)?)
    }
}

/// QASSMaxMLP, elementwise: q * base_mlp(log n) * (1 + tanh(query_mlp(q)))
struct QaSsMax {
    base0: Linear,
    base2: Linear,
    query0: Linear,
    query2: Linear,
    nhead: usize,
    hd: usize,
}

impl QaSsMax {
    fn load(vb: &VarBuilder, nhead: usize, hd: usize) -> Result<Self> {
        Ok(QaSsMax {
            base0: Linear::load(&vb.pp("base_mlp.0"), 1, 64)?,
            base2: Linear::load(&vb.pp("base_mlp.2"), 64, nhead * hd)?,
            query0: Linear::load(&vb.pp("query_mlp.0"), hd, 64)?,
            query2: Linear::load(&vb.pp("query_mlp.2"), 64, hd)?,
            nhead,
            hd,
        })
    }
    /// q: (N, H, L, hd); n: the number of keys
    fn fwd(&self, q: &Tensor, n: usize) -> Result<Tensor> {
        let logn = (n.max(1) as f64).ln() as f32;
        let x = Tensor::new(&[[logn]], q.device())?;
        let base = self.base2.fwd(&self.base0.fwd(&x)?.gelu_erf()?)?.reshape((1, self.nhead, 1, self.hd))?;
        let modulation = (self.query2.fwd(&self.query0.fwd(q)?.gelu_erf()?)?.tanh()? + 1.0)?;
        Ok(q.mul(&modulation.broadcast_mul(&base)?)?)
    }
}

/// non-interleaved rotary embedding over a head's whole width
struct Rope {
    freqs: Tensor,
}

impl Rope {
    /// t: (N, H, L, hd), positions 0..L
    fn rotate(&self, t: &Tensor) -> Result<Tensor> {
        let (_, _, l, hd) = t.dims4()?;
        let pos = Tensor::arange(0u32, l as u32, t.device())?.to_dtype(DType::F32)?;
        let ang = pos.unsqueeze(1)?.broadcast_mul(&self.freqs.unsqueeze(0)?)?; // (L, hd/2)
        let ang = Tensor::cat(&[&ang, &ang], 1)?;
        let (cos, sin) = (ang.cos()?, ang.sin()?);
        let half = hd / 2;
        let x1 = t.narrow(3, 0, half)?;
        let x2 = t.narrow(3, half, half)?;
        let rot = Tensor::cat(&[&x2.neg()?, &x1], 3)?;
        Ok(t.broadcast_mul(&cos)?.add(&rot.broadcast_mul(&sin)?)?)
    }
}

struct Attention {
    in_w: Tensor,
    in_b: Tensor,
    out: Linear,
    ssmax: Option<QaSsMax>,
    nhead: usize,
}

impl Attention {
    fn load(vb: &VarBuilder, d: usize, nhead: usize, ssmax: bool) -> Result<Self> {
        Ok(Attention {
            in_w: vb.get((3 * d, d), "in_proj_weight")?,
            in_b: vb.get(3 * d, "in_proj_bias")?,
            out: Linear::load(&vb.pp("out_proj"), d, d)?,
            ssmax: if ssmax { Some(QaSsMax::load(&vb.pp("ssmax_layer"), nhead, d / nhead)?) } else { None },
            nhead,
        })
    }

    fn proj(&self, x: &Tensor, k: usize, d: usize) -> Result<Tensor> {
        let w = self.in_w.narrow(0, k * d, d)?;
        let b = self.in_b.narrow(0, k * d, d)?;
        // (N, L, d) -> (N, H, L, hd)
        let (n, l, _) = x.dims3()?;
        let y = x.broadcast_matmul(&w.t()?)?.broadcast_add(&b)?;
        Ok(y.reshape((n, l, self.nhead, d / self.nhead))?.transpose(1, 2)?.contiguous()?)
    }

    /// q: (N, Lq, d), kv: (N, Lk, d)
    fn fwd(&self, q: &Tensor, kv: &Tensor, rope: Option<&Rope>) -> Result<Tensor> {
        let (n, lq, d) = q.dims3()?;
        let lk = kv.dim(1)?;
        let hd = d / self.nhead;
        let mut qh = self.proj(q, 0, d)?;
        let mut kh = self.proj(kv, 1, d)?;
        let vh = self.proj(kv, 2, d)?;
        if let Some(r) = rope {
            qh = r.rotate(&qh)?;
            kh = r.rotate(&kh)?;
        }
        if let Some(s) = &self.ssmax {
            qh = s.fwd(&qh, lk)?;
        }
        let scores = (qh.matmul(&kh.transpose(2, 3)?.contiguous()?)? / (hd as f64).sqrt())?;
        let p = candle_nn::ops::softmax_last_dim(&scores)?;
        let o = p.matmul(&vh)?; // (N, H, Lq, hd)
        let o = o.transpose(1, 2)?.contiguous()?.reshape((n, lq, d))?;
        self.out.fwd(&o)
    }
}

/// MultiheadAttentionBlock, norm_first: x = q + attn(norm1 q, norm1 kv); x + ff(norm2 x)
struct Block {
    attn: Attention,
    norm1: LayerNorm,
    norm2: LayerNorm,
    lin1: Linear,
    lin2: Linear,
}

impl Block {
    fn load(vb: &VarBuilder, d: usize, nhead: usize, ff: usize, ssmax: bool) -> Result<Self> {
        Ok(Block {
            attn: Attention::load(&vb.pp("attn"), d, nhead, ssmax)?,
            norm1: LayerNorm::load(&vb.pp("norm1"), d)?,
            norm2: LayerNorm::load(&vb.pp("norm2"), d)?,
            lin1: Linear::load(&vb.pp("linear1"), d, ff)?,
            lin2: Linear::load(&vb.pp("linear2"), ff, d)?,
        })
    }

    fn ff(&self, x: &Tensor) -> Result<Tensor> {
        self.lin2.fwd(&self.lin1.fwd(x)?.gelu_erf()?)
    }

    /// q attends to kv; kv None = self-attention; train Some(n) = keys are q's first n rows
    fn fwd(&self, q: &Tensor, kv: Option<&Tensor>, train: Option<usize>, rope: Option<&Rope>) -> Result<Tensor> {
        let qn = self.norm1.fwd(q)?;
        let kn = match (kv, train) {
            (Some(k), _) => self.norm1.fwd(k)?,
            (None, Some(n)) => qn.narrow(1, 0, n)?,
            (None, None) => qn.clone(),
        };
        let x = q.add(&self.attn.fwd(&qn, &kn, rope)?)?;
        Ok(x.add(&self.ff(&self.norm2.fwd(&x)?)?)?)
    }
}

struct Isab {
    ind: Tensor,
    mab1: Block,
    mab2: Block,
}

impl Isab {
    /// src: (N, T, E); the inducing points read the training rows, then every row reads them
    fn fwd(&self, src: &Tensor, train: usize) -> Result<Tensor> {
        let n = src.dim(0)?;
        let (m, e) = self.ind.dims2()?;
        let ind = self.ind.unsqueeze(0)?.broadcast_as((n, m, e))?.contiguous()?;
        let hidden = self.mab1.fwd(&ind, Some(&src.narrow(1, 0, train)?), None, None)?;
        self.mab2.fwd(src, Some(&hidden), None, None)
    }
}

pub struct TabIcl {
    cfg: Config,
    dev: Device,
    in_linear: Linear,
    col_y: Linear,
    col_blocks: Vec<Isab>,
    cls: Tensor,
    row_blocks: Vec<Block>,
    rope: Rope,
    row_ln: LayerNorm,
    icl_y: Linear,
    icl_blocks: Vec<Block>,
    icl_ln: LayerNorm,
    dec0: Linear,
    dec2: Linear,
}

impl TabIcl {
    pub fn load(path: &std::path::Path, dev: &Device) -> Result<Self> {
        let cfg = Config::v2();
        let vb = unsafe { VarBuilder::from_mmaped_safetensors(&[path], DType::F32, dev)? };
        let e = cfg.embed_dim;
        let icl = e * cfg.row_num_cls;
        let col = vb.pp("col_embedder");
        let mut col_blocks = Vec::new();
        for i in 0..cfg.col_num_blocks {
            let b = col.pp(format!("tf_col.blocks.{i}"));
            col_blocks.push(Isab {
                ind: b.get((cfg.col_num_inds, e), "ind_vectors")?,
                mab1: Block::load(&b.pp("multihead_attn1"), e, cfg.col_nhead, 2 * e, true)?,
                mab2: Block::load(&b.pp("multihead_attn2"), e, cfg.col_nhead, 2 * e, false)?,
            });
        }
        let row = vb.pp("row_interactor");
        let row_blocks = (0..cfg.row_num_blocks)
            .map(|i| Block::load(&row.pp(format!("tf_row.blocks.{i}")), e, cfg.row_nhead, 2 * e, false))
            .collect::<Result<Vec<_>>>()?;
        let icl_vb = vb.pp("icl_predictor");
        let icl_blocks = (0..cfg.icl_num_blocks)
            .map(|i| Block::load(&icl_vb.pp(format!("tf_icl.blocks.{i}")), icl, cfg.icl_nhead, 2 * icl, true))
            .collect::<Result<Vec<_>>>()?;
        Ok(TabIcl {
            in_linear: Linear::load(&col.pp("in_linear"), cfg.group_size, e)?,
            col_y: Linear::load(&col.pp("y_encoder"), cfg.max_classes, e)?,
            col_blocks,
            cls: row.get((cfg.row_num_cls, e), "cls_tokens")?,
            row_blocks,
            rope: Rope { freqs: row.get(e / cfg.row_nhead / 2, "tf_row.rope.freqs")? },
            row_ln: LayerNorm::load(&row.pp("out_ln"), e)?,
            icl_y: Linear::load(&icl_vb.pp("y_encoder"), cfg.max_classes, icl)?,
            icl_blocks,
            icl_ln: LayerNorm::load(&icl_vb.pp("ln"), icl)?,
            dec0: Linear::load(&icl_vb.pp("decoder.0"), icl, 2 * icl)?,
            dec2: Linear::load(&icl_vb.pp("decoder.2"), 2 * icl, cfg.max_classes)?,
            cfg,
            dev: dev.clone(),
        })
    }

    fn one_hot(&self, y: &[f32]) -> Result<Tensor> {
        let k = self.cfg.max_classes;
        let mut v = vec![0f32; y.len() * k];
        for (i, &c) in y.iter().enumerate() {
            v[i * k + c as usize] = 1.0;
        }
        Ok(Tensor::from_vec(v, (y.len(), k), &self.dev)?)
    }

    /// One table: x is (T, H) row-major (training rows first), y the training labels (0..k-1).
    /// Returns logits (T - train, k) for k = the number of distinct training labels.
    pub fn forward_one(&self, x: &[f32], t: usize, h: usize, y: &[f32]) -> Result<Vec<Vec<f32>>> {
        let train = y.len();
        if train == 0 || train > t || x.len() != t * h || h == 0 {
            bail!("tabicl: bad shapes (T {t}, H {h}, train {train}, cells {})", x.len());
        }
        let mut distinct: Vec<i64> = y.iter().map(|&c| c as i64).collect();
        distinct.sort();
        distinct.dedup();
        let k = distinct.len();
        if distinct[distinct.len() - 1] as usize >= self.cfg.max_classes {
            bail!("tabicl: more than {} classes is not ported", self.cfg.max_classes);
        }
        let e = self.cfg.embed_dim;
        let c = self.cfg.row_num_cls;
        let gs = self.cfg.group_size;
        let g = h + c;

        // feature grouping "same": group j holds features (j + 2^i) % H; CLS groups are all SKIP
        let mut feats = vec![SKIP; g * t * gs];
        for j in 0..h {
            for r in 0..t {
                for i in 0..gs {
                    feats[((c + j) * t + r) * gs + i] = x[r * h + (j + (1 << i)) % h];
                }
            }
        }
        let feats = Tensor::from_vec(feats, (g, t, gs), &self.dev)?;
        let mut src = self.in_linear.fwd(&feats)?;
        // SkippableLinear: a row whose inputs are all SKIP stays SKIP
        let skip: Vec<f32> = (0..g).flat_map(|gi| (0..t).map(move |_| if gi < c { 1.0 } else { 0.0 })).collect();
        let skip = Tensor::from_vec(skip, (g, t, 1), &self.dev)?;
        src = skip.broadcast_mul(&Tensor::full(SKIP, (g, t, e), &self.dev)?)?.add(&(1.0 - &skip)?.broadcast_mul(&src)?)?;
        // target-aware: the training rows carry their label
        let ye = self.col_y.fwd(&self.one_hot(y)?)?; // (train, E)
        let head = src.narrow(1, 0, train)?.broadcast_add(&ye)?;
        src = if train < t { Tensor::cat(&[&head, &src.narrow(1, train, t - train)?], 1)? } else { head };
        for b in &self.col_blocks {
            src = b.fwd(&src, train)?; // a group all SKIP cannot occur here: y was added to every group
        }
        // (G+C, T, E) -> (T, G+C, E), CLS tokens in front
        let emb = src.transpose(0, 1)?.contiguous()?;
        let cls = self.cls.unsqueeze(0)?.broadcast_as((t, c, e))?.contiguous()?;
        let mut emb = Tensor::cat(&[&cls, &emb.narrow(1, c, h)?], 1)?;
        let nb = self.row_blocks.len();
        for b in &self.row_blocks[..nb - 1] {
            emb = b.fwd(&emb, None, None, Some(&self.rope))?;
        }
        let cls_out = self.row_blocks[nb - 1].fwd(&emb.narrow(1, 0, c)?, Some(&emb), None, Some(&self.rope))?;
        let rep = self.row_ln.fwd(&cls_out)?.reshape((1, t, c * e))?;

        // in-context learning over the rows
        let ry = self.icl_y.fwd(&self.one_hot(y)?)?.unsqueeze(0)?;
        let head = rep.narrow(1, 0, train)?.broadcast_add(&ry)?;
        let mut r = if train < t { Tensor::cat(&[&head, &rep.narrow(1, train, t - train)?], 1)? } else { head };
        for b in &self.icl_blocks {
            r = b.fwd(&r, None, Some(train), None)?;
        }
        let out = self.dec2.fwd(&self.dec0.fwd(&self.icl_ln.fwd(&r)?)?.gelu_erf()?)?;
        let out = out.squeeze(0)?.narrow(0, train, t - train)?.narrow(1, 0, k)?;
        Ok(out.to_vec2::<f32>()?)
    }
}
