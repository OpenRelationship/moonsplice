//! `s:world` on Bevy: a 3D scene described as data each frame, drawn by Bevy's renderer.
//!
//! The comp describes the world at `t` as a document: a camera, the look (background, ambient,
//! bloom, fog, tonemapping) and a list of entities, each a row: an id, a shape or a glTF, a
//! transform and a material, or a light. This syncs that document into Bevy's ECS: an entity per
//! id, spawned the first time it is named, updated in place after that, despawned when it stops
//! being named. Nothing carries over between frames except what the document says, so a frame
//! is a function of the document, which is a function of `t`, and the world stays seekable.
//!
//! The picture is drawn offscreen into an image and read back as sRGB RGBA, which the scene
//! crate puts in an image slot like any other picture.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use bevy::asset::RenderAssetUsages;
use bevy::camera::{ClearColorConfig, ImageRenderTarget, RenderTarget};
use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::gltf::GltfAssetLabel;
use bevy::light::AmbientLight;
use bevy::pbr::{DistanceFog, FogFalloff};
use bevy::post_process::bloom::Bloom;
use bevy::prelude::*;
use bevy::render::gpu_readback::{Readback, ReadbackComplete};
use bevy::render::render_resource::{TextureFormat, TextureUsages};
use serde_json::Value;

/// What one world node has in Bevy: its target, its camera, and an entity per row id.
pub(crate) struct View {
    image: Handle<Image>,
    camera: Entity,
    size: (u32, u32),
    rows: HashMap<String, (Entity, String)>,
    drawn: bool,
}

#[derive(Default)]
pub(crate) struct Worlds {
    views: HashMap<String, View>,
    meshes: HashMap<String, Handle<Mesh>>,
}

fn f(v: &Value, k: &str, d: f32) -> f32 {
    v.get(k).and_then(|x| x.as_f64()).map(|x| x as f32).unwrap_or(d)
}

