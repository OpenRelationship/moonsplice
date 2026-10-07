//! What `TabICLClassifier` (tabicl 2.2.0) does around the network, in float64 as numpy does it:
//! the table framed as tablua's server framed it (modal/tabular.py), ordinal-encoded categoricals
//! first, constant columns dropped, then an ensemble of members, each a normalisation
//! ("none" | "power", Yeo-Johnson as scipy 1.18.1 fits it) with a feature permutation (a random
//! Latin square drawn by CPython's MT19937) and a class rotation; the members' logits are
//! un-rotated, averaged, and softened at the temperature.

use crate::model::TabIcl;
use crate::pyrand::PyRandom;
use anyhow::{bail, Context, Result};
use serde_json::Value;

pub struct Settings {
    pub n_estimators: usize,
    pub random_state: u32,
    pub softmax_temperature: f64,
    pub outlier_threshold: f64,
}

impl Default for Settings {
    /// what tablua's server ran (modal/tabular.py: n_estimators=4, random_state=0)
    fn default() -> Self {
        Settings { n_estimators: 4, random_state: 0, softmax_temperature: 0.9, outlier_threshold: 4.0 }
    }
}

// ---------- framing: pandas' view of tablua's rows ----------

/// Python's repr of a float
fn py_float(x: f64) -> String {
    if x.is_nan() {
        return "nan".into();
    }
    if x.is_infinite() {
        return if x > 0.0 { "inf".into() } else { "-inf".into() };
    }
    let a = x.abs();
    if a != 0.0 && (a < 1e-4 || a >= 1e16) {
        let s = format!("{x:e}"); // 1e-5, 1.5e20
        let (m, e) = s.split_once('e').unwrap();
        let e: i32 = e.parse().unwrap();
        return format!("{m}e{}{:02}", if e < 0 { '-' } else { '+' }, e.abs());
    }
    let s = format!("{x}");
    if s.contains('.') { s } else { format!("{s}.0") }
}

/// one categorical column as `astype(str)` sees it, after DataFrame's dtype inference
fn cat_strings(col: &[&Value]) -> Vec<String> {
    let all_int = col.iter().all(|v| v.is_i64() || v.is_u64());
    let all_bool = col.iter().all(|v| v.is_boolean());
    let numeric_or_null = col.iter().all(|v| v.is_number() || v.is_null()) && col.iter().any(|v| v.is_number());
    col.iter()
        .map(|v| {
            if all_int || all_bool {
                match v {
                    Value::Bool(b) => if *b { "True".into() } else { "False".into() },
                    _ => v.to_string(),
                }
            } else if numeric_or_null {
                py_float(v.as_f64().unwrap_or(f64::NAN)) // a float64 column: 1 is "1.0", null "nan"
            } else {
                match v {
                    Value::String(s) => s.clone(),
                    Value::Null => "None".into(),
                    Value::Bool(b) => if *b { "True".into() } else { "False".into() },
                    Value::Number(n) if n.is_f64() => py_float(n.as_f64().unwrap()),
                    other => other.to_string(),
                }
            }
        })
        .collect()
}

/// pd.to_numeric(errors="coerce").fillna(-1)
fn num_value(v: &Value) -> f64 {
    let x = match v {
        Value::Number(n) => n.as_f64().unwrap_or(f64::NAN),
        Value::Bool(b) => if *b { 1.0 } else { 0.0 },
        Value::String(s) => s.trim().parse::<f64>().unwrap_or(f64::NAN),
        _ => f64::NAN,
    };
    if x.is_nan() { -1.0 } else { x }
}

fn rows_of(t: &Value) -> Result<Vec<Vec<Value>>> {
    let rows = t["rows"].as_array().context("a table needs rows")?;
    rows.iter().map(|r| r.as_array().cloned().context("a row is a list")).collect()
}

