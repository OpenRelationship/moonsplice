use super::*;

const SRC: &str = r##"local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3.6, fps = 30,
  background = "#0c1018",

  scene = function(s)
    s:text { x = 48, y = 36, text = "35  CAPTIONS", size = 22, color = "#6b7894" }
    local bar = s:rect { x = 80, y = 528, w = 0, h = 4, rx = 2, color = "#3ee0c6" }
    s:captions {
      x = 80, y = 578, size = 36, color = "#f4f6fb",
      cues = {
        { 0.55, 1.45, "Hold the cut." },
        { 1.45, 2.45, "Let the type land." },
      },
    }

    s:script(function(t)
      t:wait(0.15)
      t:tween(bar, 0.4, { w = 640 }, "expoOut")
    end)
  end,
}
"##;

#[test]
fn no_edits_is_byte_identical() {
    assert_eq!(lower(SRC, &[], None).unwrap(), SRC);
}

/// The three nodes SRC builds, as the engine reports them: `s:captions` builds a *text*
/// node, so its id is text3 and not captions3.
fn engine_nodes() -> Vec<NodeRef> {
    vec![
        NodeRef::at("text1", "text", 8),
        NodeRef::at("rect2", "rect", 9),
        NodeRef::at("text3", "text", 10),
    ]
}

#[test]
fn spans_find_every_node_and_its_local() {
    let spans = node_spans(SRC).unwrap();
    let ids: Vec<&str> = spans.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, vec!["text1", "rect2", "captions3"]);
    assert_eq!(spans[1].var.as_deref(), Some("bar"));
    assert_eq!(spans[0].var, None);
}

#[test]
fn a_node_is_traced_to_the_line_that_wrote_it() {
    let nodes = engine_nodes();
    let layout = Layout::read(SRC, Some(&nodes)).unwrap();
    assert_eq!(layout.span("text3").unwrap().kind, "captions");
    assert_eq!(layout.span("rect2").unwrap().var.as_deref(), Some("bar"));
    assert_eq!(layout.placed(), 3);
}

#[test]
fn a_thing_built_in_a_loop_is_refused_rather_than_changing_all_of_them() {
    // Eight circles from one line, the way every real composition with a loop does it.
    let src = "return e.comp {\n  scene = function(s)\n    for i = 1, 8 do\n      s:circle { x = i * 10, y = 100, r = 20 }\n    end\n  end,\n}\n";
    let nodes: Vec<NodeRef> = (1..=8)
        .map(|i| NodeRef::at(&format!("circle{i}"), "circle", 4))
        .collect();
    let layout = Layout::read(src, Some(&nodes)).unwrap();
    match layout.span("circle3") {
        Err(EditRefusal::Shared { count, .. }) => assert_eq!(count, 8),
        other => panic!("{other:?}"),
    }
    assert_eq!(layout.placed(), 0);
    assert!(layout
        .span("circle3")
        .unwrap_err()
        .to_string()
        .contains("would change all 8"));
}

#[test]
fn a_thing_built_inside_a_helper_is_found_anyway() {
    // Lua replaces a tail-called frame, so `return s:svg{}` inside a helper reports the
    // helper's *call site* as its line. The second pass places it from what is left over.
    let src = "local function plane(s, x)\n  return s:svg { src = \"a.svg\", x = x }\nend\n\nreturn e.comp {\n  scene = function(s)\n    local a = plane(s, 10)\n    local b = plane(s, 20)\n  end,\n}\n";
    let nodes = vec![
        NodeRef::at("svg1", "svg", 7),
        NodeRef::at("svg2", "svg", 8),
    ];
    let layout = Layout::read(src, Some(&nodes)).unwrap();
    // Two nodes, one constructor: the helper is a loop by another name, so both are refused
    // by name rather than one of them silently changing both.
    assert!(matches!(
        layout.span("svg1"),
        Err(EditRefusal::Shared { count: 2, .. })
    ));
}

#[test]
fn a_loop_over_two_constructors_pairs_them_by_turn() {
    let src = "return e.comp {\n  scene = function(s)\n    for i = 1, 3 do\n      s:circle { r = 4 } s:text { text = \"x\" }\n    end\n  end,\n}\n";
    let nodes: Vec<NodeRef> = vec![
        NodeRef::at("circle1", "circle", 4),
        NodeRef::at("text2", "text", 4),
        NodeRef::at("circle3", "circle", 4),
        NodeRef::at("text4", "text", 4),
        NodeRef::at("circle5", "circle", 4),
        NodeRef::at("text6", "text", 4),
    ];
    let layout = Layout::read(src, Some(&nodes)).unwrap();
    // Three of each, so both constructors are shared three ways and both are refused.
    assert!(matches!(
        layout.span("text4"),
        Err(EditRefusal::Shared { count: 3, .. })
    ));
}

