/// A player asks for ranges, and a viewer that cannot answer them shows a clip that will not
/// seek and sometimes will not start. So the answers are checked against real bytes.
#[test]
fn an_asset_is_served_whole_or_in_the_slice_a_player_asked_for() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("clip.mp4");
    std::fs::write(&file, (0u8..=255).collect::<Vec<u8>>()).unwrap();

    // No range: all of it, and what it is.
    let (status, bytes, media, part) = read_slice(&file, None).unwrap();
    assert_eq!((status, media.as_str(), part), (200, "video/mp4", None));
    assert_eq!(bytes.len(), 256);

    // A range: exactly those bytes, and where they sit in the whole.
    let (status, bytes, _, part) = read_slice(&file, Some("bytes=10-13")).unwrap();
    assert_eq!(status, 206);
    assert_eq!(bytes, vec![10, 11, 12, 13]);
    assert_eq!(part, Some((10, 13, 256)));

    // "From here on" is answered to the end.
    let (_, bytes, _, part) = read_slice(&file, Some("bytes=250-")).unwrap();
    assert_eq!(bytes, vec![250, 251, 252, 253, 254, 255]);
    assert_eq!(part, Some((250, 255, 256)));

    // Past the end is clamped rather than read past.
    let (_, bytes, _, part) = read_slice(&file, Some("bytes=200-9999")).unwrap();
    assert_eq!(bytes.len(), 56);
    assert_eq!(part, Some((200, 255, 256)));

    // Nonsense is no range at all, which is a whole answer rather than an error.
    let (status, bytes, _, _) = read_slice(&file, Some("pages=2")).unwrap();
    assert_eq!((status, bytes.len()), (200, 256));
    assert_eq!(parse_range("bytes=x-y"), None);
    assert_eq!(parse_range("bytes=4-"), Some((4, None)));
}

use super::*;

fn outline_with_a_movement() -> serde_json::Value {
    serde_json::json!({
        "comp": { "title": "Hero", "duration": 2.0, "width": 1280, "height": 720, "fps": 30 },
        "nodes": [{ "id": "rect2", "kind": "rect", "label": null }],
        "tracks": [{
            "node": "rect2", "prop": "w",
            "segments": [{ "kind": "tween", "t0": 0.15, "t1": 0.55, "from": 0, "to": 640,
                           "ease": "expoOut", "manual": false }]
        }],
        "cues": [], "audio": [], "cli_only": []
    })
}

