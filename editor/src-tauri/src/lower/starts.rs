use super::*;

const SCRIPT: &str = r##"local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 4, fps = 30,

  scene = function(s)
    local bar = s:rect { x = 80, y = 528, w = 0, h = 4 }
    local dot = s:circle { x = 40, y = 40, r = 8 }

    s:script(function(t)
      t:wait(0.15)
      t:tween(bar, 0.4, { w = 640 }, "expoOut")
      t:tween(dot, 0.3, { x = 900 }, "sineOut")
      t:wait(0.2)
      t:tween(bar, 0.5, { w = 100 }, "sineIn")
    end)
  end,
}
"##;

fn nodes() -> Vec<NodeRef> {
    vec![NodeRef::at("rect1", "rect", 7), NodeRef::at("circle2", "circle", 8)]
}

#[test]
fn a_movement_with_a_wait_before_it_starts_later_by_changing_the_wait() {
    let out = move_tween_start(SCRIPT, "rect1", 0, 0.35, Some(&nodes())).unwrap();
    assert!(out.contains("t:wait(0.5)"), "{out}");
    // And nothing else was touched: the movement itself is the same words.
    assert!(out.contains(r#"t:tween(bar, 0.4, { w = 640 }, "expoOut")"#));
    assert_eq!(out.lines().count(), SCRIPT.lines().count());
}

#[test]
fn it_starts_earlier_the_same_way_and_stops_at_zero() {
    let out = move_tween_start(SCRIPT, "rect1", 0, -0.15, Some(&nodes())).unwrap();
    assert!(out.contains("t:wait(0)"), "{out}");

    // Past the thing in front of it, it is refused, with how far past.
    let err = move_tween_start(SCRIPT, "rect1", 0, -0.9, Some(&nodes())).unwrap_err();
    assert!(err.to_string().contains("0.75s before"), "{err}");
}

#[test]
fn a_movement_with_nothing_before_it_gets_a_wait_of_its_own() {
    // The dot's movement follows the bar's directly: there is no wait to change, so one goes
    // in, on its own line, at the indentation already there.
    let out = move_tween_start(SCRIPT, "circle2", 0, 0.25, Some(&nodes())).unwrap();
    assert!(out.contains("      t:wait(0.25)\n      t:tween(dot,"), "{out}");
    assert_eq!(out.lines().count(), SCRIPT.lines().count() + 1);
}

#[test]
fn and_cannot_start_earlier_than_the_thing_it_follows() {
    let err = move_tween_start(SCRIPT, "circle2", 0, -0.1, Some(&nodes())).unwrap_err();
    assert!(err.to_string().contains("nothing written before it"), "{err}");
}

#[test]
fn the_second_movement_of_a_thing_is_a_different_movement() {
    // The bar moves twice. Moving the second one changes the wait before *it*.
    let out = move_tween_start(SCRIPT, "rect1", 1, 0.3, Some(&nodes())).unwrap();
    assert!(out.contains("t:wait(0.15)"), "the first wait is untouched:\n{out}");
    assert!(out.contains("t:wait(0.5)"), "{out}");

    // And asking for one that is not there says how many there are.
    let err = move_tween_start(SCRIPT, "rect1", 7, 0.3, Some(&nodes())).unwrap_err();
    assert!(err.to_string().contains("there is no #7"), "{err}");
}

#[test]
fn moving_it_nowhere_is_the_same_file() {
    assert_eq!(move_tween_start(SCRIPT, "rect1", 0, 0.0, Some(&nodes())).unwrap(), SCRIPT);
    assert_eq!(lower(SCRIPT, &[], None).unwrap(), SCRIPT);
}