#[test]
fn a_node_from_nowhere_is_refused_not_guessed() {
    // Nothing in SRC builds a video, and the line is not one anything was written on, so
    // neither pass can place it and the app says so.
    let nodes = vec![NodeRef::at("ghost1", "video", 999)];
    let layout = Layout::read(SRC, Some(&nodes)).unwrap();
    assert!(matches!(
        layout.span("ghost1"),
        Err(EditRefusal::Unplaceable { .. })
    ));
    assert!(layout
        .span("ghost1")
        .unwrap_err()
        .to_string()
        .contains("cannot be traced back"));
}

#[test]
fn with_no_line_information_it_falls_back_to_counting() {
    let nodes: Vec<NodeRef> = ["text1", "rect2", "text3"]
        .iter()
        .map(|id| NodeRef {
            id: (*id).into(),
            kind: "text".into(),
            line: None,
            props: Vec::new(),
        })
        .collect();
    let layout = Layout::read(SRC, Some(&nodes)).unwrap();
    assert_eq!(layout.span("text3").unwrap().kind, "captions");
}

#[test]
fn a_count_that_cannot_be_paired_refuses_rather_than_guessing() {
    let nodes = vec![NodeRef {
        id: "text1".into(),
        kind: "text".into(),
        line: None,
        props: Vec::new(),
    }];
    assert!(matches!(
        Layout::read(SRC, Some(&nodes)),
        Err(EditRefusal::IdsMisaligned {
            constructors: 3,
            nodes: 1
        })
    ));
}

/// A live model, asked to put a caption behind a bar, invented `z = "-1"` -- and the
/// lowering wrote it into the composition, where nothing reads it. A word the renderer
/// ignores is worse than a refusal: the person is told their change worked.
#[test]
fn a_property_the_thing_does_not_have_is_refused_not_invented() {
    let nodes = vec![NodeRef {
        id: "rect2".into(),
        kind: "rect".into(),
        line: Some(3),
        props: vec!["x".into(), "y".into(), "w".into(), "h".into()],
    }];
    let refused = set_prop(SRC, "rect2", "z", "-1", Some(&nodes));
    assert!(
        matches!(&refused, Err(EditRefusal::NoProp { key, .. }) if key == "z"),
        "got {refused:?}"
    );
    let said = refused.unwrap_err().to_string();
    assert!(said.contains("no \"z\" to set"), "{said}");

    // What it does have still works.
    assert!(set_prop(SRC, "rect2", "w", "640", Some(&nodes)).is_ok());
    // And so does a property anything can have, whether or not it is written down.
    assert!(set_prop(SRC, "rect2", "opacity", "0.5", Some(&nodes)).is_ok());
}

#[test]
fn set_prop_replaces_only_that_field() {
    let out = set_prop(SRC, "rect2", "w", "640", None).unwrap();
    assert!(out.contains("x = 80, y = 528, w = 640, h = 4"));
    assert_eq!(out.len(), SRC.len() + 2);
    // and it left the other node alone
    assert!(out.contains("s:text { x = 48, y = 36,"));
}

#[test]
fn set_prop_inserts_a_missing_field() {
    let out = set_prop(SRC, "rect2", "opacity", "0.5", None).unwrap();
    assert!(out.contains("s:rect { opacity = 0.5, x = 80"));
}

#[test]
fn set_prop_does_not_reach_into_a_nested_table() {
    // `cues` holds tables; a bare `x` inside one must not be mistaken for the node's.
    let out = set_prop(SRC, "captions3", "x", "120", None).unwrap();
    assert!(out.contains("x = 120, y = 578"));
    assert!(out.contains("{ 0.55, 1.45, \"Hold the cut.\" }"));
}

