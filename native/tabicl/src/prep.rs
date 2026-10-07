//! What `TabICLClassifier` (tabicl 2.2.0) does around the network, in float64 as numpy does it:
//! the table framed as tablua's server framed it (modal/tabular.py), ordinal-encoded categoricals
//! first, constant columns dropped, then an ensemble of members, each a normalisation
//! ("none" | "power", Yeo-Johnson as scipy 1.18.1 fits it) with a feature permutation (a random
//! Latin square drawn by CPython's MT19937) and a class rotation; the members' logits are
//! un-rotated, averaged, and softened at the temperature.

mod ensemble;
mod yeojohnson;

use crate::model::TabIcl;
use crate::pyrand::PyRandom;
use anyhow::{bail, Context, Result};
use serde_json::Value;
use ensemble::{class_shifts, feature_shuffles, Pipeline};
use yeojohnson::col;

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
    use super::ensemble::latin_square;

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
