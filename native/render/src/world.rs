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

mod rows;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use bevy::asset::RenderAssetUsages;
use bevy::camera::{ClearColorConfig, ImageRenderTarget, RenderTarget};
use bevy::core_pipeline::tonemapping::Tonemapping;
use bevy::light::AmbientLight;
use bevy::pbr::{DistanceFog, FogFalloff};
use bevy::post_process::bloom::Bloom;
use bevy::prelude::*;
use bevy::render::gpu_readback::{Readback, ReadbackComplete};
use bevy::render::render_resource::{TextureFormat, TextureUsages};
use serde_json::Value;

use rows::{colour, f, row_kind, spawn_row, update_row, v3};

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