/// TransformToNumerical: categoricals (ordinal over the training values, unseen -1) then numerics
fn encode(body: &Value) -> Result<(Vec<Vec<f64>>, Vec<Vec<f64>>)> {
    let train = rows_of(&body["train"])?;
    let test = rows_of(&body["test"])?;
    let ncol = body["train"]["columns"].as_array().map(|c| c.len()).context("train columns")?;
    let cat: Vec<usize> = body["categorical"].as_array().map(|a| a.iter().filter_map(|v| v.as_u64()).map(|v| v as usize).collect()).unwrap_or_default();
    let cell = |r: &Vec<Value>, j: usize| r.get(j).cloned().unwrap_or(Value::Null);
    let mut tr: Vec<Vec<f64>> = vec![Vec::new(); train.len()];
    let mut te: Vec<Vec<f64>> = vec![Vec::new(); test.len()];
    for j in (0..ncol).filter(|j| cat.contains(j)) {
        let a: Vec<Value> = train.iter().map(|r| cell(r, j)).collect();
        let b: Vec<Value> = test.iter().map(|r| cell(r, j)).collect();
        let sa = cat_strings(&a.iter().collect::<Vec<_>>());
        let sb = cat_strings(&b.iter().collect::<Vec<_>>());
        let mut cats = sa.clone();
        cats.sort();
        cats.dedup();
        for (i, s) in sa.iter().enumerate() {
            tr[i].push(cats.binary_search(s).map(|k| k as f64).unwrap_or(-1.0));
        }
        for (i, s) in sb.iter().enumerate() {
            te[i].push(cats.binary_search(s).map(|k| k as f64).unwrap_or(-1.0));
        }
    }
    for j in (0..ncol).filter(|j| !cat.contains(j)) {
        for (i, r) in train.iter().enumerate() {
            tr[i].push(num_value(&cell(r, j)));
        }
        for (i, r) in test.iter().enumerate() {
            te[i].push(num_value(&cell(r, j)));
        }
    }
    Ok((tr, te))
}

// ---------- column statistics ----------

fn col(x: &[Vec<f64>], j: usize) -> Vec<f64> {
    x.iter().map(|r| r[j]).collect()
}
fn mean(v: &[f64]) -> f64 {
    v.iter().sum::<f64>() / v.len() as f64
}
/// numpy's var/std with ddof
fn var(v: &[f64], ddof: usize) -> f64 {
    let m = mean(v);
    v.iter().map(|x| (x - m) * (x - m)).sum::<f64>() / (v.len() - ddof) as f64
}
fn nan_stats(v: &[f64], ddof: usize) -> (f64, f64) {
    let ok: Vec<f64> = v.iter().copied().filter(|x| !x.is_nan()).collect();
    let d = if ok.len() > ddof { ddof } else { 0 };
    (mean(&ok), var(&ok, d).sqrt())
}
/// sklearn's _is_constant_feature
fn is_constant(var: f64, mean: f64, n: usize) -> bool {
    let eps = f64::EPSILON;
    let n = n as f64;
    var <= n * eps * var + (n * mean * eps).powi(2)
}

// ---------- Yeo-Johnson, as scipy.stats.yeojohnson fits and applies it ----------

fn yj(x: f64, l: f64) -> f64 {
    let eps = f64::EPSILON;
    if x >= 0.0 {
        if l.abs() < eps { x.ln_1p() } else { (l * x.ln_1p()).exp_m1() / l }
    } else if (l - 2.0).abs() > eps {
        -((2.0 - l) * (-x).ln_1p()).exp_m1() / (2.0 - l)
    } else {
        -(-x).ln_1p()
    }
}

fn logsumexp(v: &[f64]) -> f64 {
    let m = v.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    if m == f64::NEG_INFINITY {
        return m;
    }
    m + v.iter().map(|x| (x - m).exp()).sum::<f64>().ln()
}

