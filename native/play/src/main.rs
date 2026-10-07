//! `moonsplice-play comp.lua`: play a game (.robot/docs/canon.robot, amendment 2026-10-06).
//!
//! Bevy owns the window, the keyboard and the mouse. The composition runs where it always does,
//! in the engine (`moonsplice_engine::Session`, the same runtime `render` and the Studio use), on
//! a thread of its own: every Bevy frame sends that frame's input as events, asks for the frame at
//! the game's clock, and writes the pixels into the texture on screen. Nothing about the game is
//! decided here, so what is played is exactly what `render --input-log` will draw again.
//!
//! Escape ends the session and saves what was played to `<comp>.play.json`, which renders with
//! `moonsplice render <comp> --input-log <comp>.play.json -o trailer.mp4`.

use std::path::PathBuf;
use std::time::Instant;

use bevy::asset::RenderAssetUsages;
use bevy::input::keyboard::KeyboardInput;
use bevy::input::mouse::MouseButtonInput;
use bevy::input::ButtonState;
use bevy::prelude::*;
use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat};
use bevy::window::{PrimaryWindow, WindowResolution};
use moonsplice_engine::Session;

struct Game {
    session: Session,
    seq: u64,
}

// The session is only touched from Bevy's main schedule, one system at a time.
#[derive(Resource)]
struct Running {
    game: std::sync::Mutex<Game>,
    started: Instant,
    w: u32,
    h: u32,
    image: Handle<Image>,
    comp: PathBuf,
    saved: bool,
    scripted: std::sync::Mutex<Vec<(f64, String, String)>>,
    quit_after: Option<f64>,
    pointer: std::sync::Mutex<Option<(f32, f32)>>,
}

impl Game {
    fn call(&mut self, mut req: serde_json::Value) -> Result<String, String> {
        self.seq += 1;
        req["seq"] = serde_json::json!(self.seq);
        self.session.send(&req.to_string()).map_err(|e| e.to_string())?;
        let reply = self.session.recv().map_err(|e| e.to_string())?;
        if let Some(why) = reply.strip_prefix("err ") {
            return Err(why.splitn(2, ' ').nth(1).unwrap_or(why).to_string());
        }
        Ok(reply)
    }
    fn payload(&mut self, reply: &str) -> Option<Vec<u8>> {
        let path = reply.split_whitespace().nth(1)?;
        self.session.take(path)
    }
}

fn key_name(k: &KeyCode) -> Option<String> {
    use KeyCode::*;
    Some(match k {
        ArrowUp => "up".into(),
        ArrowDown => "down".into(),
        ArrowLeft => "left".into(),
        ArrowRight => "right".into(),
        Space => "space".into(),
        Enter => "enter".into(),
        ShiftLeft | ShiftRight => "shift".into(),
        Tab => "tab".into(),
        other => {
            let s = format!("{other:?}");
            if let Some(c) = s.strip_prefix("Key") {
                c.to_lowercase()
            } else if let Some(d) = s.strip_prefix("Digit") {
                d.to_string()
            } else {
                return None;
            }
        }
    })
}

