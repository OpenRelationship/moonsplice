use super::*;

/// How many megabytes of decoded frames to hold. Raw pane-size frames are about 2 MB each, so
/// 384 MB is roughly six seconds of 30 fps preview: enough that scrubbing back over a beat, or
/// playing the same phrase twice, never asks the renderer twice. `MOONSPLICE_FRAME_CACHE_MB` moves
/// it, for a machine with less to spare or a comp with more to hold.
pub(super) fn frame_budget() -> usize {
    let mb = std::env::var("MOONSPLICE_FRAME_CACHE_MB")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|mb| *mb >= 16)
        .unwrap_or(384);
    mb * 1024 * 1024
}

/// The engine's node list, in the shape the lowering aligns against.
pub(super) fn node_refs(outline: &serde_json::Value) -> Vec<NodeRef> {
    outline["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|n| {
                    Some(NodeRef {
                        id: n["id"].as_str()?.to_string(),
                        kind: n["kind"].as_str().unwrap_or("").to_string(),
                        line: n["line"].as_u64().map(|v| v as u32),
                        props: n["props"]
                            .as_object()
                            .map(|o| o.keys().cloned().collect())
                            .unwrap_or_default(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

// ------------------------------------------------------------------------------ the watcher

/// A composition changed on disk. There is one representation, so this is a re-read and not a
/// merge — the third writer needs no machinery of its own.
pub(super) fn watch(app: AppHandle, root: PathBuf) {
    std::thread::spawn(move || {
        use notify::Watcher;
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watcher = match notify::recommended_watcher(move |res| {
            let _ = tx.send(res);
        }) {
            Ok(w) => w,
            Err(e) => {
                log::warn!("no file watcher: {e}");
                return;
            }
        };
        if watcher
            .watch(&root, notify::RecursiveMode::Recursive)
            .is_err()
        {
            return;
        }
        while let Ok(Ok(ev)) = rx.recv() {
            let touched: Vec<PathBuf> = ev
                .paths
                .into_iter()
                .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("lua"))
                .collect();
            if touched.is_empty() {
                continue;
            }
            // Settle: an editor writes through a temp file and renames, so the first event
            // can arrive before the bytes do.
            std::thread::sleep(std::time::Duration::from_millis(80));
            let studio = app.state::<Studio>();
            let mut open = studio.open.lock().unwrap();
            let names: Vec<String> = open.keys().cloned().collect();
            for name in names {
                let Some(o) = open.get_mut(&name) else { continue };
                if !touched.iter().any(|p| same_file(p, &o.doc.path)) {
                    continue;
                }
                match o.doc.adopt_from_disk() {
                    Ok(Some(applied)) => match o.refresh_outline() {
                        Ok(()) => {
                            broadcast(&app, &name, o, applied.what.clone());
                            // It loads again. Said out loud, because the window has been showing
                            // a picture it was told not to trust and needs telling that it can.
                            if o.trouble.take().is_some() {
                                let _ = app.emit(
                                    event::TROUBLE,
                                    Trouble { variation: name.clone(), why: None },
                                );
                            }
                        }
                        Err(e) => {
                            // The engine still holds the last version that worked, and the
                            // preview goes on painting it. That is the right thing to keep
                            // showing and the wrong thing to show silently: without this, the
                            // app and the file quietly stop being the same composition.
                            let why = crate::engine::in_words(&e);
                            let why = if why.is_empty() { e.clone() } else { why };
                            log::warn!("could not re-read {name}: {e}");
                            if o.trouble.as_deref() != Some(why.as_str()) {
                                o.trouble = Some(why.clone());
                                let _ = app.emit(
                                    event::TROUBLE,
                                    Trouble { variation: name.clone(), why: Some(why) },
                                );
                            }
                        }
                    },
                    Ok(None) => {}
                    Err(e) => log::warn!("could not re-read {name}: {e}"),
                }
            }
        }
    });
}

pub(super) fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(x), Ok(y)) => x == y,
        _ => a == b,
    }
}

// -------------------------------------------------------------------------------- the frames

/// `cframe://localhost/<variation>/<hash>/<t_ms>/<w>x<h>.raw` — and `.jpg` for anything that
/// wants a picture rather than pixels.
///
/// Every part of the key is in the path, so the webview's own cache is correct and a changed
/// composition simply asks for a different URL. `?warm=1` says nobody is looking at this frame
/// yet, which is what lets the queue put the picture first.
pub(super) fn frame_wanted(path: &str, query: Option<&str>) -> Result<(FrameKey, bool), String> {
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    if parts.len() < 4 {
        return Err("a frame is asked for as <variation>/<hash>/<ms>/<w>x<h>.raw".into());
    }
    let variation = urldecode(parts[0]);
    let hash = parts[1].to_string();
    let t_ms: u32 = parts[2].parse().map_err(|_| "that is not a time")?;
    let last = parts[3];
    let raw = !last.ends_with(".jpg");
    let size = last.trim_end_matches(".jpg").trim_end_matches(".raw");
    let (sw, sh) = size.split_once('x').ok_or("that is not a size")?;
    let w: u32 = sw.parse().map_err(|_| "that is not a width")?;
    let h: u32 = sh.parse().map_err(|_| "that is not a height")?;
    let warm = query.is_some_and(|q| q.split('&').any(|kv| kv == "warm=1"));
    Ok((
        FrameKey {
            variation,
            hash,
            t_ms,
            w,
            h,
            raw,
        },
        !warm,
    ))
}

/// Every response these two schemes make is cross-origin, and has to say so.
///
/// The window is `http://localhost:1420` while it is being developed and `tauri://localhost`
/// once it is built; the frames are `cframe://localhost` and the sounds are `casset://localhost`.
/// Different scheme, different origin, every single time -- so without this header the webview
/// refuses the response before the app sees a byte of it, and `fetch` says only "Load failed".
///
/// What that looked like: 569 frames rendered, served and thrown away, a preview showing the
/// checkerboard it shows when no frame has arrived, and no sound at all -- with nothing wrong
/// anywhere in the renderer, the queue or the cache, all of which were working perfectly and
/// measurably the whole time.
///
/// `*` and not the window's own origin because the origin is not one value: it changes between
/// development and a build, and the alternative is a list of origins to keep in step with the
/// two places that already know. Nothing outside this process can reach these schemes -- they
/// are registered on this webview and resolve nowhere else -- so there is no third party for a
/// wildcard to let in.
///
/// `range` is named among the allowed headers because a `<audio>` element asks for one, and a
/// request carrying `Range` is not a simple request: it is preflighted, and a preflight with no
/// answer fails the same silent way.
pub(super) fn across_the_origin(b: tauri::http::response::Builder) -> tauri::http::response::Builder {
    b.header("access-control-allow-origin", "*")
        .header("access-control-allow-methods", "GET, HEAD, OPTIONS")
        .header("access-control-allow-headers", "range")
        .header("access-control-max-age", "86400")
}

/// A raw frame with its size on the front: width then height, 32 bits each, little-endian.
///
/// Eight bytes so the window never has to be told separately how big the picture is. See the
/// note on the headers in the scheme handler for why being told separately did not work.
pub fn stamped(frame: &Frame) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + frame.bytes.len());
    out.extend_from_slice(&frame.w.to_le_bytes());
    out.extend_from_slice(&frame.h.to_le_bytes());
    out.extend_from_slice(&frame.bytes);
    out
}

