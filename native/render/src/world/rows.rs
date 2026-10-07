//! A world's rows in Bevy: reading a row's values, the meshes and materials it names, and spawning
//! or updating the entity a row stands for.

use bevy::asset::RenderAssetUsages;
use bevy::gltf::GltfAssetLabel;
use bevy::prelude::*;
use serde_json::Value;

use super::Worlds;

pub(super) fn f(v: &Value, k: &str, d: f32) -> f32 {
    v.get(k).and_then(|x| x.as_f64()).map(|x| x as f32).unwrap_or(d)
}

pub(super) fn v3(v: &Value, k: &str, d: Vec3) -> Vec3 {
    match v.get(k).and_then(|x| x.as_array()) {
        Some(a) if a.len() >= 3 => Vec3::new(
            a[0].as_f64().unwrap_or(0.0) as f32,
            a[1].as_f64().unwrap_or(0.0) as f32,
            a[2].as_f64().unwrap_or(0.0) as f32,
        ),
        _ => d,
    }
}

/// [r, g, b, a?] in sRGB, 0..1, or "#rrggbb[aa]".
pub(super) fn colour(v: Option<&Value>, d: Color) -> Color {
    match v {
        Some(Value::Array(a)) if a.len() >= 3 => Color::srgba(
            a[0].as_f64().unwrap_or(0.0) as f32,
            a[1].as_f64().unwrap_or(0.0) as f32,
            a[2].as_f64().unwrap_or(0.0) as f32,
            a.get(3).and_then(|x| x.as_f64()).unwrap_or(1.0) as f32,
        ),
        Some(Value::String(s)) => Srgba::hex(s.trim_start_matches('#')).map(Color::from).unwrap_or(d),
        _ => d,
    }
}

fn transform(row: &Value) -> Transform {
    let rot = Quat::from_euler(EulerRot::YXZ, f(row, "yaw", 0.0), f(row, "pitch", 0.0), f(row, "roll", 0.0));
    let s = f(row, "scale", 1.0);
    let size = v3(row, "size", Vec3::ONE) * s;
    Transform { translation: v3(row, "pos", Vec3::ZERO), rotation: rot, scale: size }
}

/// Unit shapes, scaled by the row's `size`: a cube is 1 on a side, a sphere 1 across.
/// "MSH1", vertex and triangle counts, per vertex position and normal (6 f32), triangles (3 u32)
fn read_msh(path: &str) -> Result<Mesh, String> {
    let b = std::fs::read(path).map_err(|e| format!("world: solid {path}: {e}"))?;
    if b.len() < 12 || &b[..4] != b"MSH1" {
        return Err(format!("world: {path} is not a solid mesh (MSH1)"));
    }
    let u = |o: usize| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) as usize;
    let (nv, nt) = (u(4), u(8));
    if b.len() != 12 + nv * 24 + nt * 12 {
        return Err(format!("world: {path} is cut short"));
    }
    let f = |o: usize| f32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]);
    let mut pos = Vec::with_capacity(nv);
    let mut norm = Vec::with_capacity(nv);
    for i in 0..nv {
        let o = 12 + i * 24;
        pos.push([f(o), f(o + 4), f(o + 8)]);
        norm.push([f(o + 12), f(o + 16), f(o + 20)]);
    }
    let base = 12 + nv * 24;
    let idx: Vec<u32> = (0..nt * 3).map(|i| u(base + i * 4) as u32).collect();
    let mut m = Mesh::new(bevy::render::mesh::PrimitiveTopology::TriangleList, RenderAssetUsages::default());
    m.insert_attribute(Mesh::ATTRIBUTE_POSITION, pos);
    m.insert_attribute(Mesh::ATTRIBUTE_NORMAL, norm);
    m.insert_indices(bevy::render::mesh::Indices::U32(idx));
    Ok(m)
}