/// log of the variance of exp(logx), in log space (scipy's _log_var)
fn log_var(logx: &[f64]) -> f64 {
    let n = logx.len() as f64;
    let logmean = logsumexp(logx) - n.ln();
    let dev: Vec<f64> = logx
        .iter()
        .map(|&a| {
            let m = a.max(logmean);
            if m == f64::NEG_INFINITY {
                return f64::NEG_INFINITY;
            }
            ((a - m).exp() - (logmean - m).exp()).abs().ln() + m
        })
        .map(|d| 2.0 * d)
        .collect();
    logsumexp(&dev) - n.ln()
}

fn yj_llf(data: &[f64], l: f64) -> f64 {
    let eps = f64::EPSILON;
    let n = data.len() as f64;
    let logvar = if data.iter().all(|&x| x >= 0.0) {
        if l.abs() < eps {
            var(&data.iter().map(|x| x.ln_1p()).collect::<Vec<_>>(), 0).ln()
        } else {
            log_var(&data.iter().map(|x| l * x.ln_1p()).collect::<Vec<_>>()) - 2.0 * l.abs().ln()
        }
    } else if data.iter().all(|&x| x < 0.0) {
        if (l - 2.0).abs() < eps {
            var(&data.iter().map(|x| (-x).ln_1p()).collect::<Vec<_>>(), 0).ln()
        } else {
            log_var(&data.iter().map(|x| (2.0 - l) * (-x).ln_1p()).collect::<Vec<_>>()) - 2.0 * (2.0 - l).abs().ln()
        }
    } else {
        let s = var(&data.iter().map(|&x| yj(x, l)).collect::<Vec<_>>(), 0);
        if s >= f64::MIN_POSITIVE { s.ln() } else { f64::NEG_INFINITY }
    };
    let signed: f64 = data.iter().map(|&x| x.signum() * x.abs().ln_1p()).sum();
    -n / 2.0 * logvar + (l - 1.0) * signed
}

/// scipy.optimize.fminbound (_minimize_scalar_bounded), line for line
fn fminbound(f: impl Fn(f64) -> f64, x1: f64, x2: f64, xatol: f64) -> f64 {
    let maxfun = 500;
    let sqrt_eps = 2.2e-16f64.sqrt();
    let golden_mean = 0.5 * (3.0 - 5f64.sqrt());
    let (mut a, mut b) = (x1, x2);
    let mut fulc = a + golden_mean * (b - a);
    let (mut nfc, mut xf) = (fulc, fulc);
    let (mut rat, mut e) = (0.0f64, 0.0f64);
    let mut x;
    let mut fx = f(xf);
    let mut num = 1;
    let (mut ffulc, mut fnfc) = (fx, fx);
    let mut xm = 0.5 * (a + b);
    let mut tol1 = sqrt_eps * xf.abs() + xatol / 3.0;
    let mut tol2 = 2.0 * tol1;
    let sign = |v: f64| if v > 0.0 { 1.0 } else if v < 0.0 { -1.0 } else { 0.0 };
    while (xf - xm).abs() > (tol2 - 0.5 * (b - a)) {
        let mut golden = true;
        if e.abs() > tol1 {
            golden = false;
            let mut r = (xf - nfc) * (fx - ffulc);
            let mut q = (xf - fulc) * (fx - fnfc);
            let mut p = (xf - fulc) * q - (xf - nfc) * r;
            q = 2.0 * (q - r);
            if q > 0.0 {
                p = -p;
            }
            q = q.abs();
            r = e;
            e = rat;
            if p.abs() < (0.5 * q * r).abs() && p > q * (a - xf) && p < q * (b - xf) {
                rat = (p + 0.0) / q;
                x = xf + rat;
                if (x - a) < tol2 || (b - x) < tol2 {
                    let si = sign(xm - xf) + if xm - xf == 0.0 { 1.0 } else { 0.0 };
                    rat = tol1 * si;
                }
            } else {
                golden = true;
            }
        }
        if golden {
            e = if xf >= xm { a - xf } else { b - xf };
            rat = golden_mean * e;
        }
        let si = sign(rat) + if rat == 0.0 { 1.0 } else { 0.0 };
        x = xf + si * rat.abs().max(tol1);
        let fu = f(x);
        num += 1;
        if fu <= fx {
            if x >= xf { a = xf } else { b = xf }
            fulc = nfc;
            ffulc = fnfc;
            nfc = xf;
            fnfc = fx;
            xf = x;
            fx = fu;
        } else {
            if x < xf { a = x } else { b = x }
            if fu <= fnfc || nfc == xf {
                fulc = nfc;
                ffulc = fnfc;
                nfc = x;
                fnfc = fu;
            } else if fu <= ffulc || fulc == xf || fulc == nfc {
                fulc = x;
                ffulc = fu;
            }
        }
        xm = 0.5 * (a + b);
        tol1 = sqrt_eps * xf.abs() + xatol / 3.0;
        tol2 = 2.0 * tol1;
        if num >= maxfun {
            break;
        }
    }
    xf
}