fn main() {
    let comp = match std::env::args().nth(1) {
        Some(c) => PathBuf::from(c),
        None => {
            eprintln!("usage: moonsplice-play comp.lua");
            std::process::exit(2);
        }
    };
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let root = std::env::var("MOONSPLICE_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        moonsplice_engine::default_runtime().parent().map(|p| p.to_path_buf()).unwrap_or_default()
    });
    let serve = std::env::temp_dir().join(format!("moonsplice-play-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&serve);
    let session = Session::start(
        &root.join("core").join("runtime"),
        vec!["--serve".into(), comp.display().to_string()],
        vec![
            ("MOONSPLICE_CWD".into(), cwd.display().to_string()),
            ("MOONSPLICE_SERVE_DIR".into(), serve.display().to_string()),
            ("MOONSPLICE_HEADLESS".into(), "1".into()),
        ],
    )
    .unwrap_or_else(|e| {
        eprintln!("moonsplice-play: {e}");
        std::process::exit(2);
    });
    let ready = match session.recv() {
        Ok(r) => r,
        Err(_) => {
            for l in session.said() {
                eprintln!("{l}");
            }
            std::process::exit(1);
        }
    };
    let mut it = ready.split_whitespace().skip(1);
    let w: u32 = it.next().and_then(|v| v.parse().ok()).unwrap_or(1280);
    let h: u32 = it.next().and_then(|v| v.parse().ok()).unwrap_or(720);

    let title = comp.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    App::new()
        .add_plugins(DefaultPlugins.set(WindowPlugin {
            primary_window: Some(Window {
                title: format!("{title} — moonsplice"),
                resolution: WindowResolution::new(w, h),
                ..default()
            }),
            ..default()
        }))
        .insert_resource(ClearColor(Color::BLACK))
        .insert_non_send(Pending { game: Some(Game { session, seq: 0 }), comp, w, h })
        .add_systems(Startup, setup)
        .add_systems(Update, (frame, save_on_exit))
        .run();
}

struct Pending {
    game: Option<Game>,
    comp: PathBuf,
    w: u32,
    h: u32,
}

fn setup(mut commands: Commands, mut images: ResMut<Assets<Image>>, mut pending: NonSendMut<Pending>) {
    let (w, h) = (pending.w, pending.h);
    let image = Image::new_fill(
        Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        TextureDimension::D2,
        &[0, 0, 0, 255],
        TextureFormat::Rgba8UnormSrgb,
        RenderAssetUsages::MAIN_WORLD | RenderAssetUsages::RENDER_WORLD,
    );
    let handle = images.add(image);
    commands.spawn(Camera2d);
    commands.spawn(Sprite::from_image(handle.clone()));
    let game = pending.game.take().expect("one setup");
    commands.insert_resource(Running {
        game: std::sync::Mutex::new(game),
        started: Instant::now(),
        w,
        h,
        image: handle,
        comp: pending.comp.clone(),
        saved: false,
        scripted: std::sync::Mutex::new(scripted_keys()),
        quit_after: std::env::var("MOONSPLICE_PLAY_SECONDS").ok().and_then(|v| v.parse().ok()),
        pointer: std::sync::Mutex::new(None),
    });
}

fn frame(
    run: Res<Running>,
    mut images: ResMut<Assets<Image>>,
    mut keys: MessageReader<KeyboardInput>,
    mut buttons: MessageReader<MouseButtonInput>,
    windows: Query<&Window, With<PrimaryWindow>>,
) {
    let t = run.started.elapsed().as_secs_f64();
    let mut events = Vec::new();
    for k in keys.read() {
        if k.repeat {
            continue;
        }
        if let Some(name) = key_name(&k.key_code) {
            let field = if k.state == ButtonState::Pressed { "down" } else { "up" };
            events.push(serde_json::json!({ "t": t, field: name }));
        }
    }
    if let Ok(win) = windows.single() {
        if let Some(p) = win.cursor_position() {
            let (sx, sy) = (run.w as f32 / win.width(), run.h as f32 / win.height());
            let (x, y) = (p.x * sx, p.y * sy);
            let mut moved = serde_json::json!({ "t": t, "x": x, "y": y });
            let mut last = run.pointer.lock().unwrap();
            let changed = last.map_or(true, |(lx, ly)| (lx - x).abs() >= 0.5 || (ly - y).abs() >= 0.5);
            *last = Some((x, y));
            for b in buttons.read() {
                if b.button == MouseButton::Left {
                    let mut e = moved.clone();
                    e[if b.state == ButtonState::Pressed { "press" } else { "release" }] = serde_json::json!(true);
                    events.push(e);
                }
            }
            if changed {
                events.push(moved);
            }
        }
    }
    // MOONSPLICE_PLAY_KEYS="0.5:down:up,2:up:up": keys pressed at those seconds, for a test
    // to play without a person at the keyboard
    {
        let mut scripted = run.scripted.lock().unwrap();
        while scripted.first().is_some_and(|(at, _, _)| *at <= t) {
            let (_, field, key) = scripted.remove(0);
            events.push(serde_json::json!({ "t": t, field: key }));
        }
    }
    let mut game = run.game.lock().unwrap();
    if !events.is_empty() {
        let _ = game.call(serde_json::json!({ "op": "input", "events": events }));
    }
    match game.call(serde_json::json!({ "op": "frame", "t": t })) {
        Ok(reply) => {
            if let Some(px) = game.payload(&reply) {
                if let Some(mut img) = images.get_mut(&run.image) {
                    if let Some(data) = img.data.as_mut() {
                        if data.len() == px.len() {
                            data.copy_from_slice(&px);
                        }
                    }
                }
            }
        }
        Err(why) => eprintln!("moonsplice-play: {why}"),
    }
}

fn scripted_keys() -> Vec<(f64, String, String)> {
    let mut out: Vec<(f64, String, String)> = std::env::var("MOONSPLICE_PLAY_KEYS")
        .unwrap_or_default()
        .split(',')
        .filter_map(|e| {
            let mut p = e.trim().splitn(3, ':');
            Some((p.next()?.parse().ok()?, p.next()?.to_string(), p.next()?.to_string()))
        })
        .collect();
    out.sort_by(|a, b| a.0.total_cmp(&b.0));
    out
}

fn save_on_exit(mut run: ResMut<Running>, keys: Res<ButtonInput<KeyCode>>, mut exit: MessageWriter<AppExit>) {
    let timed_out = run.quit_after.is_some_and(|s| run.started.elapsed().as_secs_f64() >= s);
    if run.saved || !(keys.just_pressed(KeyCode::Escape) || timed_out) {
        return;
    }
    run.saved = true;
    let out = run.comp.with_extension("play.json");
    let mut game = run.game.lock().unwrap();
    match game.call(serde_json::json!({ "op": "log" })) {
        Ok(reply) => {
            if let Some(doc) = game.payload(&reply) {
                match std::fs::write(&out, doc) {
                    Ok(()) => eprintln!("moonsplice-play: saved what was played to {}", out.display()),
                    Err(e) => eprintln!("moonsplice-play: {}: {e}", out.display()),
                }
            }
        }
        Err(why) => eprintln!("moonsplice-play: {why}"),
    }
    exit.write(AppExit::Success);
}