fn shape_mesh(shape: &str, detail: u32) -> Option<Mesh> {
    Some(match shape {
        "cube" | "box" => Cuboid::new(1.0, 1.0, 1.0).into(),
        "sphere" => Sphere::new(0.5).mesh().uv(detail * 2, detail).into(),
        "plane" => Plane3d::default().mesh().size(1.0, 1.0).into(),
        "cylinder" => Cylinder::new(0.5, 1.0).mesh().resolution(detail * 2).into(),
        "capsule" => Capsule3d::new(0.25, 0.5).mesh().into(),
        "cone" => Cone::new(0.5, 1.0).mesh().resolution(detail * 2).into(),
        "torus" => Torus::new(0.3, 0.5).mesh().minor_resolution(detail as usize).major_resolution(detail as usize * 2).into(),
        _ => return None,
    })
}

fn material(row: &Value) -> StandardMaterial {
    let base = colour(row.get("color"), Color::WHITE);
    let emissive = colour(row.get("emissive"), Color::BLACK).to_linear() * f(row, "emissive_strength", 1.0);
    let alpha = base.alpha();
    StandardMaterial {
        base_color: base,
        metallic: f(row, "metallic", 0.0),
        perceptual_roughness: f(row, "roughness", 0.5),
        reflectance: f(row, "reflectance", 0.5),
        emissive,
        unlit: row.get("unlit").and_then(|x| x.as_bool()).unwrap_or(false),
        alpha_mode: if alpha < 0.999 { AlphaMode::Blend } else { AlphaMode::Opaque },
        double_sided: row.get("double_sided").and_then(|x| x.as_bool()).unwrap_or(false),
        cull_mode: if row.get("double_sided").and_then(|x| x.as_bool()).unwrap_or(false) { None } else { Some(bevy::render::render_resource::Face::Back) },
        ..default()
    }
}

/// The kind of thing a row is, so a row whose kind changes is respawned rather than patched.
pub(super) fn row_kind(row: &Value) -> String {
    if let Some(l) = row.get("light").and_then(|x| x.as_str()) {
        return format!("light:{l}");
    }
    if let Some(s) = row.get("solid").and_then(|x| x.as_str()) {
        return format!("solid:{s}");
    }
    if let Some(s) = row.get("src").and_then(|x| x.as_str()) {
        return format!("gltf:{s}");
    }
    format!("mesh:{}:{}", row.get("shape").and_then(|x| x.as_str()).unwrap_or("cube"), f(row, "detail", 24.0) as u32)
}