/// scipy.stats.yeojohnson_normmax with no bracket
fn yj_normmax(x: &[f64]) -> f64 {
    if x.iter().all(|&v| v == 0.0) {
        return 1.0;
    }
    let log1p_max_x = (20.0 * x.iter().fold(0f64, |m, v| m.max(v.abs()))).ln_1p();
    let log_eps = f64::EPSILON.ln();
    let log_tiny = (f64::MIN_POSITIVE.ln() - log_eps) / 2.0;
    let log_max = (f64::MAX.ln() + log_eps) / 2.0;
    let (mut lb, mut ub) = (log_tiny / log1p_max_x, log_max / log1p_max_x);
    if x.iter().all(|&v| v < 0.0) {
        (lb, ub) = (2.0 - ub, 2.0 - lb);
    } else if x.iter().any(|&v| v < 0.0) {
        (lb, ub) = ((2.0 - ub).max(lb), (2.0 - lb).min(ub));
    }
    let neg = |l: f64| {
        let v = yj_llf(x, l);
        if v.is_infinite() { f64::INFINITY } else { -v }
    };
    fminbound(neg, lb, ub, 1.48e-8)
}

// ---------- PreprocessingPipeline ----------

struct Pipeline {
    mean: Vec<f64>,
    scale: Vec<f64>,
    power: Option<(Vec<f64>, Vec<f64>, Vec<f64>)>, // lambdas, scaler mean, scaler scale
    lower: Vec<f64>,
    upper: Vec<f64>,
    train_out: Vec<Vec<f64>>,
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

