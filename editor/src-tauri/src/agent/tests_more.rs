use super::tests::*;
use super::*;

#[test]
fn a_change_is_put_to_the_person_before_the_body_runs() {
    let app = FakeApp::new();
    let rec = Recorder::new(true);
    let out = run(
        vec![
            reply_calls(&[(
                "change",
                serde_json::json!({
                    "edits": [{"verb": "set_prop", "node": "text1", "key": "opacity", "value": 1}],
                    "why": "made the caption visible"
                }),
            )]),
            reply_text("The caption shows now."),
        ],
        app.clone(),
        rec.clone(),
        "make the caption visible",
    )
    .unwrap();
    assert_eq!(out.stop, "answered");
    let asked = rec.asked.lock().unwrap();
    assert_eq!(asked.len(), 1);
    assert_eq!(asked[0].tool, "change");
    assert_eq!(app.changed.lock().unwrap().len(), 1);
}

#[test]
fn a_refusal_is_a_result_the_model_reads_and_nothing_is_written() {
    let app = FakeApp::new();
    let rec = Recorder::new(false); // the person says no
    let out = run(
        vec![
            reply_calls(&[(
                "change",
                serde_json::json!({
                    "edits": [{"verb": "set_prop", "node": "text1", "key": "x", "value": 0}],
                    "why": "moved the caption"
                }),
            )]),
            reply_text("You turned that down, so nothing moved."),
        ],
        app.clone(),
        rec.clone(),
        "put the caption on the left",
    )
    .unwrap();
    assert_eq!(out.stop, "answered", "a refusal is not an error");
    assert!(app.changed.lock().unwrap().is_empty(), "the body never ran");
    assert_eq!(rec.asked.lock().unwrap().len(), 1);
}

#[test]
fn twelve_edits_for_one_intention_reach_the_app_as_one_call() {
    let app = FakeApp::new();
    let rec = Recorder::new(true);
    let edits: Vec<serde_json::Value> = (0..12)
        .map(|i| serde_json::json!({"verb": "set_prop", "node": "text1", "key": "x", "value": i}))
        .collect();
    run(
        vec![
            reply_calls(&[(
                "change",
                serde_json::json!({ "edits": edits, "why": "lined everything up" }),
            )]),
            reply_text("Lined up."),
        ],
        app.clone(),
        rec,
        "line it all up",
    )
    .unwrap();
    let changed = app.changed.lock().unwrap();
    assert_eq!(changed.len(), 1, "one call, so one undo step");
    assert_eq!(changed[0].len(), 12);
}

#[test]
fn an_edit_the_composition_cannot_express_comes_back_as_a_sentence() {
    let app = FakeApp::new();
    let rec = Recorder::new(true);
    let out = run(
        vec![
            reply_calls(&[(
                "change",
                serde_json::json!({
                    "edits": [{"verb": "set_prop", "node": "ghost", "key": "x", "value": 0}],
                    "why": "moved a ghost"
                }),
            )]),
            reply_text("There is nothing by that name."),
        ],
        app.clone(),
        rec,
        "move the ghost",
    )
    .unwrap();
    assert_eq!(out.stop, "answered");
    assert!(app.changed.lock().unwrap().is_empty());
}

#[test]
fn the_pixel_model_never_reaches_the_composition() {
    let app = FakeApp::new();
    let rec = Recorder::new(true);
    let out = run(
        vec![
            reply_calls(&[(
                "repaint",
                serde_json::json!({ "instruction": "remove the sign" }),
            )]),
            reply_text("That is new footage; the composition is unchanged."),
        ],
        app.clone(),
        rec,
        "take the sign out of the render",
    )
    .unwrap();
    assert_eq!(out.stop, "answered");
    assert!(app.changed.lock().unwrap().is_empty());
}

#[test]
fn the_loop_always_ends_and_says_why() {
    let app = FakeApp::new();
    let rec = Recorder::new(true);
    // A model that only ever asks to read: the budget is what stops it.
    let replies: Vec<serde_json::Value> = (0..40)
        .map(|_| reply_calls(&[("holds", serde_json::json!({}))]))
        .collect();
    let out = run(replies, app, rec, "keep going").unwrap();
    assert_eq!(out.stop, "budget");
    assert!(out.reason.unwrap_or_default().len() > 0);
}

#[test]
fn stopping_a_turn_refuses_every_tool_from_then_on() {
    let p = paths();
    let app = FakeApp::new();
    let rec = Recorder::new(true);
    let cancel = Cancel::default();
    cancel.stop();
    let out = run_turn(
        Turn {
            paths: &p,
            bridge: app.clone(),
            surface: rec,
            transport: Scripted::new(vec![
                reply_calls(&[("holds", serde_json::json!({}))]),
                reply_text("I was stopped."),
            ]),
            scheme: "openrouter",
            key: "sk-test",
            model: None,
            budget: None,
            cancel,
        },
        "look at it",
        &[],
    )
    .unwrap();
    assert_eq!(out.stop, "answered");
    assert!(app.changed.lock().unwrap().is_empty());
}

#[test]
fn the_request_names_the_declaration_s_model_and_its_tools() {
    let app = FakeApp::new();
    let rec = Recorder::new(true);
    let transport = Scripted::new(vec![reply_text("nothing to do")]);
    let p = paths();
    run_turn(
        Turn {
            paths: &p,
            bridge: app,
            surface: rec,
            transport: transport.clone(),
            scheme: "openrouter",
            key: "sk-test",
            model: None,
            budget: None,
            cancel: Cancel::default(),
        },
        "hello",
        &[],
    )
    .unwrap();
    let seen = transport.seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    let body = &seen[0];
    assert_eq!(body["model"], "minimax/minimax-m3");
    let names: Vec<&str> = body["tools"]
        .as_array()
        .expect("tools")
        .iter()
        .map(|t| t["function"]["name"].as_str().unwrap_or(""))
        .collect();
    for expected in ["holds", "at", "shows", "change", "undo", "export", "repaint"] {
        assert!(names.contains(&expected), "{expected} is missing from {names:?}");
    }
}

#[test]
fn the_history_the_ui_holds_is_what_the_model_is_shown() {
    let app = FakeApp::new();
    let rec = Recorder::new(true);
    let transport = Scripted::new(vec![reply_text("still here")]);
    let p = paths();
    run_turn(
        Turn {
            paths: &p,
            bridge: app,
            surface: rec,
            transport: transport.clone(),
            scheme: "openrouter",
            key: "sk-test",
            model: None,
            budget: None,
            cancel: Cancel::default(),
        },
        "and now",
        &[
            Said {
                role: "user".into(),
                text: "make it blue".into(),
            },
            Said {
                role: "assistant".into(),
                text: "done".into(),
            },
        ],
    )
    .unwrap();
    let seen = transport.seen.lock().unwrap();
    let text = seen[0]["messages"].to_string();
    assert!(text.contains("make it blue"));
    assert!(text.contains("and now"));
}

#[test]
fn the_chat_surface_s_roles_become_the_harness_s() {
    assert_eq!(malleable_role("assistant"), "agent");
    assert_eq!(malleable_role("user"), "user");
    assert_eq!(malleable_role("system"), "user", "nothing else may be a role");
}

#[test]
fn two_is_the_port_convention_in_both_directions() {
    assert_eq!(two(Ok("ok".into())), (Some("ok".into()), None));
    assert_eq!(two(Err("no".into())), (None, Some("no".into())));
}