/// Make one frame: ask the engine, scale it to the pane, and record what each step cost.
///
/// Called on a frame worker, never on the webview's thread. `queued` is when the request
/// arrived, so the record can separate "the renderer is slow" from "we asked for more frames
/// than it can make".
pub(super) fn make_frame(
    app: &AppHandle,
    key: &FrameKey,
    live: bool,
    queued: std::time::Instant,
) -> Result<Frame, String> {
    let studio = app.state::<Studio>();
    let queue_us = queued.elapsed().as_micros() as u64;

    // Asked for twice, warmed then wanted: the second one is a cache hit and costs nothing.
    if let Some(hit) = studio.cache.get(key) {
        studio.perf.record(perf::FrameSpan {
            t_ms: key.t_ms,
            w: hit.w,
            h: hit.h,
            live,
            hit: true,
            wait_us: queue_us,
            total_us: queue_us,
            bytes: hit.bytes.len(),
            ..Default::default()
        });
        return Ok(hit);
    }

    // The engine is taken out of the map and let go of before rendering: holding it across a
    // render would serialise every command in the app behind whatever frame the preview happens
    // to want, which is the difference between a scrub that feels live and one that fights the UI.
    let engine = {
        let open = studio.open.lock().unwrap();
        open.get(&key.variation)
            .ok_or("that composition is not open")?
            .engine
            .clone()
    };
    // The size the picture will actually be shown at, which is what the renderer is asked for.
    // `fit` is the same rule this side would have applied afterwards, so nothing about what
    // arrives changes -- only how much of it had to be drawn.
    let (want, _) = frames::fit(
        engine.meta.width.max(1),
        engine.meta.height.max(1),
        key.w.max(1),
        key.h.max(1),
    );
    let (rgba, sw, sh, cost) = engine
        .frame_measured(key.t_ms as f64 / 1000.0, Some(want))
        .map_err(|e| e.to_string())?;

    let encode = std::time::Instant::now();
    let (bytes, dw, dh) = if key.raw {
        frames::scale_rgba(&rgba, sw, sh, key.w, key.h).ok_or("that frame did not scale")?
    } else {
        let (w, h) = frames::fit(sw, sh, key.w.max(1), key.h.max(1));
        (
            frames::rgba_to_jpeg(&rgba, sw, sh, key.w, key.h, 82).ok_or("that frame did not encode")?,
            w,
            h,
        )
    };
    let encode_us = encode.elapsed().as_micros() as u64;
    let bytes_len = bytes.len();
    let frame = studio.cache.put(key.clone(), bytes, dw, dh);
    studio.perf.record(perf::FrameSpan {
        t_ms: key.t_ms,
        w: dw,
        h: dh,
        live,
        hit: false,
        wait_us: queue_us + cost.wait_us,
        render_us: cost.render_us,
        read_us: cost.read_us,
        encode_us,
        total_us: queue_us + cost.wait_us + cost.render_us + cost.read_us + encode_us,
        bytes: bytes_len,
    });
    Ok(frame)
}

/// The queue, started on first use. Two workers: the engine renders one frame at a time, so the
/// second worker exists to scale and hand over one frame while the next is being rendered.
pub(super) fn frame_queue(app: &AppHandle) -> Arc<queue::FrameQueue> {
    let studio = app.state::<Studio>();
    studio
        .frames
        .get_or_init(|| {
            let handle = app.clone();
            queue::FrameQueue::start(
                2,
                Arc::new(move |key: &FrameKey, live: bool, queued: std::time::Instant| {
                    make_frame(&handle, key, live, queued)
                }),
            )
        })
        .clone()
}

/// A frame, straight from the cache if it is there. The synchronous path, for tests and for the
/// export preview -- the window goes through the queue instead.
pub fn frame_now(app: &AppHandle, path: &str) -> Result<Frame, String> {
    let (key, _) = frame_wanted(path, None)?;
    let studio = app.state::<Studio>();
    if let Some(hit) = studio.cache.get(&key) {
        return Ok(hit);
    }
    make_frame(app, &key, true, std::time::Instant::now())
}
