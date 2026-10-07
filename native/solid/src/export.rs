//! Writing a mesh out: Moonsplice's own MSH1 for the renderer, glTF for anything else, each written
//! whole or not at all.

use anyhow::{Context, Result};
use serde_json::json;

use super::Mesh;

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