#[test]
fn a_drag_becomes_two_span_rewrites() {
    let edits = gesture_to_edits(
        Gesture::Move {
            node: "rect2".into(),
            x: 12.345,
            y: 20.0,
        },
        &outline_with_a_movement(),
    )
    .unwrap();
    assert_eq!(edits.len(), 2);
    match &edits[0] {
        Edit::SetProp { key, value, .. } => {
            assert_eq!(key, "x");
            assert_eq!(value, &serde_json::json!(12.35));
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn dragging_a_thing_the_timeline_moves_is_refused_with_the_reason() {
    let mut o = outline_with_a_movement();
    o["tracks"][0]["prop"] = serde_json::json!("x");
    let err = gesture_to_edits(
        Gesture::Move {
            node: "rect2".into(),
            x: 10.0,
            y: 10.0,
        },
        &o,
    )
    .unwrap_err();
    assert!(err.to_string().contains("change the movement instead"));
}

/// The last gesture that had no verb. It has one, and it is a difference rather than a time:
/// when a movement begins is everything before it in the script added up.
#[test]
fn dragging_where_a_movement_starts_moves_it_by_the_difference() {
    let o = outline_with_a_movement();
    // The movement runs 0.15..0.55. Dragged to 0.4 it starts a quarter of a second later.
    let edits = gesture_to_edits(
        Gesture::MoveStart {
            node: "rect2".into(),
            t: 0.4,
            occurrence: 0,
        },
        &o,
    )
    .unwrap();
    match &edits[..] {
        [Edit::MoveTweenStart { delta, .. }] => assert!((delta - 0.25).abs() < 1e-9),
        other => panic!("{other:?}"),
    }

    // A movement that is not there is said in words, without an id in them.
    let err = gesture_to_edits(
        Gesture::MoveStart {
            node: "rect2".into(),
            t: 1.0,
            occurrence: 9,
        },
        &o,
    )
    .unwrap_err();
    let said = err.say(&words::names(&o));
    assert!(said.contains("no movement there"), "{said}");
    assert!(!said.contains("rect2"), "an id reached a person: {said}");
}

/// What paints over what is a verb now. What has no front or back still is not.
#[test]
fn restacking_a_picture_is_a_verb_and_restacking_sound_is_not() {
    let edits = gesture_to_edits(
        Gesture::Restack {
            node: "rect2".into(),
            over: None,
        },
        &outline_with_a_movement(),
    )
    .unwrap();
    assert!(matches!(&edits[..], [Edit::Restack { over: None, .. }]));

    let with_sound = serde_json::json!({
        "comp": { "title": "Hero", "duration": 2.0, "width": 1280, "height": 720, "fps": 30 },
        "nodes": [
            { "id": "rect2", "kind": "rect", "label": null },
            { "id": "tts3", "kind": "tts", "label": "Line one" }
        ],
        "tracks": [], "cues": [], "audio": [], "cli_only": []
    });
    let err = gesture_to_edits(
        Gesture::Restack {
            node: "tts3".into(),
            over: Some("rect2".into()),
        },
        &with_sound,
    )
    .unwrap_err();
    let said = err.say(&words::names(&with_sound));
    assert!(said.contains("no front or back"), "{said}");
    assert!(!said.contains("tts3"), "an id reached a person: {said}");
}

#[test]
fn a_pin_inside_a_movement_is_marked_as_covered() {
    let o = outline_with_a_movement();
    assert!(moving_at(&o, "rect2", "w", 0.3));
    assert!(!moving_at(&o, "rect2", "w", 1.5));
    assert!(!moving_at(&o, "rect2", "x", 0.3));
    let edits = gesture_to_edits(
        Gesture::Pin {
            node: "rect2".into(),
            t: 0.3,
            key: "w".into(),
            value: serde_json::json!(100),
        },
        &o,
    )
    .unwrap();
    match &edits[0] {
        Edit::PinProp { covered, .. } => assert!(*covered),
        other => panic!("{other:?}"),
    }
}

#[test]
fn the_outline_reads_as_sentences_with_no_json_in_them() {
    let text = describe(&outline_with_a_movement());
    assert!(text.contains("Hero — 2.0s, 1280x720, 30 fps."), "{text}");
    assert!(
        text.contains("Block's width moves from 0 to 640 between 0.15s and 0.55s, arriving"),
        "{text}"
    );
    assert!(!text.contains('{'));
}

/// What the agent reads is what it says back. It read `rect4` and told someone who opened
/// this app to avoid code that "rect4 is the teal bar" — so nothing it reads may be code.
#[test]
fn nothing_the_agent_reads_about_a_composition_is_code() {
    let o = outline_with_a_movement();
    let text = describe(&o);
    for code in ["rect2", "text1", "expoOut", "'s w ", "{", "}", ".lua"] {
        assert!(!text.contains(code), "describe said `{code}`:\n{text}");
    }
    let at = describe_instant(&serde_json::json!({
        "t": 0.5,
        "nodes": [{ "id": "rect2", "kind": "rect", "props": { "x": 80, "opacity": 1 } }]
    }));
    for code in ["rect2", "opacity", "\"x\""] {
        assert!(!at.contains(code), "the instant said `{code}`:\n{at}");
    }
    eprintln!("{text}\n---\n{at}");
}

#[test]
fn an_empty_composition_says_so_rather_than_listing_nothing() {
    let mut o = outline_with_a_movement();
    o["nodes"] = serde_json::json!([]);
    o["tracks"] = serde_json::json!([]);
    assert!(describe(&o).contains("It is empty"));
}

#[test]
fn a_pinned_value_reads_differently_from_a_movement() {
    let mut o = outline_with_a_movement();
    o["tracks"][0]["segments"][0] = serde_json::json!({
        "kind": "pin", "t0": 1.0, "t1": 1.0, "to": 0, "manual": true
    });
    let text = describe(&o);
    assert!(text.contains("was set by hand at 1.00s"), "{text}");
    assert!(!text.contains("moves from"));
}

#[test]
fn a_frame_url_is_rejected_when_it_is_not_one() {
    // No app handle here, so only the parsing is under test; it must not panic.
    assert!(frame_wanted("hero", None).is_err());
    assert!(frame_wanted("hero/abc/soon/640x360.raw", None).is_err());
    assert!(frame_wanted("hero/abc/500/640.raw", None).is_err());

    let (key, live) = frame_wanted("hero%20wide/abc/500/640x360.raw", None).expect("a frame");
    assert_eq!(key.variation, "hero wide", "a name with a space survives the url");
    assert_eq!((key.hash.as_str(), key.t_ms, key.w, key.h), ("abc", 500, 640, 360));
    assert!(key.raw, "the preview asks for pixels");
    assert!(live, "and by default somebody is looking at them");

    // `.jpg` is the same frame as a picture, and a different cache entry.
    let (pic, _) = frame_wanted("hero/abc/500/640x360.jpg", None).expect("a picture");
    assert!(!pic.raw);
    assert_ne!(pic, key);

    // Warmed ahead: same frame, and the queue is told nobody is waiting on it.
    let (same, live) = frame_wanted("hero/abc/500/640x360.raw", Some("warm=1")).expect("warm");
    assert_eq!(same, frame_wanted("hero/abc/500/640x360.raw", None).unwrap().0);
    assert!(!live);
}

#[test]
fn a_name_with_a_space_survives_the_url() {
    assert_eq!(urldecode("hero%20wide"), "hero wide");
}

/// The real stderr of a real failed export, which put a LÖVE stack frame in front of the
/// person exporting. Whatever else it says, it says nothing that looks like code.
#[test]
fn a_failed_export_says_nothing_that_looks_like_code() {
    let real = "moonsplice error: scene.lua:43: moonsplice-scene: font not found: \
comps/assets/fonts/Roboto-Regular.ttf\nstack traceback:\n\tmain.lua:497: in function 'handler'\n\
\t[love \"boot.lua\"]:352: in function <[love \"boot.lua\"]:348>\n\t[C]: in function 'assert'\n\
\t[love \"boot.lua\"]:377: in function <[love \"boot.lua\"]:344>";
    let said = trouble(real);
    assert_eq!(said, "font not found");
    for code in [".lua", "boot", "traceback", "scene.lua", "/", "[C]", ":43", "moonsplice"] {
        assert!(!said.contains(code), "{said:?} still shows {code}");
    }
}

#[test]
fn an_engine_failure_with_nothing_to_say_says_so() {
    assert_eq!(trouble(""), "the render did not finish");
    assert_eq!(
        trouble("stack traceback:\n\t[C]: in function 'assert'"),
        "the render did not finish"
    );
    // A path on its own is not a sentence, and a person is not owed it.
    assert_eq!(
        trouble("moonsplice error: /Users/someone/x/comps/hero.lua:12:"),
        "the render did not finish"
    );
}

#[test]
fn a_plain_engine_message_reaches_the_person_unchanged() {
    assert_eq!(
        trouble("moonsplice error: main.lua:88: out of memory"),
        "out of memory"
    );
    assert_eq!(trouble("ffmpeg is not installed"), "ffmpeg is not installed");
}

#[test]
fn a_word_with_a_directory_or_an_extension_in_it_is_not_a_word_a_person_chose() {
    for code in ["comps/assets/x.ttf", "scene.lua", "main.lua:497", "hero.mp4", "C:\\x\\y"] {
        assert!(looks_like_a_path(code), "{code} should read as code");
    }
    for word in ["font", "not", "found", "memory", "finish.", "ffmpeg"] {
        assert!(!looks_like_a_path(word), "{word} should read as a word");
    }
}
