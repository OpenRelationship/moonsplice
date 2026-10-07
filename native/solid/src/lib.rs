//! Solids as data (.robot/docs/solids.robot): a tree of plain values that Manifold builds into a watertight
//! mesh. Authored Z-up in metres, as CAD is (OpenSCAD, LuaCAD); written out Y-up for Bevy.
//!
//!   { op = "difference",
//!     { op = "cylinder", h = 1.2, r = 0.45 },
//!     { op = "cylinder", h = 1.3, r = 0.4, move = { 0, 0, 0.1 } } }
//!
//! Every node may carry `scale`, `rotate` (degrees about x, y, z) and `move`, applied in that order.
//! Children are the node's positional entries (or `children`). A profile (2D) is a node of the 2D
//! ops or a plain list of points. `build` refuses with a reason a tree that is malformed; the
//! measurements say what a well-formed one came out as (empty, in parts, how big, watertight).

use anyhow::{anyhow, bail, Context, Result};
use manifold3d::{CrossSection, JoinType, Manifold};
use serde_json::{json, Value};

const SEG: i32 = 48;

fn num(v: &Value, k: &str, d: f64) -> f64 {
    v.get(k).and_then(|x| x.as_f64()).unwrap_or(d)
}

fn vec3(v: &Value, k: &str) -> Option<[f64; 3]> {
    let x = v.get(k)?;
    if let Some(s) = x.as_f64() {
        return Some([s, s, s]);
    }
    let a = x.as_array()?;
    let g = |i: usize| a.get(i).and_then(|y| y.as_f64()).unwrap_or(0.0);
    Some([g(0), g(1), g(2)])
}

fn segs(v: &Value) -> i32 {
    v.get("segments").and_then(|x| x.as_i64()).map(|s| s.clamp(3, 512) as i32).unwrap_or(SEG)
}

/// a node's children: `children`, or its positional entries ("1", "2", ... once it has been JSON)
fn children(v: &Value) -> Vec<&Value> {
    if let Some(a) = v.get("children").and_then(|c| c.as_array()) {
        return a.iter().collect();
    }
    if let Some(a) = v.as_array() {
        return a.iter().collect();
    }
    let mut out: Vec<(usize, &Value)> = v
        .as_object()
        .map(|o| o.iter().filter_map(|(k, c)| k.parse::<usize>().ok().map(|i| (i, c))).collect())
        .unwrap_or_default();
    out.sort_by_key(|(i, _)| *i);
    out.into_iter().map(|(_, c)| c).collect()
}

fn child(v: &Value, what: &str) -> Result<Value> {
    if let Some(c) = v.get("child") {
        return Ok(c.clone());
    }
    children(v).first().map(|c| (*c).clone()).ok_or_else(|| anyhow!("{what} needs a child"))
}

fn op(v: &Value) -> &str {
    v.get("op").and_then(|x| x.as_str()).unwrap_or(if v.is_array() { "union" } else { "" })
}

fn place(m: Manifold, v: &Value) -> Manifold {
    let mut m = m;
    if let Some(s) = vec3(v, "scale") {
        m = m.scale(s[0], s[1], s[2]);
    }
    if let Some(r) = vec3(v, "rotate") {
        m = m.rotate(r[0], r[1], r[2]);
    }
    if let Some(t) = vec3(v, "move") {
        m = m.translate(t[0], t[1], t[2]);
    }
    m
}

fn place2(c: CrossSection, v: &Value) -> CrossSection {
    let mut c = c;
    if let Some(x) = v.get("scale") {
        let (sx, sy) = match x.as_array() {
            Some(a) => (a.first().and_then(|y| y.as_f64()).unwrap_or(1.0), a.get(1).and_then(|y| y.as_f64()).unwrap_or(1.0)),
            None => (x.as_f64().unwrap_or(1.0), x.as_f64().unwrap_or(1.0)),
        };
        c = c.scale(sx, sy);
    }
    if let Some(r) = v.get("rotate").and_then(|x| x.as_f64()) {
        c = c.rotate(r);
    }
    if let Some(a) = v.get("move").and_then(|x| x.as_array()) {
        let g = |i: usize| a.get(i).and_then(|y| y.as_f64()).unwrap_or(0.0);
        c = c.translate(g(0), g(1));
    }
    c
}