#[test]
fn unknown_node_is_refused_with_the_names_it_knows() {
    match set_prop(SRC, "nope", "x", "1", None) {
        Err(EditRefusal::UnknownNode { known, .. }) => {
            assert_eq!(known, vec!["captions3", "rect2", "text1"]);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_curve_that_does_not_exist_is_refused_not_written() {
    let refused = set_ease(SRC, "rect2", "gently", 0, None);
    assert!(
        matches!(&refused, Err(EditRefusal::NoCurve { asked, .. }) if asked == "gently"),
        "got {refused:?}"
    );
    let said = refused.unwrap_err().to_string();
    assert!(said.contains("Arriving"), "the refusal should offer the real ones: {said}");

    // The word the app itself shows is accepted, and lands as the renderer's own name.
    let out = set_ease(SRC, "rect2", "Arriving", 0, None).unwrap();
    assert!(out.contains("\"expoOut\""), "{out}");
}

#[test]
fn set_ease_rewrites_the_curve_name() {
    let out = set_ease(SRC, "rect2", "sineOut", 0, None).unwrap();
    assert!(out.contains(r#"t:tween(bar, 0.4, { w = 640 }, "sineOut")"#));
}

#[test]
fn set_ease_needs_a_name_to_hold_the_node() {
    assert!(matches!(
        set_ease(SRC, "text1", "sineOut", 0, None),
        Err(EditRefusal::NotInLocal { .. })
    ));
}

#[test]
fn set_ease_appends_when_no_curve_was_written() {
    let src = SRC.replace(r#", "expoOut")"#, ")");
    let out = set_ease(&src, "rect2", "backOut", 0, None).unwrap();
    assert!(out.contains(r#"t:tween(bar, 0.4, { w = 640 }, "backOut")"#));
}

#[test]
fn set_tween_duration_edits_the_number() {
    let out = set_tween_duration(SRC, "rect2", 1.25, 0, None).unwrap();
    assert!(out.contains("t:tween(bar, 1.25, { w = 640 }"));
}

#[test]
fn a_movement_that_is_not_there_is_refused() {
    assert!(matches!(
        set_tween_duration(SRC, "rect2", 1.0, 3, None),
        Err(EditRefusal::NoTween {
            have: 1,
            asked: 3,
            ..
        })
    ));
}

#[test]
fn a_computed_duration_is_refused_rather_than_guessed() {
    let src = SRC.replace("t:tween(bar, 0.4,", "t:tween(bar, dur * 2,");
    assert!(matches!(
        set_tween_duration(&src, "rect2", 1.0, 0, None),
        Err(EditRefusal::NotALiteral { .. })
    ));
}

#[test]
fn set_cue_retimes_one_line() {
    let out = set_cue(SRC, "captions3", 1, Some(1.6), None, None, None).unwrap();
    assert!(out.contains(r#"{ 1.6, 2.45, "Let the type land." }"#));
    assert!(out.contains(r#"{ 0.55, 1.45, "Hold the cut." }"#));
}

#[test]
fn set_cue_rewords_one_line_and_escapes_it() {
    let out = set_cue(SRC, "captions3", 0, None, None, Some("Say \"cut\"."), None).unwrap();
    assert!(out.contains(r#"{ 0.55, 1.45, "Say \"cut\"." }"#));
}

#[test]
fn a_line_that_is_not_there_is_refused() {
    assert!(matches!(
        set_cue(SRC, "captions3", 9, Some(0.0), None, None, None),
        Err(EditRefusal::NoCue { have: 2, asked: 9, .. })
    ));
}

#[test]
fn pin_writes_a_step_into_the_timeline_block() {
    let out = pin_prop(SRC, "rect2", 2.5, "opacity", "0", false, None).unwrap();
    assert!(out.contains("t:at(2.5) t:set(bar, { opacity = 0 })"));
    // still one script block, still closed
    assert_eq!(out.matches("s:script(").count(), 1);
    assert!(out.contains("t:tween(bar, 0.4,"));
}

#[test]
fn pin_refuses_where_a_movement_already_decides_the_value() {
    assert!(matches!(
        pin_prop(SRC, "rect2", 0.3, "w", "100", true, None),
        Err(EditRefusal::Conflict { .. })
    ));
}

#[test]
fn edits_apply_in_order_and_compose() {
    let edits = vec![
        Edit::SetProp {
            node: "rect2".into(),
            key: "h".into(),
            value: serde_json::json!(8),
        },
        Edit::SetEase {
            node: "rect2".into(),
            ease: "quadOut".into(),
            occurrence: 0,
        },
    ];
    let out = lower(SRC, &edits, None).unwrap();
    assert!(out.contains("h = 8,"));
    assert!(out.contains(r#""quadOut""#));
}

#[test]
fn numbers_read_the_way_a_person_wrote_them() {
    assert_eq!(fmt_num(2.0), "2");
    assert_eq!(fmt_num(0.55), "0.55");
    assert_eq!(fmt_num(1.25), "1.25");
    assert_eq!(fmt_num(-3.0), "-3");
}

#[test]
fn match_brace_skips_strings_and_comments() {
    let src = "{ a = \"}\", -- }\n b = { c = 1 } }";
    assert_eq!(match_brace(src, 0), src.len());
}

#[test]
fn a_gesture_with_no_verb_is_refused_not_applied() {
    // The UI asks to move where a movement *starts*. No verb says that, so the app
    // must refuse rather than open a second edit path.
    let refusal = EditRefusal::NoVerb {
        gesture: "move when a movement starts".into(),
    };
    assert!(refusal.to_string().contains("nothing was changed"));
}
