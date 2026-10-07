// The prefetch worker: one thread per handle, decoding the next frame while the renderer is busy.

use super::{Decoder, Mode, T_EPS};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

struct Ready {
    t: f64,
    y: Vec<u8>,
    u: Vec<u8>,
    v: Vec<u8>,
    ok: bool,
}

struct Shared {
    req: Option<f64>,
    ready: Option<Ready>,
    dead: bool,
}

pub(super) struct Worker {
    sh: Arc<(Mutex<Shared>, Condvar, Condvar)>, // (state, req_cv, ready_cv)
    pub(super) mode: u8, // 0 yuv, 1 rgba
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) full_range: bool,
    join: Option<thread::JoinHandle<()>>,
}

pub(super) fn spawn_worker(mut dec: Decoder) -> Worker {
    let (mode, full_range) = match &dec.mode {
        Mode::Yuv420 { full_range } => (0u8, *full_range),
        Mode::Rgba { .. } => (1u8, true),
    };
    let (width, height) = match &dec.mode {
        Mode::Yuv420 { .. } => (dec.width, dec.height),
        Mode::Rgba { out_w, out_h, .. } => (*out_w, *out_h),
    };
    let sh = Arc::new((
        Mutex::new(Shared { req: None, ready: None, dead: false }),
        Condvar::new(),
        Condvar::new(),
    ));
    let sh2 = sh.clone();
    let join = thread::spawn(move || {
        let (m, req_cv, ready_cv) = &*sh2;
        loop {
            let t = {
                let mut g = m.lock().unwrap();
                while g.req.is_none() && !g.dead {
                    g = req_cv.wait(g).unwrap();
                }
                if g.dead {
                    return;
                }
                g.req.take().unwrap()
            };
            let ok = dec.advance_to(t).is_ok();
            let ready = Ready {
                t,
                y: dec.cache_y.clone(),
                u: dec.cache_u.clone(),
                v: dec.cache_v.clone(),
                ok,
            };
            let mut g = m.lock().unwrap();
            g.ready = Some(ready);
            ready_cv.notify_all();
        }
    });
    Worker { sh, mode, width, height, full_range, join: Some(join) }
}

impl Worker {
    pub(super) fn fetch(&self, t: f64, y: &mut [u8], u: Option<&mut [u8]>, v: Option<&mut [u8]>) -> bool {
        let (m, req_cv, ready_cv) = &*self.sh;
        let mut g = m.lock().unwrap();
        let matches = |r: &Option<Ready>| r.as_ref().map_or(false, |r| (r.t - t).abs() < T_EPS);
        if !matches(&g.ready) {
            g.req = Some(t);
            req_cv.notify_all();
            while !matches(&g.ready) && !g.dead {
                g = ready_cv.wait(g).unwrap();
            }
        }
        match g.ready.as_ref() {
            Some(r) if r.ok => {
                y.copy_from_slice(&r.y);
                if let Some(u) = u { u.copy_from_slice(&r.u); }
                if let Some(v) = v { v.copy_from_slice(&r.v); }
                true
            }
            _ => false,
        }
    }

    pub(super) fn prefetch(&self, t: f64) {
        let (m, req_cv, _) = &*self.sh;
        let mut g = m.lock().unwrap();
        let already = g.ready.as_ref().map_or(false, |r| (r.t - t).abs() < T_EPS);
        if g.req.is_none() && !already {
            g.req = Some(t);
            req_cv.notify_all();
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        {
            let (m, req_cv, _) = &*self.sh;
            m.lock().unwrap().dead = true;
            req_cv.notify_all();
        }
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}
