//! The ensemble's members: the preprocessing pipeline each one fits (sklearn's scaler, the power
//! transform and outlier clipping), and the feature permutations and class rotations between them.

use super::yeojohnson::{col, is_constant, mean, nan_stats, var, yj, yj_normmax};
use crate::pyrand::PyRandom;
use anyhow::{bail, Result};


// ---------- PreprocessingPipeline ----------

pub(super) struct Pipeline {
    mean: Vec<f64>,
    scale: Vec<f64>,
    power: Option<(Vec<f64>, Vec<f64>, Vec<f64>)>, // lambdas, scaler mean, scaler scale
    lower: Vec<f64>,
    upper: Vec<f64>,
    pub(super) train_out: Vec<Vec<f64>>,
}

impl Pipeline {
    fn std_scale(&self, x: &[Vec<f64>]) -> Vec<Vec<f64>> {
        x.iter()
            .map(|r| r.iter().enumerate().map(|(j, v)| ((v - self.mean[j]) / self.scale[j]).clamp(-100.0, 100.0)).collect())
            .collect()
    }
    fn power_apply(&self, x: Vec<Vec<f64>>) -> Vec<Vec<f64>> {
        match &self.power {
            None => x,
            Some((lam, m, s)) => {
                x.into_iter().map(|r| r.iter().enumerate().map(|(j, &v)| (yj(v, lam[j]) - m[j]) / s[j]).collect()).collect()
            }
        }
    }
    fn clip(&self, x: Vec<Vec<f64>>) -> Vec<Vec<f64>> {
        x.into_iter()
            .map(|r| {
                r.iter()
                    .enumerate()
                    .map(|(j, &v)| {
                        let v = (-(v.abs().ln_1p()) + self.lower[j]).max(v);
                        (v.abs().ln_1p() + self.upper[j]).min(v)
                    })
                    .collect()
            })
            .collect()
    }

    pub(super) fn fit(x: &[Vec<f64>], power: bool, thr: f64) -> Pipeline {
        let n = x.len();
        let d = x[0].len();
        let mean: Vec<f64> = (0..d).map(|j| self::mean(&col(x, j))).collect();
        let scale: Vec<f64> = (0..d).map(|j| var(&col(x, j), 0).sqrt() + 1e-6).collect();
        let mut p = Pipeline { mean, scale, power: None, lower: vec![], upper: vec![], train_out: vec![] };
        let xs = p.std_scale(x);
        if power {
            let mut lam = vec![1.0; d];
            let mut t = xs.clone();
            for j in 0..d {
                let c = col(&xs, j);
                if is_constant(var(&c, 0), self::mean(&c), n) {
                    continue; // lambda 1, and (as sklearn) the column is left as it is
                }
                lam[j] = yj_normmax(&c);
                for i in 0..n {
                    t[i][j] = yj(xs[i][j], lam[j]);
                }
            }
            // StandardScaler: a constant column gets scale 1
            let mut sm = vec![0.0; d];
            let mut ss = vec![1.0; d];
            for j in 0..d {
                let c = col(&t, j);
                let (m, v) = (self::mean(&c), var(&c, 0));
                sm[j] = m;
                ss[j] = if is_constant(v, m, n) { 1.0 } else { v.sqrt() };
            }
            p.power = Some((lam, sm, ss));
        }
        let xn = p.power_apply(xs);
        // OutlierRemover: bounds from the data with its outliers masked out
        let ddof = if n > 1 { 1 } else { 0 };
        for j in 0..d {
            let c = col(&xn, j);
            let (m0, s0) = nan_stats(&c, ddof);
            let s0 = s0.max(1e-6);
            let clean: Vec<f64> =
                c.iter().map(|&v| if v < m0 - thr * s0 || v > m0 + thr * s0 { f64::NAN } else { v }).collect();
            let (m, s) = nan_stats(&clean, ddof);
            let s = s.max(1e-6);
            p.lower.push(m - thr * s);
            p.upper.push(m + thr * s);
        }
        p.train_out = p.clip(xn);
        p
    }

    pub(super) fn transform(&self, x: &[Vec<f64>]) -> Vec<Vec<f64>> {
        self.clip(self.power_apply(self.std_scale(x)))
    }
}

// ---------- the ensemble ----------

pub(super) fn latin_square(n: usize, rng: &mut PyRandom) -> Vec<Vec<usize>> {
    fn rls(symbols: &mut Vec<usize>, rng: &mut PyRandom) -> Vec<Vec<usize>> {
        let n = symbols.len();
        if n == 1 {
            return vec![symbols.clone()];
        }
        let sym = rng.choice(symbols);
        let pos = symbols.iter().position(|&s| s == sym).unwrap();
        symbols.remove(pos);
        let mut square = rls(symbols, rng);
        let first = square[0].clone();
        square.push(first);
        for (i, row) in square.iter_mut().enumerate().take(n) {
            row.insert(i, sym);
        }
        square
    }
    let mut symbols: Vec<usize> = (0..n).collect();
    let mut square = rls(&mut symbols, rng);
    rng.shuffle(&mut square);
    let mut trans: Vec<Vec<usize>> = (0..n).map(|c| square.iter().map(|r| r[c]).collect()).collect();
    rng.shuffle(&mut trans);
    trans
}

pub(super) fn feature_shuffles(n: usize, n_est: usize, seed: u32) -> Result<Vec<Vec<usize>>> {
    if n_est == 1 {
        return Ok(vec![(0..n).collect()]);
    }
    if n > 4000 {
        bail!("tabicl: more than 4000 features is not ported");
    }
    let mut rng = PyRandom::new(seed);
    Ok(latin_square(n, &mut rng))
}

pub(super) fn class_shifts(n: usize, n_est: usize) -> Vec<Vec<usize>> {
    let idx: Vec<usize> = (0..n).collect();
    if n_est == 1 {
        return vec![idx];
    }
    // indices[-i:] + indices[:-i]
    (0..n).map(|i| idx[n - i..].iter().chain(&idx[..n - i]).copied().collect()).collect()
}