    fn fit(x: &[Vec<f64>], power: bool, thr: f64) -> Pipeline {
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

    fn transform(&self, x: &[Vec<f64>]) -> Vec<Vec<f64>> {
        self.clip(self.power_apply(self.std_scale(x)))
    }
}

// ---------- the ensemble ----------

fn latin_square(n: usize, rng: &mut PyRandom) -> Vec<Vec<usize>> {
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

fn feature_shuffles(n: usize, n_est: usize, seed: u32) -> Result<Vec<Vec<usize>>> {
    if n_est == 1 {
        return Ok(vec![(0..n).collect()]);
    }
    if n > 4000 {
        bail!("tabicl: more than 4000 features is not ported");
    }
    let mut rng = PyRandom::new(seed);
    Ok(latin_square(n, &mut rng))
}

fn class_shifts(n: usize, n_est: usize) -> Vec<Vec<usize>> {
    let idx: Vec<usize> = (0..n).collect();
    if n_est == 1 {
        return vec![idx];
    }
    // indices[-i:] + indices[:-i]
    (0..n).map(|i| idx[n - i..].iter().chain(&idx[..n - i]).copied().collect()).collect()
}

pub struct Answer {
    pub classes: Vec<i64>,
    pub probas: Vec<Vec<f64>>,
}

/// one ensemble member as the network sees it: X (T, H) row-major, its labels, its class shift
pub struct Member {
    pub x: Vec<f32>,
    pub t: usize,
    pub h: usize,
    pub y: Vec<f32>,
    pub shift: Vec<usize>,
}

/// everything before the network: the encoded table (level 2's first check), the classes, the members
pub struct Prepared {
    pub encoded_train: Vec<Vec<f64>>,
    pub encoded_test: Vec<Vec<f64>>,
    pub classes: Vec<i64>,
    pub members: Vec<Member>,
    pub n_test: usize,
}

pub fn prepare(body: &Value, s: &Settings) -> Result<Prepared> {
    let (encoded_train, encoded_test) = encode(body)?;
    let labels: Vec<i64> = body["labels"]
        .as_array()
        .context("labels")?
        .iter()
        .map(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)).context("an integer label"))
        .collect::<Result<_>>()?;
    if labels.len() != encoded_train.len() || labels.is_empty() {
        bail!("tabicl: {} labels for {} rows", labels.len(), encoded_train.len());
    }
    let mut classes = labels.clone();
    classes.sort();
    classes.dedup();
    let y: Vec<usize> = labels.iter().map(|l| classes.binary_search(l).unwrap()).collect();
    let k = classes.len();
    if k > 10 {
        bail!("tabicl: more than 10 classes is not ported");
    }

    // UniqueFeatureFilter
    let d0 = encoded_train[0].len();
    let mut keep: Vec<usize> = if encoded_train.len() <= 1 {
        (0..d0).collect()
    } else {
        (0..d0)
            .filter(|&j| {
                let mut c = col(&encoded_train, j);
                c.sort_by(|a, b| a.partial_cmp(b).unwrap());
                c.dedup();
                c.len() > 1
            })
            .collect()
    };
    if keep.is_empty() {
        keep.push(0);
    }
    let tr: Vec<Vec<f64>> = encoded_train.iter().map(|r| keep.iter().map(|&j| r[j]).collect()).collect();
    let te: Vec<Vec<f64>> = encoded_test.iter().map(|r| keep.iter().map(|&j| r[j]).collect()).collect();
    let d = keep.len();

    // (feature shuffle, class shift) pairs in a shuffled order, crossed with the norms, first n
    let xs = feature_shuffles(d, s.n_estimators, s.random_state)?;
    let ys = class_shifts(k, s.n_estimators);
    let mut configs: Vec<(Vec<usize>, Vec<usize>)> =
        xs.iter().flat_map(|x| ys.iter().map(move |y| (x.clone(), y.clone()))).collect();
    PyRandom::new(s.random_state).shuffle(&mut configs);
    let chosen: Vec<(&(Vec<usize>, Vec<usize>), bool)> =
        configs.iter().flat_map(|c| [(c, false), (c, true)]).take(s.n_estimators).collect();

    let mut pipes: [Option<Pipeline>; 2] = [None, None];
    for (_, power) in &chosen {
        let i = *power as usize;
        if pipes[i].is_none() {
            pipes[i] = Some(Pipeline::fit(&tr, *power, s.outlier_threshold));
        }
    }
    let t = tr.len() + te.len();
    let mut members = Vec::new();
    for ((fs, cs), power) in &chosen {
        let p = pipes[*power as usize].as_ref().unwrap();
        let test = p.transform(&te);
        let x: Vec<f32> = p.train_out.iter().chain(test.iter()).flat_map(|r| fs.iter().map(|&j| r[j] as f32)).collect();
        let yy: Vec<f32> = y.iter().map(|&c| cs[c] as f32).collect();
        members.push(Member { x, t, h: d, y: yy, shift: cs.clone() });
    }
    Ok(Prepared { encoded_train, encoded_test, classes, members, n_test: te.len() })
}