fn points(v: &Value) -> Result<Vec<[f64; 2]>> {
    let a = v.as_array().context("points are a list of {x, y}")?;
    let pts: Vec<[f64; 2]> = a
        .iter()
        .map(|p| {
            let q = p.as_array().context("a point is {x, y}")?;
            Ok([q.first().and_then(|x| x.as_f64()).context("a point's x")?, q.get(1).and_then(|x| x.as_f64()).context("a point's y")?])
        })
        .collect::<Result<_>>()?;
    if pts.len() < 3 {
        bail!("a polygon needs at least 3 points, not {}", pts.len());
    }
    Ok(pts)
}

/// a 2D node: circle, square, polygon, offset, and the booleans and hull of profiles
pub fn profile(v: &Value) -> Result<CrossSection> {
    if v.as_array().map(|a| a.first().map(|p| p.is_array()).unwrap_or(false)).unwrap_or(false) {
        return Ok(CrossSection::from_simple_polygon(&points(v)?));
    }
    let c = match op(v) {
        "circle" => CrossSection::circle(num(v, "r", 0.5), segs(v)),
        "square" | "rect" => {
            let (x, y) = match v.get("size") {
                Some(Value::Array(a)) => (a.first().and_then(|q| q.as_f64()).unwrap_or(1.0), a.get(1).and_then(|q| q.as_f64()).unwrap_or(1.0)),
                Some(s) => (s.as_f64().unwrap_or(1.0), s.as_f64().unwrap_or(1.0)),
                None => (1.0, 1.0),
            };
            CrossSection::square(x, y, v.get("center").and_then(|b| b.as_bool()).unwrap_or(true))
        }
        "polygon" => CrossSection::from_simple_polygon(&points(v.get("points").context("polygon needs points")?)?),
        "offset" => {
            let join = match v.get("join").and_then(|j| j.as_str()).unwrap_or("round") {
                "square" => JoinType::Square,
                "miter" => JoinType::Miter,
                "bevel" => JoinType::Bevel,
                _ => JoinType::Round,
            };
            profile(&child(v, "offset")?)?.offset(num(v, "delta", 0.05), join, 2.0, segs(v))
        }
        "union" | "difference" | "intersection" | "hull" => {
            let cs: Vec<CrossSection> = children(v).into_iter().map(profile).collect::<Result<_>>()?;
            if cs.is_empty() {
                bail!("{} of profiles needs children", op(v));
            }
            match op(v) {
                "union" => CrossSection::batch_union(&cs),
                "hull" => CrossSection::batch_hull(&cs),
                o => {
                    let mut it = cs.into_iter();
                    let first = it.next().unwrap();
                    it.fold(first, |a, b| if o == "difference" { a.difference(&b) } else { a.intersection(&b) })
                }
            }
        }
        "" => bail!("a profile needs op (circle, square, polygon, offset, union, difference, intersection, hull) or a list of points"),
        o => bail!("no 2D op {o:?} (circle, square, polygon, offset, union, difference, intersection, hull)"),
    };
    Ok(place2(c, v))
}

fn profile_of(v: &Value) -> Result<CrossSection> {
    profile(v.get("profile").ok_or_else(|| anyhow!("{} needs profile", op(v)))?)
}

