use super::*;

const THREE: &str = r##"local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,

  scene = function(s)
    s:rect { x = 0, y = 0, w = 1280, h = 720, color = "#101418" }
    local bar = s:rect { x = 80, y = 528, w = 0, h = 4, color = "#3ee0c6" }
    s:text { x = 48, y = 36, text = "TOP", size = 22 }

    s:script(function(t)
      t:tween(bar, 0.4, { w = 640 }, "expoOut")
    end)
  end,
}
"##;

fn nodes() -> Vec<NodeRef> {
    vec![
        NodeRef::at("rect1", "rect", 7),
        NodeRef::at("rect2", "rect", 8),
        NodeRef::at("text3", "text", 9),
    ]
}

/// The order of the statements is the order of the picture, so the only thing worth asserting
/// is which line is where.
fn order(src: &str) -> Vec<&str> {
    src.lines()
        .filter_map(|l| {
            let t = l.trim();
            if t.starts_with("s:") || t.starts_with("local ") {
                t.split_whitespace().last()
            } else {
                None
            }
        })
        .collect()
}

#[test]
fn a_thing_is_brought_in_front_of_another() {
    // The backdrop, which is drawn first, put in front of the bar.
    let out = reorder(THREE, "rect1", Some("rect2"), Some(&nodes())).unwrap();
    let lines: Vec<&str> = out.lines().map(str::trim).collect();
    let backdrop = lines.iter().position(|l| l.contains("#101418")).unwrap();
    let bar = lines.iter().position(|l| l.contains("#3ee0c6")).unwrap();
    let top = lines.iter().position(|l| l.contains("\"TOP\"")).unwrap();
    assert!(bar < backdrop && backdrop < top, "{out}");
    // And nothing else changed: same lines, in a different order.
    assert_eq!(order(&out).len(), order(THREE).len());
}

#[test]
fn a_thing_is_sent_to_the_very_back() {
    let out = reorder(THREE, "text3", None, Some(&nodes())).unwrap();
    let lines: Vec<&str> = out.lines().map(str::trim).collect();
    let top = lines.iter().position(|l| l.contains("\"TOP\"")).unwrap();
    let backdrop = lines.iter().position(|l| l.contains("#101418")).unwrap();
    assert!(top < backdrop, "{out}");
}

#[test]
fn a_thing_something_else_reads_does_not_move_past_it() {
    // The bar is tweened by the script at the end. Moving it in front of the text is fine --
    // the script is still after it -- but there is nothing after the script to move it to.
    let ok = reorder(THREE, "rect2", Some("text3"), Some(&nodes())).unwrap();
    assert!(ok.contains("t:tween(bar"), "{ok}");

    // Now the other direction: the text moved behind the bar would put it above nothing it
    // reads, so that is allowed too. What is not allowed is the bar going after its script.
    let with_last = THREE.replace(
        "    end)\n",
        "    end)\n    s:rect { x = 0, y = 0, w = 10, h = 10, color = \"#fff\" }\n",
    );
    let mut all = nodes();
    all.push(NodeRef::at("rect4", "rect", 15));
    let err = reorder(&with_last, "rect2", Some("rect4"), Some(&all)).unwrap_err();
    assert!(err.to_string().contains("what moves it is written between"), "{err}");
}

#[test]
fn a_thing_does_not_move_above_what_it_is_made_of() {
    let src = THREE.replace(
        r#"    s:text { x = 48, y = 36, text = "TOP", size = 22 }"#,
        "    local pill = s:rect { x = 0, y = 0, w = 40, h = 20 }\n    s:text { x = 48, y = 36, text = \"TOP\", size = 22, clip_node = pill }",
    );
    let all = vec![
        NodeRef::at("rect1", "rect", 7),
        NodeRef::at("rect2", "rect", 8),
        NodeRef::at("rect3", "rect", 9),
        NodeRef::at("text4", "text", 10),
    ];
    let err = reorder(&src, "text4", None, Some(&all)).unwrap_err();
    assert!(err.to_string().contains("does not exist yet"), "{err}");
}

#[test]
fn putting_a_thing_where_it_already_is_changes_nothing() {
    let same = reorder(THREE, "rect2", Some("rect1"), Some(&nodes())).unwrap();
    assert_eq!(same, THREE);
    let err = reorder(THREE, "rect1", Some("rect1"), Some(&nodes())).unwrap_err();
    assert!(err.to_string().contains("in front of itself"), "{err}");
}
