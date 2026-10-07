use super::*;

const CLIPS: &str = r##"local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 10, fps = 30,

  scene = function(s)
    local shot = s:video { src = "a.mp4", from = 1, duration = 6, media_start = 2, x = 0, y = 0 }
    s:rect { x = 0, y = 600, w = 1280, h = 120, color = "#000000aa" }
  end,
}
"##;

fn nodes() -> Vec<NodeRef> {
    vec![NodeRef::at("video1", "video", 7), NodeRef::at("rect2", "rect", 8)]
}

#[test]
fn a_clip_cut_in_two_is_the_same_clip_twice() {
    let out = split(CLIPS, "video1", 4.0, Some(&nodes())).unwrap();

    // The half that stays keeps its name and stops at the cut.
    assert!(
        out.contains(
            r#"local shot = s:video { src = "a.mp4", from = 1, duration = 3, media_start = 2, x = 0, y = 0 }"#
        ),
        "{out}"
    );
    // The half that is made starts there, and starts three seconds further into the footage
    // -- so the frame after the cut is the frame that was after the cut before it.
    assert!(
        out.contains(
            r#"    s:video { src = "a.mp4", from = 4, duration = 3, media_start = 5, x = 0, y = 0 }"#
        ),
        "{out}"
    );
    // It is written under the clip it came from, not at the end of the scene: what it draws
    // over and what draws over it are unchanged.
    let first = out.find("local shot").unwrap();
    let second = out[first..].find("s:video").map(|k| first + k).unwrap();
    let plate = out.find("s:rect").unwrap();
    assert!(second < plate, "the new half landed after the plate\n{out}");
    // And nothing else moved.
    assert_eq!(out.lines().count(), CLIPS.lines().count() + 1);
}

#[test]
fn the_cut_has_to_land_inside_the_clip() {
    for t in [0.5, 1.0, 7.0, 9.0] {
        let err = split(CLIPS, "video1", t, Some(&nodes())).unwrap_err();
        assert!(
            err.to_string().contains("inside the clip"),
            "{t}s: {err}"
        );
    }
}

#[test]
fn a_thing_with_no_length_is_not_cut_but_told_why() {
    let err = split(CLIPS, "rect2", 4.0, Some(&nodes())).unwrap_err();
    assert!(err.to_string().contains("no length of its own"), "{err}");
}

#[test]
fn cutting_twice_makes_three_and_they_join_up() {
    let once = split(CLIPS, "video1", 3.0, Some(&nodes())).unwrap();
    // The engine would now report three nodes; the second half is the new video2.
    let three = vec![
        NodeRef::at("video1", "video", 7),
        NodeRef::at("video2", "video", 8),
        NodeRef::at("rect3", "rect", 9),
    ];
    let twice = split(&once, "video2", 5.0, Some(&three)).unwrap();

    // 1..3, 3..5, 5..7 -- no gap, no overlap, and each starts where the last left off in
    // the footage as well as on the timeline.
    let spans: Vec<(f64, f64, f64)> = twice
        .lines()
        .filter(|l| l.contains("s:video"))
        .map(|l| {
            let n = |k: &str| {
                field(&l[l.find('{').unwrap()..], k)
                    .unwrap()
                    .parse::<f64>()
                    .unwrap()
            };
            (n("from"), n("duration"), n("media_start"))
        })
        .collect();
    assert_eq!(spans, vec![(1.0, 2.0, 2.0), (3.0, 2.0, 4.0), (5.0, 2.0, 6.0)], "{twice}");
}

#[test]
fn a_clip_given_a_name_by_hand_does_not_get_it_twice() {
    let src = CLIPS.replace(
        r#"{ src = "a.mp4", from = 1"#,
        r#"{ id = "hero", src = "a.mp4", from = 1"#,
    );
    let out = split(&src, "hero", 4.0, Some(&[NodeRef::at("hero", "video", 7), NodeRef::at("rect2", "rect", 8)])).unwrap();
    assert_eq!(out.matches(r#"id = "hero""#).count(), 1, "{out}");
}