/// a 3D node
pub fn solid(v: &Value) -> Result<Manifold> {
    let center = v.get("center").and_then(|b| b.as_bool()).unwrap_or(true);
    let m = match op(v) {
        "cube" | "box" => {
            let s = vec3(v, "size").unwrap_or([1.0, 1.0, 1.0]);
            Manifold::cube(s[0], s[1], s[2], center)
        }
        "sphere" => Manifold::sphere(num(v, "r", 0.5), segs(v)),
        "cylinder" | "cone" => {
            let r = num(v, "r", 0.5);
            let r1 = num(v, "r1", r);
            let r2 = num(v, "r2", if op(v) == "cone" { 0.0 } else { r });
            Manifold::cylinder(num(v, "h", 1.0), r1, r2, segs(v), center)
        }
        "torus" => {
            let (r, tube) = (num(v, "r", 0.5), num(v, "tube", 0.1));
            if tube >= r {
                bail!("torus: tube ({tube}) must be smaller than r ({r})");
            }
            Manifold::revolve(&CrossSection::circle(tube, segs(v) / 2).translate(r, 0.0), segs(v), 360.0)
        }
        "capsule" => {
            let (r, h) = (num(v, "r", 0.25), num(v, "h", 1.0));
            let a = Manifold::sphere(r, segs(v)).translate(0.0, 0.0, -h / 2.0);
            let b = Manifold::sphere(r, segs(v)).translate(0.0, 0.0, h / 2.0);
            Manifold::batch_hull(&[a, b])
        }
        "extrude" => {
            let p = profile_of(v)?;
            let (sx, sy) = match v.get("scale_top") {
                Some(Value::Array(a)) => (a.first().and_then(|q| q.as_f64()).unwrap_or(1.0), a.get(1).and_then(|q| q.as_f64()).unwrap_or(1.0)),
                Some(s) => (s.as_f64().unwrap_or(1.0), s.as_f64().unwrap_or(1.0)),
                None => (1.0, 1.0),
            };
            let twist = num(v, "twist", 0.0);
            let slices = v.get("slices").and_then(|x| x.as_i64()).unwrap_or(if twist != 0.0 { 32 } else { 0 }) as i32;
            let h = num(v, "h", 1.0);
            let m = Manifold::extrude_with_options(&p, h, slices, twist, sx, sy);
            if center { m.translate(0.0, 0.0, -h / 2.0) } else { m }
        }
        "revolve" => Manifold::revolve(&profile_of(v)?, segs(v), num(v, "degrees", 360.0)),
        "union" | "difference" | "intersection" | "hull" | "group" => {
            let ms: Vec<Manifold> = children(v).into_iter().map(solid).collect::<Result<_>>()?;
            if ms.is_empty() {
                bail!("{} needs children", op(v));
            }
            match op(v) {
                "union" => Manifold::batch_union(&ms),
                "hull" => Manifold::batch_hull(&ms),
                "group" => Manifold::compose(&ms),
                "difference" => Manifold::batch_difference(&ms),
                _ => {
                    let mut it = ms.into_iter();
                    let first = it.next().unwrap();
                    it.fold(first, |a, b| a.intersection(&b))
                }
            }
        }
        "minkowski" => {
            let cs = children(v);
            if cs.len() != 2 {
                bail!("minkowski takes two children, not {}", cs.len());
            }
            solid(cs[0])?.minkowski_sum(&solid(cs[1])?)
        }
        "smooth" => {
            let c = solid(&child(v, "smooth")?)?;
            let refine = v.get("refine").and_then(|x| x.as_i64()).unwrap_or(3).clamp(1, 8) as i32;
            c.smooth_out(num(v, "angle", 60.0), num(v, "smoothness", 0.4)).refine(refine)
        }
        "repeat" => {
            // n copies, each `step` (move / rotate / scale) further on from the last
            let base = solid(&child(v, "repeat")?)?;
            let n = v.get("n").and_then(|x| x.as_i64()).unwrap_or(2).clamp(1, 512) as usize;
            let step = v.get("step").cloned().unwrap_or(json!({}));
            let mut cur = base;
            let mut all = Vec::with_capacity(n);
            for _ in 0..n {
                all.push(cur.clone());
                cur = place(cur, &step);
            }
            if v.get("union").and_then(|b| b.as_bool()).unwrap_or(true) { Manifold::batch_union(&all) } else { Manifold::compose(&all) }
        }
        "radial" => {
            // n copies round the z axis
            let base = solid(&child(v, "radial")?)?;
            let n = v.get("n").and_then(|x| x.as_i64()).unwrap_or(6).clamp(1, 512) as usize;
            let all: Vec<Manifold> = (0..n).map(|i| base.rotate(0.0, 0.0, 360.0 * i as f64 / n as f64)).collect();
            Manifold::batch_union(&all)
        }
        "mirror" => {
            let c = solid(&child(v, "mirror")?)?;
            let n = vec3(v, "normal").unwrap_or([1.0, 0.0, 0.0]);
            let m = c.mirror(n);
            if v.get("keep").and_then(|b| b.as_bool()).unwrap_or(true) { c.union(&m) } else { m }
        }
        "trim" => {
            let c = solid(&child(v, "trim")?)?;
            c.trim_by_plane(vec3(v, "normal").unwrap_or([0.0, 0.0, 1.0]), num(v, "offset", 0.0))
        }
        "" => bail!("a solid needs op: cube sphere cylinder cone torus capsule extrude revolve union difference intersection hull group minkowski smooth repeat radial mirror trim"),
        o => bail!("no op {o:?}: cube sphere cylinder cone torus capsule extrude revolve union difference intersection hull group minkowski smooth repeat radial mirror trim"),
    };
    m.status().map_err(|e| anyhow!("{} failed in Manifold: {e:?}", op(v)))?;
    Ok(place(m, v))
}

