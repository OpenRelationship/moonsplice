//! Column statistics as numpy computes them, and Yeo-Johnson as scipy.stats.yeojohnson fits and
//! applies it, in float64.

// ---------- column statistics ----------

pub(super) fn col(x: &[Vec<f64>], j: usize) -> Vec<f64> {
    x.iter().map(|r| r[j]).collect()
}
pub(super) fn mean(v: &[f64]) -> f64 {
    v.iter().sum::<f64>() / v.len() as f64
}
/// numpy's var/std with ddof
pub(super) fn var(v: &[f64], ddof: usize) -> f64 {
    let m = mean(v);
    v.iter().map(|x| (x - m) * (x - m)).sum::<f64>() / (v.len() - ddof) as f64
}
pub(super) fn nan_stats(v: &[f64], ddof: usize) -> (f64, f64) {
    let ok: Vec<f64> = v.iter().copied().filter(|x| !x.is_nan()).collect();
    let d = if ok.len() > ddof { ddof } else { 0 };
    (mean(&ok), var(&ok, d).sqrt())
}
/// sklearn's _is_constant_feature
pub(super) fn is_constant(var: f64, mean: f64, n: usize) -> bool {
    let eps = f64::EPSILON;
    let n = n as f64;
    var <= n * eps * var + (n * mean * eps).powi(2)
}

// ---------- Yeo-Johnson, as scipy.stats.yeojohnson fits and applies it ----------

pub(super) fn yj(x: f64, l: f64) -> f64 {
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
pub(super) fn yj_normmax(x: &[f64]) -> f64 {
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
