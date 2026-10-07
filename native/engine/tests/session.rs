//! A session in this process serves the frames the offline render hashes, and a composition
//! that will not open ends its session, not the process.

use std::path::{Path, PathBuf};

use md5::{Digest, Md5};
use moonsplice_engine::Session;

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap()
}

fn start(comp: &str, serve_dir: &Path) -> Session {
    let root = root();
    Session::start(
        &root.join("core").join("runtime"),
        vec!["--serve".into(), comp.into()],
        vec![
            ("MOONSPLICE_CWD".into(), root.display().to_string()),
            ("MOONSPLICE_SERVE_DIR".into(), serve_dir.display().to_string()),
            ("MOONSPLICE_HEADLESS".into(), "1".into()),
        ],
    )
    .unwrap()
}

fn golden(case: &str, frame: usize) -> String {
    let text = std::fs::read_to_string(root().join(format!(".robot/golden/{case}.scene.md5"))).unwrap();
    let line = text.lines().find(|l| l.starts_with(&format!("FRAME {frame} "))).unwrap();
    line.split_whitespace().nth(2).unwrap().to_string()
}

#[test]
fn frames_match_the_goldens() {
    if std::env::var("MOONSPLICE_SCENE_THREADS").map(|v| v != "0").unwrap_or(false) {
        return; // goldens are taken at threads=0
    }
    let dir = std::env::temp_dir().join(format!("moonsplice-session-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let s = start("comps/cases/blend_modes.lua", &dir);
    let ready = s.recv().unwrap();
    assert!(ready.starts_with("ready 1280 720"), "{ready}");
    for (seq, frame) in [(1, 0usize), (2, 30), (3, 12)] {
        s.send(&format!(r#"{{"op":"frame","t":{},"seq":{seq}}}"#, frame as f64 / 30.0)).unwrap();
        let reply = s.recv().unwrap();
        let path = reply.split_whitespace().nth(1).unwrap();
        assert!(reply.starts_with("frame "), "{reply}");
        let bytes = s.take(path).expect("the frame's bytes");
        assert_eq!(bytes.len(), 1280 * 720 * 4);
        assert_eq!(format!("{:x}", Md5::digest(&bytes)), golden("blend_modes", frame), "frame {frame}");
    }
    s.send(r#"{"op":"outline","seq":4}"#).unwrap();
    let reply = s.recv().unwrap();
    let path = reply.split_whitespace().nth(1).unwrap();
    let doc = String::from_utf8(s.take(path).unwrap()).unwrap();
    assert!(doc.contains("\"nodes\""), "{doc}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_composition_that_will_not_open_ends_only_its_session() {
    let dir = std::env::temp_dir().join(format!("moonsplice-session-bad-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("bad.lua"), "return 1 +").unwrap();
    let mut s = Session::start(
        &root().join("core").join("runtime"),
        vec!["--serve".into(), "bad.lua".into()],
        vec![
            ("MOONSPLICE_CWD".into(), dir.display().to_string()),
            ("MOONSPLICE_SERVE_DIR".into(), dir.display().to_string()),
        ],
    )
    .unwrap();
    assert!(s.recv().is_err(), "no greeting from a comp that does not parse");
    assert_eq!(s.stop(), Some(1));
    assert!(s.said().iter().any(|l| l.contains("bad.lua")), "{:?}", s.said());
    // and the process is still here to say so
    let _ = std::fs::remove_dir_all(&dir);
}