/// Z-up (authored) to Y-up (Bevy): (x, y, z) -> (x, z, -y)
fn yup(p: [f32; 3]) -> [f32; 3] {
    [p[0], p[2], -p[1]]
}

/// positions and normals (Y-up) and triangles
pub struct Mesh {
    pub pos: Vec<[f32; 3]>,
    pub norm: Vec<[f32; 3]>,
    pub tri: Vec<u32>,
}

pub fn mesh(m: &Manifold, sharp_degrees: f64) -> Mesh {
    // Manifold counts property channels after the position: normals at 0 land in vertex properties 3..6
    let m = m.calculate_normals(0, sharp_degrees);
    let (props, n, tri) = m.to_mesh_f32_with_normals(0);
    let nv = if n == 0 { 0 } else { props.len() / n };
    let mut pos = Vec::with_capacity(nv);
    let mut norm = Vec::with_capacity(nv);
    for i in 0..nv {
        let p = &props[i * n..];
        pos.push(yup([p[0], p[1], p[2]]));
        norm.push(if n >= 6 { yup([p[3], p[4], p[5]]) } else { [0.0, 1.0, 0.0] });
    }
    Mesh { pos, norm, tri }
}

/// what the solid came out as, Y-up, for the agent to check against what it meant
pub fn measure(m: &Manifold) -> Value {
    let parts = m.decompose().len();
    let (min, max) = match m.bounding_box() {
        Some(b) => (b.min(), b.max()),
        None => ([0.0; 3], [0.0; 3]),
    };
    let y = |p: [f64; 3]| [p[0], p[2], -p[1]];
    let (a, b) = (y(min), y(max));
    let lo = [a[0].min(b[0]), a[1].min(b[1]), a[2].min(b[2])];
    let hi = [a[0].max(b[0]), a[1].max(b[1]), a[2].max(b[2])];
    json!({
        "empty": m.is_empty(),
        "parts": parts,
        "volume": m.volume(),
        "area": m.surface_area(),
        "triangles": m.num_tri(),
        "genus": m.genus(),
        "watertight": m.status().is_ok() && !m.is_empty(),
        "min": lo, "max": hi,
        "size": [hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]],
    })
}

