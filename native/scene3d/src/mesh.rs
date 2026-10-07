use glam::{Mat3, Mat4, Vec3, Vec4Swizzles};

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct Vertex {
    pub pos: [f32; 3],
    pub nrm: [f32; 3],
}

#[derive(Clone, Default)]
pub struct Mesh {
    pub vertices: Vec<Vertex>,
    pub indices: Vec<u32>,
}

impl Mesh {
    pub fn is_empty(&self) -> bool {
        self.indices.is_empty()
    }

    fn push_face(&mut self, corners: [[f32; 3]; 4], n: [f32; 3]) {
        let base = self.vertices.len() as u32;
        for pos in corners {
            self.vertices.push(Vertex { pos, nrm: n });
        }
        self.indices
            .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
    }
}

pub fn unit_cube() -> Mesh {
    let mut m = Mesh::default();
    let p = 0.5f32;
    m.push_face(
        [[-p, -p, p], [p, -p, p], [p, p, p], [-p, p, p]],
        [0.0, 0.0, 1.0],
    );
    m.push_face(
        [[p, -p, -p], [-p, -p, -p], [-p, p, -p], [p, p, -p]],
        [0.0, 0.0, -1.0],
    );
    m.push_face(
        [[-p, p, p], [p, p, p], [p, p, -p], [-p, p, -p]],
        [0.0, 1.0, 0.0],
    );
    m.push_face(
        [[-p, -p, -p], [p, -p, -p], [p, -p, p], [-p, -p, p]],
        [0.0, -1.0, 0.0],
    );
    m.push_face(
        [[p, -p, p], [p, -p, -p], [p, p, -p], [p, p, p]],
        [1.0, 0.0, 0.0],
    );
    m.push_face(
        [[-p, -p, -p], [-p, -p, p], [-p, p, p], [-p, p, -p]],
        [-1.0, 0.0, 0.0],
    );
    m
}

pub fn unit_sphere(lat: u32, lon: u32) -> Mesh {
    let lat = lat.max(3);
    let lon = lon.max(3);
    let mut m = Mesh::default();
    for y in 0..=lat {
        let v = y as f32 / lat as f32;
        let phi = v * std::f32::consts::PI;
        let sy = phi.sin();
        let cy = phi.cos();
        for x in 0..=lon {
            let u = x as f32 / lon as f32;
            let theta = u * std::f32::consts::TAU;
            let px = sy * theta.cos();
            let pz = sy * theta.sin();
            m.vertices.push(Vertex {
                pos: [px * 0.5, cy * 0.5, pz * 0.5],
                nrm: [px, cy, pz],
            });
        }
    }
    let stride = lon + 1;
    for y in 0..lat {
        for x in 0..lon {
            let i0 = y * stride + x;
            let i1 = i0 + 1;
            let i2 = i0 + stride;
            let i3 = i2 + 1;
            m.indices.extend_from_slice(&[i0, i2, i1, i1, i2, i3]);
        }
    }
    m
}

pub fn load_gltf(path: &str) -> Result<Mesh, String> {
    let (doc, buffers, _images) = gltf::import(path).map_err(|e| e.to_string())?;
    let mut out = Mesh::default();
    let scene = doc
        .default_scene()
        .or_else(|| doc.scenes().next())
        .ok_or_else(|| "gltf has no scene".to_string())?;
    for node in scene.nodes() {
        visit_node(node, Mat4::IDENTITY, &buffers, &mut out)?;
    }
    if out.is_empty() {
        return Err("gltf has no triangles".into());
    }
    Ok(out)
}

fn visit_node(
    node: gltf::Node<'_>,
    parent: Mat4,
    buffers: &[gltf::buffer::Data],
    out: &mut Mesh,
) -> Result<(), String> {
    let local = Mat4::from_cols_array_2d(&node.transform().matrix());
    let world = parent * local;
    if let Some(mesh) = node.mesh() {
        for prim in mesh.primitives() {
            append_primitive(&prim, world, buffers, out)?;
        }
    }
    for child in node.children() {
        visit_node(child, world, buffers, out)?;
    }
    Ok(())
}

fn append_primitive(
    prim: &gltf::Primitive<'_>,
    world: Mat4,
    buffers: &[gltf::buffer::Data],
    out: &mut Mesh,
) -> Result<(), String> {
    let reader = prim.reader(|b| buffers.get(b.index()).map(|d| d.0.as_slice()));
    let positions: Vec<[f32; 3]> = reader
        .read_positions()
        .ok_or_else(|| "gltf primitive missing POSITION".to_string())?
        .collect();
    let normals: Option<Vec<[f32; 3]>> = reader.read_normals().map(|n| n.collect());
    let indices: Vec<u32> = if let Some(idx) = reader.read_indices() {
        idx.into_u32().collect()
    } else {
        (0..positions.len() as u32).collect()
    };
    let nrm_mat = Mat3::from_mat4(world).inverse().transpose();
    let base = out.vertices.len() as u32;
    for (i, p) in positions.iter().enumerate() {
        let wp = (world * glam::Vec4::new(p[0], p[1], p[2], 1.0)).xyz();
        let n = if let Some(ns) = &normals {
            let raw = ns.get(i).copied().unwrap_or([0.0, 1.0, 0.0]);
            (nrm_mat * Vec3::from(raw)).normalize_or_zero()
        } else {
            Vec3::Y
        };
        out.vertices.push(Vertex {
            pos: wp.into(),
            nrm: n.into(),
        });
    }
    if normals.is_none() {
        for tri in indices.chunks(3) {
            if tri.len() < 3 {
                break;
            }
            let a = Vec3::from(out.vertices[(base + tri[0]) as usize].pos);
            let b = Vec3::from(out.vertices[(base + tri[1]) as usize].pos);
            let c = Vec3::from(out.vertices[(base + tri[2]) as usize].pos);
            let n = (b - a).cross(c - a).normalize_or_zero();
            for &i in tri {
                out.vertices[(base + i) as usize].nrm = n.into();
            }
        }
    }
    out.indices.extend(indices.into_iter().map(|i| base + i));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_eval_cube_gltf() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../evals/assets/cube.gltf");
        let m = load_gltf(path).expect("cube.gltf");
        assert_eq!(m.indices.len(), 36);
        assert_eq!(m.vertices.len(), 24);
    }
}