fn v3(v: &Value, k: &str, d: Vec3) -> Vec3 {
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
fn colour(v: Option<&Value>, d: Color) -> Color {
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
fn row_kind(row: &Value) -> String {
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

fn spawn_row(app: &mut App, ws: &mut Worlds, row: &Value, kind: &str) -> Result<Entity, String> {
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

fn update_row(app: &mut App, e: Entity, row: &Value, kind: &str) {
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

fn camera_bundle(doc: &Value, image: &Handle<Image>) -> impl Bundle {
    let cam = doc.get("camera").cloned().unwrap_or(Value::Null);
    let pos = v3(&cam, "pos", Vec3::new(0.0, 1.5, 5.0));
    let look = v3(&cam, "look", Vec3::ZERO);
    let up = v3(&cam, "up", Vec3::Y);
    (
        Camera3d::default(),
        Camera { clear_color: ClearColorConfig::Custom(colour(doc.get("background"), Color::NONE)), ..default() },
        RenderTarget::Image(ImageRenderTarget { handle: image.clone(), scale_factor: 1.0 }),
        Projection::Perspective(PerspectiveProjection {
            fov: f(&cam, "fov", 0.7),
            near: f(&cam, "near", 0.05),
            far: f(&cam, "far", 200.0),
            ..default()
        }),
        Transform::from_translation(pos).looking_at(look, up),
        Msaa::Sample4,
    )
}

fn tonemapping(doc: &Value) -> Tonemapping {
    match doc.get("tonemapping").and_then(|x| x.as_str()).unwrap_or("agx") {
        "none" => Tonemapping::None,
        "reinhard" => Tonemapping::Reinhard,
        "aces" => Tonemapping::AcesFitted,
        "tony" => Tonemapping::TonyMcMapface,
        "blender" => Tonemapping::BlenderFilmic,
        _ => Tonemapping::AgX,
    }
}

/// Sync the document into the world and return the frame, `w` x `h` sRGB RGBA, straight alpha.
pub(crate) fn frame(app: &mut App, ws: &mut Worlds, id: &str, doc: &Value, w: u32, h: u32) -> Result<Vec<u8>, String> {
    // the target and its camera, made once per world node (again when its size changes)
    let stale = ws.views.get(id).is_some_and(|v| v.size != (w, h));
    if stale {
        if let Some(v) = ws.views.remove(id) {
            app.world_mut().despawn(v.camera);
            for (e, _) in v.rows.values() {
                app.world_mut().despawn(*e);
            }
        }
    }
    if !ws.views.contains_key(id) {
        let mut img = Image::new_target_texture(w, h, TextureFormat::Rgba8UnormSrgb, None);
        img.texture_descriptor.usage |= TextureUsages::COPY_SRC;
        img.asset_usage = RenderAssetUsages::RENDER_WORLD;
        let image = app.world_mut().resource_mut::<Assets<Image>>().add(img);
        let camera = app.world_mut().spawn(camera_bundle(doc, &image)).id();
        ws.views.insert(id.to_string(), View { image, camera, size: (w, h), rows: HashMap::new(), drawn: false });
    }

    // the camera and the look, every frame
    let (camera, image) = {
        let v = &ws.views[id];
        (v.camera, v.image.clone())
    };
    {
        let world = app.world_mut();
        let mut em = world.entity_mut(camera);
        let cam = doc.get("camera").cloned().unwrap_or(Value::Null);
        let pos = v3(&cam, "pos", Vec3::new(0.0, 1.5, 5.0));
        if let Some(mut tr) = em.get_mut::<Transform>() {
            *tr = Transform::from_translation(pos).looking_at(v3(&cam, "look", Vec3::ZERO), v3(&cam, "up", Vec3::Y));
        }
        if let Some(mut p) = em.get_mut::<Projection>() {
            if let Projection::Perspective(pp) = p.as_mut() {
                pp.fov = f(&cam, "fov", 0.7);
            }
        }
        if let Some(mut c) = em.get_mut::<Camera>() {
            c.clear_color = ClearColorConfig::Custom(colour(doc.get("background"), Color::NONE));
        }
        em.insert(tonemapping(doc));
        let amb = doc.get("ambient").cloned().unwrap_or(Value::Null);
        em.insert(AmbientLight {
            color: colour(amb.get("color"), Color::WHITE),
            brightness: f(&amb, "brightness", 120.0),
            affects_lightmapped_meshes: true,
        });
        match doc.get("bloom").and_then(|x| x.as_f64()) {
            Some(b) if b > 0.0 => {
                em.insert(Bloom { intensity: b as f32, ..Bloom::NATURAL });
            }
            _ => {
                em.remove::<Bloom>();
            }
        }
        match doc.get("fog") {
            Some(fog) if fog.is_object() => {
                em.insert(DistanceFog {
                    color: colour(fog.get("color"), Color::srgb(0.5, 0.55, 0.6)),
                    falloff: FogFalloff::Linear { start: f(fog, "start", 5.0), end: f(fog, "end", 40.0) },
                    ..default()
                });
            }
            _ => {
                em.remove::<DistanceFog>();
            }
        }
    }

    // whether anything new reached the world this frame: new things take a few updates to be
    // prepared in the render world (meshes, materials, shadow maps), and a frame read back before
    // that would differ from the same frame drawn later -- so that frame waits for them
    let mut spawned = ws.views[id].rows.is_empty();
    // the rows
    let rows: Vec<Value> = doc.get("entities").and_then(|x| x.as_array()).cloned().unwrap_or_default();
    let mut seen: HashMap<String, ()> = HashMap::new();
    for (i, row) in rows.iter().enumerate() {
        let rid = row.get("id").map(|x| match x {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        }).unwrap_or_else(|| format!("#{i}"));
        let kind = row_kind(row);
        seen.insert(rid.clone(), ());
        let existing = ws.views[id].rows.get(&rid).cloned();
        match existing {
            Some((e, k)) if k == kind => update_row(app, e, row, &kind),
            Some((e, _)) => {
                app.world_mut().despawn(e);
                spawned = true;
                let e = spawn_row(app, ws, row, &kind)?;
                ws.views.get_mut(id).unwrap().rows.insert(rid, (e, kind));
            }
            None => {
                spawned = true;
                let e = spawn_row(app, ws, row, &kind)?;
                ws.views.get_mut(id).unwrap().rows.insert(rid, (e, kind));
            }
        }
    }
    let gone: Vec<String> = ws.views[id].rows.keys().filter(|k| !seen.contains_key(*k)).cloned().collect();
    for k in gone {
        if let Some((e, _)) = ws.views.get_mut(id).unwrap().rows.remove(&k) {
            app.world_mut().despawn(e);
        }
    }

    // glTF scenes load asynchronously; a frame waits for them rather than drawing without them
    for _ in 0..600 {
        let world = app.world();
        let server = world.resource::<AssetServer>();
        let pending = world.iter_entities().any(|e| {
            e.get::<WorldAssetRoot>().is_some_and(|s| !server.is_loaded_with_dependencies(&s.0))
        });
        if !pending {
            break;
        }
        app.update();
    }
    // a spawned scene's meshes arrive an update after the scene does; anything new is prepared
    // before the frame that shows it is read
    for _ in 0..if spawned { 4 } else { 1 } {
        app.update();
    }

    // draw, and read the target back. A world's first frame is read until two reads agree:
    // what Bevy loads lazily on first use (tonemapping LUTs, bloom and shadow pipelines) is
    // otherwise missing from whichever frame happens to be drawn first, and a frame must not
    // depend on its place in the order
    let first = !ws.views.get(id).is_some_and(|v| v.drawn);
    let mut data = read(app, &image)?;
    if first {
        for _ in 0..12 {
            let again = read(app, &image)?;
            if again == data {
                break;
            }
            data = again;
        }
        if let Some(v) = ws.views.get_mut(id) {
            v.drawn = true;
        }
    }
    // rows are padded to 256 bytes on the way back; take each row's pixels
    let row = w as usize * 4;
    if data.len() == row * h as usize {
        return Ok(data);
    }
    let padded = data.len() / h as usize;
    let mut out = Vec::with_capacity(row * h as usize);
    for y in 0..h as usize {
        out.extend_from_slice(&data[y * padded..y * padded + row]);
    }
    Ok(out)
}

fn read(app: &mut App, image: &Handle<Image>) -> Result<Vec<u8>, String> {
    let got: Arc<Mutex<Option<Vec<u8>>>> = Arc::new(Mutex::new(None));
    let sink = got.clone();
    let rb = app
        .world_mut()
        .spawn(Readback::texture(image.clone()))
        .observe(move |ev: On<ReadbackComplete>| {
            *sink.lock().unwrap() = Some(ev.event().data.clone());
        })
        .id();
    for _ in 0..240 {
        app.update();
        if got.lock().unwrap().is_some() {
            break;
        }
    }
    app.world_mut().despawn(rb);
    let data = got.lock().unwrap().take().ok_or("world: the frame never came back from the GPU")?;
    Ok(data)
}