/// TabICLClassifier(n_estimators, random_state).fit(train, labels).predict_proba(test)
pub fn predict_proba(m: &TabIcl, body: &Value, s: &Settings) -> Result<Answer> {
    let p = prepare(body, s)?;
    let k = p.classes.len();
    let mut avg = vec![vec![0f32; k]; p.n_test];
    for mb in &p.members {
        let out = m.forward_one(&mb.x, mb.t, mb.h, &mb.y)?;
        for (a, o) in avg.iter_mut().zip(&out) {
            for j in 0..k {
                a[j] += o[mb.shift[j]];
            }
        }
    }
    let n = p.members.len() as f32;
    let temp = s.softmax_temperature as f32;
    let probas = avg
        .iter()
        .map(|a| {
            let x: Vec<f32> = a.iter().map(|v| v / n / temp).collect();
            let mx = x.iter().copied().fold(f32::NEG_INFINITY, f32::max);
            let e: Vec<f32> = x.iter().map(|v| (v - mx).exp()).collect();
            let sum: f32 = e.iter().sum();
            let q: Vec<f32> = e.iter().map(|v| v / sum).collect();
            let s2: f32 = q.iter().sum();
            q.iter().map(|v| (v / s2) as f64).collect()
        })
        .collect();
    Ok(Answer { classes: p.classes, probas })
}

/// host.tabicl's contract (tablua core/ports/tabicl.lua, as modal/tabular.py answered it):
/// { probas = { { p0, p1 }, ... } } with p1 the probability of label 1
pub fn host_predict(m: &TabIcl, body: &Value, s: &Settings) -> Result<Value> {
    let t0 = std::time::Instant::now();
    let labels: Vec<i64> = body["labels"].as_array().context("labels")?.iter().filter_map(|v| v.as_i64()).collect();
    let n_test = body["test"]["rows"].as_array().map(|r| r.len()).unwrap_or(0);
    let mut distinct = labels.clone();
    distinct.sort();
    distinct.dedup();
    if distinct.len() < 2 {
        let p = labels.first().map(|&l| l as f64).unwrap_or(0.5);
        return Ok(serde_json::json!({ "probas": vec![[1.0 - p, p]; n_test], "ms": 0 }));
    }
    let a = predict_proba(m, body, s)?;
    let one = a.classes.iter().position(|&c| c == 1).context("tabicl: no label 1 among the classes")?;
    let probas: Vec<[f64; 2]> = a.probas.iter().map(|r| [1.0 - r[one], r[one]]).collect();
    Ok(serde_json::json!({ "probas": probas, "ms": t0.elapsed().as_millis() as u64 }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn latin_square_matches_cpython() {
        // the algorithm of tabicl's Shuffler._latin_squares, run in CPython with Random(0)
        assert_eq!(
            latin_square(5, &mut PyRandom::new(0)),
            vec![vec![4, 1, 3, 2, 0], vec![3, 2, 1, 0, 4], vec![1, 0, 2, 4, 3], vec![0, 3, 4, 1, 2], vec![2, 4, 0, 3, 1]]
        );
        let l8 = latin_square(8, &mut PyRandom::new(0));
        assert_eq!(l8[..2], [vec![4, 5, 7, 6, 3, 0, 2, 1], vec![0, 4, 6, 1, 7, 3, 5, 2]]);
        let mut cfg: Vec<(usize, usize)> = (0..3).flat_map(|a| (0..2).map(move |b| (a, b))).collect();
        PyRandom::new(0).shuffle(&mut cfg);
        assert_eq!(cfg, vec![(2, 0), (1, 0), (0, 1), (0, 0), (2, 1), (1, 1)]);
    }
    #[test]
    fn python_float_repr() {
        assert_eq!(py_float(1.0), "1.0");
        assert_eq!(py_float(0.4286), "0.4286");
        assert_eq!(py_float(1e-5), "1e-05");
        assert_eq!(py_float(1.5e20), "1.5e+20");
    }
}
