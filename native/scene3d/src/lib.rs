// moonsplice-scene3d: seek-safe glTF / primitive raster → premultiplied RGBA.
//
// A world is an offscreen layer, same contract as Lottie: load once, set pose
// from t, rasterize into ImageData. No Bevy/Godot loop — glam + gltf + wgpu
// (CPU Lambert fallback if the adapter is missing).
//
// Command stream (f32s):
//   0  camera   eye3 look3 up3 fov near far yaw pitch roll
//   1  light    dx dy dz r g b intensity
//   2  ambient  r g b
//   3  clear    r g b a
//   4  cube     x y z yaw pitch roll sx sy sz r g b a
//   5  mesh     handle x y z yaw pitch roll sx sy sz r g b a
//   6  sphere   x y z yaw pitch roll sx sy sz r g b a
//
// C ABI:
//   el_scene3d_load(path) -> handle > 0 | 0
//   el_scene3d_unload(handle)
//   el_scene3d_render(cmds, len, w, h, out, out_len) -> 0 | -1

mod cpu;
mod gpu;
mod mesh;
mod scene;

use mesh::Mesh;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

struct State {
    meshes: HashMap<i64, Mesh>,
    next_id: i64,
    cube: Mesh,
    sphere: Mesh,
    gpu: Option<gpu::Gpu>,
    gpu_failed: bool,
}

impl State {
    fn new() -> Self {
        Self {
            meshes: HashMap::new(),
            next_id: 1,
            cube: mesh::unit_cube(),
            sphere: mesh::unit_sphere(16, 24),
            gpu: None,
            gpu_failed: false,
        }
    }

    fn prefer_cpu() -> bool {
        matches!(
            std::env::var("MOONSPLICE_SCENE3D").ok().as_deref(),
            Some("cpu") | Some("CPU")
        )
    }

    fn ensure_gpu(&mut self) {
        if self.gpu.is_some() || self.gpu_failed || Self::prefer_cpu() {
            return;
        }
        match gpu::Gpu::new(&self.cube, &self.sphere) {
            Ok(mut g) => {
                for (id, m) in &self.meshes {
                    g.upload_mesh(*id, m);
                }
                self.gpu = Some(g);
            }
            Err(e) => {
                eprintln!("moonsplice-scene3d: wgpu init failed ({e}); CPU Lambert fallback");
                self.gpu_failed = true;
            }
        }
    }
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn with_state<T>(f: impl FnOnce(&mut State) -> T) -> T {
    let mut g = STATE.lock().unwrap_or_else(|p| p.into_inner());
    if g.is_none() {
        *g = Some(State::new());
    }
    f(g.as_mut().unwrap())
}

fn render_inner(cmds: &[f32], w: u16, h: u16, out: &mut [u8]) -> Option<()> {
    if out.len() != w as usize * h as usize * 4 {
        return None;
    }
    let frame = scene::parse(cmds)?;
    with_state(|st| {
        st.ensure_gpu();
        if st.gpu.is_some() {
            let missing: Vec<i64> = st
                .meshes
                .keys()
                .copied()
                .filter(|id| !st.gpu.as_ref().unwrap().has_mesh(*id))
                .collect();
            for id in missing {
                let mesh = st.meshes.get(&id).cloned().unwrap();
                st.gpu.as_mut().unwrap().upload_mesh(id, &mesh);
            }
        }
        if let Some(gpu) = st.gpu.as_mut() {
            match gpu.render(&frame, w as u32, h as u32, out) {
                Ok(()) => return Some(()),
                Err(e) => {
                    eprintln!("moonsplice-scene3d: wgpu render failed ({e}); CPU fallback this frame");
                }
            }
        }
        cpu::render(
            &frame,
            &st.cube,
            &st.sphere,
            &st.meshes,
            w as u32,
            h as u32,
            out,
        );
        Some(())
    })
}

#[no_mangle]
pub extern "C" fn el_scene3d_load(path: *const c_char) -> i64 {
    let result = catch_unwind(AssertUnwindSafe(|| -> Option<i64> {
        let path = unsafe { CStr::from_ptr(path) }.to_str().ok()?;
        let mesh = mesh::load_gltf(path).ok()?;
        Some(with_state(|st| {
            let id = st.next_id;
            st.next_id += 1;
            if let Some(gpu) = st.gpu.as_mut() {
                gpu.upload_mesh(id, &mesh);
            }
            st.meshes.insert(id, mesh);
            id
        }))
    }));
    match result {
        Ok(Some(id)) => id,
        _ => 0,
    }
}

#[no_mangle]
pub extern "C" fn el_scene3d_unload(handle: i64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        with_state(|st| {
            st.meshes.remove(&handle);
        });
    }));
}

#[no_mangle]
pub extern "C" fn el_scene3d_render(
    cmds: *const f32,
    len: usize,
    w: u16,
    h: u16,
    out: *mut u8,
    out_len: usize,
) -> c_int {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let cmds = unsafe { std::slice::from_raw_parts(cmds, len) };
        let out = unsafe { std::slice::from_raw_parts_mut(out, out_len) };
        render_inner(cmds, w, h, out)
    }));
    match result {
        Ok(Some(())) => 0,
        _ => -1,
    }
}
