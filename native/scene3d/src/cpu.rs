use crate::mesh::{Mesh, Vertex};
use crate::scene::{Frame, Prim};
use glam::{Mat3, Vec3, Vec4Swizzles};
use std::collections::HashMap;

fn shade(n: Vec3, frame: &Frame, color: [f32; 4]) -> [u8; 4] {
    let l = (-frame.light_dir).normalize_or_zero();
    let ndl = n.normalize_or_zero().dot(l).max(0.0);
    let lit = frame.ambient + frame.light_color * frame.light_int * ndl;
    let a = color[3].clamp(0.0, 1.0);
    let rgb = [
        (color[0] * lit.x * a).clamp(0.0, 1.0),
        (color[1] * lit.y * a).clamp(0.0, 1.0),
        (color[2] * lit.z * a).clamp(0.0, 1.0),
    ];
    [
        (rgb[0] * 255.0) as u8,
        (rgb[1] * 255.0) as u8,
        (rgb[2] * 255.0) as u8,
        (a * 255.0) as u8,
    ]
}

fn edge(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) -> f32 {
    (cx - ax) * (by - ay) - (cy - ay) * (bx - ax)
}

fn draw_mesh(
    mesh: &Mesh,
    model: glam::Mat4,
    view_proj: glam::Mat4,
    color: [f32; 4],
    frame: &Frame,
    w: usize,
    h: usize,
    color_buf: &mut [u8],
    depth: &mut [f32],
) {
    let mvp = view_proj * model;
    let nrm_mat = Mat3::from_mat4(model).inverse().transpose();
    let wf = w as f32;
    let hf = h as f32;

    let xform = |v: &Vertex| -> Option<(f32, f32, f32, Vec3)> {
        let p = mvp * glam::Vec4::new(v.pos[0], v.pos[1], v.pos[2], 1.0);
        if p.w <= 1e-5 {
            return None;
        }
        let ndc = p.xyz() / p.w;
        if ndc.z < 0.0 || ndc.z > 1.0 {
            return None;
        }
        let sx = (ndc.x * 0.5 + 0.5) * wf;
        let sy = (0.5 - ndc.y * 0.5) * hf;
        let n = (nrm_mat * Vec3::from(v.nrm)).normalize_or_zero();
        Some((sx, sy, ndc.z, n))
    };

    for tri in mesh.indices.chunks(3) {
        if tri.len() < 3 {
            break;
        }
        let Some(a) = mesh.vertices.get(tri[0] as usize).and_then(xform) else {
            continue;
        };
        let Some(b) = mesh.vertices.get(tri[1] as usize).and_then(xform) else {
            continue;
        };
        let Some(c) = mesh.vertices.get(tri[2] as usize).and_then(xform) else {
            continue;
        };
        let area = edge(a.0, a.1, b.0, b.1, c.0, c.1);
        if area <= 1e-4 {
            continue; // backface or degenerate
        }
        let minx = a.0.min(b.0).min(c.0).floor().max(0.0) as usize;
        let maxx = a.0.max(b.0).max(c.0).ceil().min(wf - 1.0) as usize;
        let miny = a.1.min(b.1).min(c.1).floor().max(0.0) as usize;
        let maxy = a.1.max(b.1).max(c.1).ceil().min(hf - 1.0) as usize;
        let inv = 1.0 / area;
        for y in miny..=maxy {
            for x in minx..=maxx {
                let px = x as f32 + 0.5;
                let py = y as f32 + 0.5;
                let w0 = edge(b.0, b.1, c.0, c.1, px, py) * inv;
                let w1 = edge(c.0, c.1, a.0, a.1, px, py) * inv;
                let w2 = edge(a.0, a.1, b.0, b.1, px, py) * inv;
                if w0 < 0.0 || w1 < 0.0 || w2 < 0.0 {
                    continue;
                }
                let z = w0 * a.2 + w1 * b.2 + w2 * c.2;
                let di = y * w + x;
                if z >= depth[di] {
                    continue;
                }
                depth[di] = z;
                let n = (a.3 * w0 + b.3 * w1 + c.3 * w2).normalize_or_zero();
                let px4 = shade(n, frame, color);
                let o = di * 4;
                color_buf[o] = px4[0];
                color_buf[o + 1] = px4[1];
                color_buf[o + 2] = px4[2];
                color_buf[o + 3] = px4[3];
            }
        }
    }
}

pub fn render(
    frame: &Frame,
    cube: &Mesh,
    sphere: &Mesh,
    meshes: &HashMap<i64, Mesh>,
    w: u32,
    h: u32,
    out: &mut [u8],
) {
    let width = w as usize;
    let height = h as usize;
    let clear = [
        (frame.clear[0] * frame.clear[3] * 255.0) as u8,
        (frame.clear[1] * frame.clear[3] * 255.0) as u8,
        (frame.clear[2] * frame.clear[3] * 255.0) as u8,
        (frame.clear[3] * 255.0) as u8,
    ];
    for px in out.chunks_exact_mut(4) {
        px.copy_from_slice(&clear);
    }
    let mut depth = vec![1.0f32; width * height];
    let vp = frame.view_proj(w as f32 / h.max(1) as f32);
    for inst in &frame.instances {
        let mesh = match inst.prim {
            Prim::Cube => cube,
            Prim::Sphere => sphere,
            Prim::Handle(id) => match meshes.get(&id) {
                Some(m) => m,
                None => continue,
            },
        };
        draw_mesh(
            mesh,
            inst.model(),
            vp,
            inst.color,
            frame,
            width,
            height,
            out,
            &mut depth,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mesh;
    use crate::scene::{Instance, Prim};

    #[test]
    fn cube_covers_center() {
        let mut frame = Frame::default();
        frame.instances.push(Instance {
            prim: Prim::Cube,
            x: 0.0,
            y: 0.0,
            z: 0.0,
            yaw: 0.4,
            pitch: -0.25,
            roll: 0.0,
            sx: 1.0,
            sy: 1.0,
            sz: 1.0,
            color: [0.3, 0.5, 1.0, 1.0],
        });
        let mut out = vec![0u8; 64 * 64 * 4];
        render(
            &frame,
            &mesh::unit_cube(),
            &mesh::unit_sphere(8, 12),
            &HashMap::new(),
            64,
            64,
            &mut out,
        );
        let i = (32 * 64 + 32) * 4;
        assert!(out[i + 3] > 0, "center pixel should be covered");
    }
}
