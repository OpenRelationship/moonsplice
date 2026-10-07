//! The three parity levels against tablua-local's fixtures (tl/tabicl_parity.py):
//! 1 the forward pass alone, 2 the ensemble from the encoded table, 3 raw rows to probas.

use crate::model::TabIcl;
use anyhow::{Context, Result};
use serde_json::Value;

fn f32s(v: &Value) -> Vec<f32> {
    v.as_array().map(|a| a.iter().map(|x| x.as_f64().unwrap_or(f64::NAN) as f32).collect()).unwrap_or_default()
}

/// largest |Δ| over every forward's logits
pub fn level1(m: &TabIcl, fx: &Value) -> Result<f64> {
    let mut worst = 0f64;
    for f in fx["forwards"].as_array().context("forwards")? {
        let xs = f["X"].as_array().context("X")?;
        let ys = f["y_train"].as_array().context("y_train")?;
        let outs = f["out"].as_array().context("out")?;
        for ((xb, yb), ob) in xs.iter().zip(ys).zip(outs) {
            let rows = xb.as_array().context("rows")?;
            let t = rows.len();
            let h = rows[0].as_array().map(|r| r.len()).unwrap_or(0);
            let x: Vec<f32> = rows.iter().flat_map(f32s).collect();
            let got = m.forward_one(&x, t, h, &f32s(yb))?;
            for (gr, wr) in got.iter().zip(ob.as_array().context("out rows")?) {
                for (g, w) in gr.iter().zip(f32s(wr)) {
                    worst = worst.max((*g as f64 - w as f64).abs());
                }
            }
        }
    }
    Ok(worst)
}

/// the fixture's raw table as tablua's body ({ train = { columns, rows }, labels, categorical, test })
fn body(fx: &Value) -> Value {
    let r = &fx["raw"];
    serde_json::json!({
        "train": { "columns": r["columns"], "rows": r["train"] },
        "test": { "columns": r["columns"], "rows": r["test"] },
        "labels": r["labels"],
        "categorical": r["categorical"],
    })
}

fn settings(fx: &Value) -> crate::prep::Settings {
    let st = &fx["settings"];
    crate::prep::Settings {
        n_estimators: st["n_estimators"].as_u64().unwrap_or(4) as usize,
        random_state: st["random_state"].as_u64().unwrap_or(0) as u32,
        softmax_temperature: st["softmax_temperature"].as_f64().unwrap_or(0.9),
        outlier_threshold: st["outlier_threshold"].as_f64().unwrap_or(4.0),
    }
}

/// level 2: the encoded table, and every member's X and labels against the forwards' (matched by
/// labels then nearest X, since the order of the norm groups is Python's set order)
pub fn level2(fx: &Value) -> Result<(f64, f64, usize, usize)> {
    let p = crate::prep::prepare(&body(fx), &settings(fx))?;
    let mut enc = 0f64;
    for (mine, theirs) in [(&p.encoded_train, &fx["encoded"]["train"]), (&p.encoded_test, &fx["encoded"]["test"])] {
        for (a, b) in mine.iter().zip(theirs.as_array().context("encoded")?) {
            for (x, y) in a.iter().zip(f32s(b)) {
                enc = enc.max((x - y as f64).abs());
            }
        }
    }
    let mut theirs: Vec<(Vec<f32>, Vec<f32>)> = Vec::new();
    for f in fx["forwards"].as_array().context("forwards")? {
        for (xb, yb) in f["X"].as_array().context("X")?.iter().zip(f["y_train"].as_array().context("y")?) {
            theirs.push((xb.as_array().unwrap().iter().flat_map(f32s).collect(), f32s(yb)));
        }
    }
    let mut worst = 0f64;
    let mut matched = 0;
    for mb in &p.members {
        let best = theirs
            .iter()
            .filter(|(x, y)| *y == mb.y && x.len() == mb.x.len())
            .map(|(x, _)| x.iter().zip(&mb.x).map(|(a, b)| (*a as f64 - *b as f64).abs()).fold(0f64, f64::max))
            .fold(f64::INFINITY, f64::min);
        if best.is_finite() {
            matched += 1;
            worst = worst.max(best);
        } else {
            worst = f64::INFINITY;
        }
    }
    Ok((enc, worst, matched, theirs.len()))
}

/// level 3: raw rows to predict_proba
pub fn level3(m: &TabIcl, fx: &Value) -> Result<f64> {
    let a = crate::prep::predict_proba(m, &body(fx), &settings(fx))?;
    let mut worst = 0f64;
    for (r, w) in a.probas.iter().zip(fx["probas"].as_array().context("probas")?) {
        for (x, y) in r.iter().zip(f32s(w)) {
            worst = worst.max((x - y as f64).abs());
        }
    }
    Ok(worst)
}