/// the mesh as Moonsplice's renderer reads it: "MSH1", vertex and triangle counts (u32 LE), then
/// per vertex position and normal (6 f32), then the triangles (3 u32 each)
pub fn write_msh(mesh: &Mesh, path: &std::path::Path) -> Result<()> {
    let mut b = Vec::with_capacity(12 + mesh.pos.len() * 24 + mesh.tri.len() * 4);
    b.extend_from_slice(b"MSH1");
    b.extend_from_slice(&(mesh.pos.len() as u32).to_le_bytes());
    b.extend_from_slice(&((mesh.tri.len() / 3) as u32).to_le_bytes());
    for (p, n) in mesh.pos.iter().zip(&mesh.norm) {
        for x in p.iter().chain(n) {
            b.extend_from_slice(&x.to_le_bytes());
        }
    }
    for i in &mesh.tri {
        b.extend_from_slice(&i.to_le_bytes());
    }
    write_whole(path, &b)
}

/// a glTF 2.0 file (buffer embedded) for anything else that wants the solid
pub fn write_gltf(mesh: &Mesh, path: &std::path::Path) -> Result<()> {
    use base64::Engine;
    let mut buf = Vec::new();
    for p in &mesh.pos {
        for x in p {
            buf.extend_from_slice(&x.to_le_bytes());
        }
    }
    let nbytes_pos = buf.len();
    for n in &mesh.norm {
        for x in n {
            buf.extend_from_slice(&x.to_le_bytes());
        }
    }
    let nbytes_norm = buf.len() - nbytes_pos;
    for i in &mesh.tri {
        buf.extend_from_slice(&i.to_le_bytes());
    }
    let nbytes_idx = buf.len() - nbytes_pos - nbytes_norm;
    let mut lo = [f32::MAX; 3];
    let mut hi = [f32::MIN; 3];
    for p in &mesh.pos {
        for k in 0..3 {
            lo[k] = lo[k].min(p[k]);
            hi[k] = hi[k].max(p[k]);
        }
    }
    let doc = json!({
        "asset": { "version": "2.0", "generator": "moonsplice-solid" },
        "scene": 0, "scenes": [{ "nodes": [0] }], "nodes": [{ "mesh": 0 }],
        "meshes": [{ "primitives": [{ "attributes": { "POSITION": 0, "NORMAL": 1 }, "indices": 2, "material": 0 }] }],
        "materials": [{ "pbrMetallicRoughness": { "baseColorFactor": [0.85, 0.85, 0.85, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.6 } }],
        "buffers": [{ "byteLength": buf.len(), "uri": format!("data:application/octet-stream;base64,{}", base64::engine::general_purpose::STANDARD.encode(&buf)) }],
        "bufferViews": [
            { "buffer": 0, "byteOffset": 0, "byteLength": nbytes_pos, "target": 34962 },
            { "buffer": 0, "byteOffset": nbytes_pos, "byteLength": nbytes_norm, "target": 34962 },
            { "buffer": 0, "byteOffset": nbytes_pos + nbytes_norm, "byteLength": nbytes_idx, "target": 34963 }
        ],
        "accessors": [
            { "bufferView": 0, "componentType": 5126, "count": mesh.pos.len(), "type": "VEC3", "min": lo, "max": hi },
            { "bufferView": 1, "componentType": 5126, "count": mesh.norm.len(), "type": "VEC3" },
            { "bufferView": 2, "componentType": 5125, "count": mesh.tri.len(), "type": "SCALAR" }
        ]
    });
    write_whole(path, doc.to_string().as_bytes())
}

/// write via a temporary file and rename, so a cache never holds half a mesh
fn write_whole(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// build a tree and write it: `out` is the .msh path (a .gltf goes beside it); the measurements
pub fn build(tree: &Value, out: &std::path::Path) -> Result<Value> {
    let m = solid(tree)?;
    let mut info = measure(&m);
    if m.is_empty() {
        bail!("the solid is empty (a difference that removed everything, or an intersection of things that do not meet)");
    }
    let sharp = num(tree, "sharp", 40.0);
    let mesh = mesh(&m, sharp);
    write_msh(&mesh, out)?;
    write_gltf(&mesh, &out.with_extension("gltf"))?;
    info["src"] = json!(out.display().to_string());
    Ok(info)
}