pub(super) fn spawn_row(app: &mut App, ws: &mut Worlds, row: &Value, kind: &str) -> Result<Entity, String> {
    let world = app.world_mut();
    let t = transform(row);
    if let Some(light) = kind.strip_prefix("light:") {
        let c = colour(row.get("color"), Color::WHITE);
        let shadows = row.get("shadows").and_then(|x| x.as_bool()).unwrap_or(false);
        let e = match light {
            "directional" => {
                let dir = v3(row, "dir", Vec3::new(-0.4, -1.0, -0.3)).normalize_or(Vec3::NEG_Y);
                world.spawn((
                    DirectionalLight { color: c, illuminance: f(row, "intensity", 8000.0), shadow_maps_enabled: shadows, ..default() },
                    Transform::default().looking_to(dir, Vec3::Y),
                ))
            }
            "point" => world.spawn((
                PointLight { color: c, intensity: f(row, "intensity", 800_000.0), range: f(row, "range", 20.0), radius: f(row, "radius", 0.0), shadow_maps_enabled: shadows, ..default() },
                Transform::from_translation(t.translation),
            )),
            "spot" => {
                let dir = v3(row, "dir", Vec3::NEG_Y).normalize_or(Vec3::NEG_Y);
                world.spawn((
                    SpotLight { color: c, intensity: f(row, "intensity", 800_000.0), range: f(row, "range", 20.0), shadow_maps_enabled: shadows,
                        outer_angle: f(row, "angle", 0.6), inner_angle: f(row, "angle", 0.6) * f(row, "softness", 0.7), ..default() },
                    Transform::from_translation(t.translation).looking_to(dir, Vec3::Y),
                ))
            }
            other => return Err(format!("world: a light is directional, point or spot, not {other}")),
        };
        return Ok(e.id());
    }
    if let Some(src) = kind.strip_prefix("gltf:") {
        let path = src.trim_start_matches('/').to_string();
        let scene = world.resource::<AssetServer>().load(GltfAssetLabel::Scene(0).from_asset(path));
        return Ok(world.spawn((WorldAssetRoot(scene), t)).id());
    }
    if let Some(path) = kind.strip_prefix("solid:") {
        // a solid built by moonsplice-solid (.robot/docs/solids.robot): its mesh, with this row's material
        let mesh = match ws.meshes.get(kind) {
            Some(h) => h.clone(),
            None => {
                let m = read_msh(path)?;
                let h = world.resource_mut::<Assets<Mesh>>().add(m);
                ws.meshes.insert(kind.to_string(), h.clone());
                h
            }
        };
        let mat = world.resource_mut::<Assets<StandardMaterial>>().add(material(row));
        return Ok(world.spawn((Mesh3d(mesh), MeshMaterial3d(mat), t)).id());
    }
    let mut parts = kind.splitn(3, ':').skip(1);
    let shape = parts.next().unwrap_or("cube").to_string();
    let detail: u32 = parts.next().and_then(|d| d.parse().ok()).unwrap_or(24).clamp(4, 128);
    let key = format!("{shape}:{detail}");
    let mesh = match ws.meshes.get(&key) {
        Some(h) => h.clone(),
        None => {
            let m = shape_mesh(&shape, detail).ok_or_else(|| format!("world: no shape called {shape}"))?;
            let h = world.resource_mut::<Assets<Mesh>>().add(m);
            ws.meshes.insert(key, h.clone());
            h
        }
    };
    let mat = world.resource_mut::<Assets<StandardMaterial>>().add(material(row));
    Ok(world.spawn((Mesh3d(mesh), MeshMaterial3d(mat), t)).id())
}

pub(super) fn update_row(app: &mut App, e: Entity, row: &Value, kind: &str) {
    let world = app.world_mut();
    let t = transform(row);
    if kind.starts_with("light:") {
        let c = colour(row.get("color"), Color::WHITE);
        let mut em = world.entity_mut(e);
        if let Some(mut l) = em.get_mut::<DirectionalLight>() {
            l.color = c;
            l.illuminance = f(row, "intensity", 8000.0);
            let dir = v3(row, "dir", Vec3::new(-0.4, -1.0, -0.3)).normalize_or(Vec3::NEG_Y);
            if let Some(mut tr) = em.get_mut::<Transform>() {
                *tr = Transform::default().looking_to(dir, Vec3::Y);
            }
            return;
        }
        if let Some(mut l) = em.get_mut::<PointLight>() {
            l.color = c;
            l.intensity = f(row, "intensity", 800_000.0);
            l.range = f(row, "range", 20.0);
        }
        if let Some(mut l) = em.get_mut::<SpotLight>() {
            l.color = c;
            l.intensity = f(row, "intensity", 800_000.0);
        }
        let dir = v3(row, "dir", Vec3::NEG_Y).normalize_or(Vec3::NEG_Y);
        if let Some(mut tr) = em.get_mut::<Transform>() {
            *tr = Transform::from_translation(t.translation).looking_to(dir, Vec3::Y);
        }
        return;
    }
    if let Some(mut tr) = world.entity_mut(e).get_mut::<Transform>() {
        *tr = t;
    }
    let mat = world.entity(e).get::<MeshMaterial3d<StandardMaterial>>().map(|m| m.0.clone());
    if let Some(h) = mat {
        if let Some(mut m) = world.resource_mut::<Assets<StandardMaterial>>().get_mut(&h) {
            *m = material(row);
        }
    }
}
