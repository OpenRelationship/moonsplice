use super::*;

fn key(h: &str, t: u32) -> FrameKey {
    FrameKey {
        variation: "v1".into(),
        hash: h.into(),
        t_ms: t,
        w: 640,
        h: 360,
        raw: true,
    }
}

#[test]
fn a_changed_source_is_simply_a_different_key() {
    let c = FrameCache::new(1024 * 1024);
    c.put(key("aaa", 0), vec![0; 100], 640, 360);
    assert!(c.get(&key("aaa", 0)).is_some());
    // the edit lands; nothing tells the cache anything
    assert!(c.get(&key("bbb", 0)).is_none());
}

#[test]
fn the_cache_stays_inside_its_budget() {
    let c = FrameCache::new(250);
    for t in 0..10 {
        c.put(key("aaa", t), vec![0; 100], 640, 360);
    }
    let (_, _, bytes) = c.stats();
    assert!(bytes <= 250, "{bytes} over budget");
    assert!(c.get(&key("aaa", 9)).is_some(), "the newest survived");
    assert!(c.get(&key("aaa", 0)).is_none(), "the oldest went first");
}

#[test]
fn forgetting_one_composition_leaves_the_other() {
    let c = FrameCache::new(1024 * 1024);
    c.put(key("aaa", 0), vec![0; 10], 640, 360);
    c.put(key("bbb", 0), vec![0; 10], 640, 360);
    c.forget("aaa");
    assert!(c.get(&key("aaa", 0)).is_none());
    assert!(c.get(&key("bbb", 0)).is_some());
}

#[test]
fn a_frame_fits_its_box_without_upscaling() {
    assert_eq!(fit(1920, 1080, 960, 540), (960, 540));
    assert_eq!(fit(1920, 1080, 960, 200), (356, 200));
    assert_eq!(fit(640, 360, 1920, 1080), (640, 360));
}

#[test]
fn rgba_encodes_to_a_jpeg_of_the_asked_size() {
    let (w, h) = (64u32, 36u32);
    let rgba: Vec<u8> = (0..w * h)
        .flat_map(|i| [(i % 255) as u8, 30, 200, 255])
        .collect();
    let jpg = rgba_to_jpeg(&rgba, w, h, 32, 32, 85).expect("encoded");
    assert_eq!(&jpg[..2], &[0xff, 0xd8], "a JPEG starts with SOI");
    let got = image::load_from_memory(&jpg).unwrap();
    assert_eq!((got.width(), got.height()), (32, 18));
}

#[test]
fn the_raw_frame_is_four_channels_and_opaque() {
    // What a canvas takes, with no conversion in the window: RGBA, alpha already 1.
    let (w, h) = (8u32, 4u32);
    let rgba: Vec<u8> = (0..w * h).flat_map(|_| [10, 20, 30, 128]).collect();
    let (out, dw, dh) = scale_rgba(&rgba, w, h, 4, 2).expect("scaled");
    assert_eq!((dw, dh), (4, 2));
    assert_eq!(out.len(), 4 * 2 * 4);
    assert_eq!(&out[..4], &[10, 20, 30, 255], "opaque, whatever the source alpha was");
}

#[test]
fn a_short_buffer_is_refused_rather_than_read_past() {
    assert!(rgba_to_jpeg(&[0; 8], 64, 36, 64, 36, 85).is_none());
}
