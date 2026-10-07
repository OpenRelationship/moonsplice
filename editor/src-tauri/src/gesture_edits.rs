use super::*;

pub fn gesture_to_edits(
    g: Gesture,
    outline: &serde_json::Value,
) -> Result<Vec<Edit>, EditRefusal> {
    Ok(match g {
        Gesture::Move { node, x, y } => {
            // Dragging sets where a thing *starts*. If a movement already decides that at the
            // moment on screen, the drag would appear to do nothing — so it is refused with the
            // reason, rather than written and silently overridden at evaluation.
            for key in ["x", "y"] {
                if moving_anywhere(outline, &node, key) {
                    let who = words::name_of(&words::names(outline), &node);
                    return Err(EditRefusal::Conflict {
                        detail: format!(
                            "{who}'s position is moved by the timeline, so dragging it would \
                             not stick — change the movement instead"
                        ),
                    });
                }
            }
            vec![
                Edit::SetProp {
                    node: node.clone(),
                    key: "x".into(),
                    value: serde_json::json!(round2(x)),
                },
                Edit::SetProp {
                    node,
                    key: "y".into(),
                    value: serde_json::json!(round2(y)),
                },
            ]
        }
        Gesture::SetValue { node, key, value } => vec![Edit::SetProp { node, key, value }],
        Gesture::Curve {
            node,
            ease,
            occurrence,
        } => vec![Edit::SetEase {
            node,
            ease,
            occurrence,
        }],
        Gesture::Lengthen {
            node,
            seconds,
            occurrence,
        } => vec![Edit::SetTweenDuration {
            node,
            seconds: round2(seconds),
            occurrence,
        }],
        Gesture::Line {
            node,
            index,
            t0,
            t1,
            text,
        } => vec![Edit::SetCue {
            node,
            index,
            t0: t0.map(round2),
            t1: t1.map(round2),
            text,
        }],
        Gesture::Pin { node, t, key, value } => {
            let covered = moving_at(outline, &node, &key, t);
            vec![Edit::PinProp {
                node,
                t: round2(t),
                key,
                value,
                covered,
            }]
        }
        Gesture::Remove { node } => vec![Edit::Remove { node }],
        // Dragging a clip along the timeline. The composition's length is fixed, so a clip
        // dragged past the end stops at the end rather than lengthening the composition, and a
        // clip dragged before zero stops at zero -- the same two walls an editor puts up.
        Gesture::Slide { node, t } => {
            let Some(span) = span_of(outline, &node) else {
                return Err(not_a_clip(outline, &node));
            };
            let last = (comp_duration(outline) - span.duration).max(0.0);
            let start = t.clamp(0.0, last);
            vec![Edit::SetProp {
                node,
                key: span.start_key.into(),
                value: serde_json::json!(round2(start)),
            }]
        }
        // Trimming. The front of a clip moves two things at once: when it begins, and how far
        // into its own footage it begins -- otherwise trimming the head off a shot would play
        // the same frames later rather than starting later in the shot. The back moves one.
        Gesture::Trim { node, edge, t } => {
            let Some(span) = span_of(outline, &node) else {
                return Err(not_a_clip(outline, &node));
            };
            let frame = one_frame(outline);
            let end = span.start + span.duration;
            match edge {
                Edge::In => {
                    // Not past its own first frame, and never past its own tail.
                    let earliest = span.start - span.media_start;
                    let start = t.clamp(earliest.max(0.0), end - frame);
                    let moved = start - span.start;
                    vec![
                        Edit::SetProp {
                            node: node.clone(),
                            key: span.start_key.into(),
                            value: serde_json::json!(round2(start)),
                        },
                        Edit::SetProp {
                            node: node.clone(),
                            key: "media_start".into(),
                            value: serde_json::json!(round2((span.media_start + moved).max(0.0))),
                        },
                        Edit::SetProp {
                            node,
                            key: "duration".into(),
                            value: serde_json::json!(round2(span.duration - moved)),
                        },
                    ]
                }
                Edge::Out => {
                    let stop = t.clamp(span.start + frame, comp_duration(outline));
                    vec![Edit::SetProp {
                        node,
                        key: "duration".into(),
                        value: serde_json::json!(round2(stop - span.start)),
                    }]
                }
            }
        }
        // The razor. A clip that is cut where nothing of it is -- before it starts, after it
        // ends -- is refused with where it actually runs, because a cut that quietly did nothing
        // is the worst answer of the three.
        Gesture::Split { node, t } => {
            if span_of(outline, &node).is_none() {
                return Err(not_a_clip(outline, &node));
            }
            vec![Edit::Split {
                node,
                at: round2(t),
            }]
        }
        // When a movement begins is not a number written next to it -- it is everything before
        // it in the script added up. So the drag is a difference, and the lowering changes the
        // one thing immediately before it that holds time. What follows moves with it, because
        // that is what a script means; making a movement longer has always worked this way.
        Gesture::MoveStart {
            node,
            t,
            occurrence,
        } => {
            let Some(was) = tween_start(outline, &node, occurrence) else {
                let who = words::name_of(&words::names(outline), &node);
                return Err(EditRefusal::Conflict {
                    detail: format!("{who} has no movement there to take hold of"),
                });
            };
            vec![Edit::MoveTweenStart {
                node,
                occurrence,
                delta: round2(t.max(0.0) - was),
            }]
        }
        // What paints over what is the order the statements are written in, so reordering the
        // lanes is moving a statement. Sound has no stack -- a mix is not a picture -- so a
        // sound dragged among the lanes is refused rather than written somewhere meaningless.
        Gesture::Restack { node, over } => {
            if over.as_deref() == Some(node.as_str()) {
                return Err(EditRefusal::Conflict {
                    detail: format!(
                        "{} is already where it is; a thing cannot be put in front of itself",
                        words::name_of(&words::names(outline), &node)
                    ),
                });
            }
            for who in [Some(&node), over.as_ref()].into_iter().flatten() {
                if is_sound(outline, who) {
                    return Err(EditRefusal::Conflict {
                        detail: format!(
                            "{} is sound, and sound has no front or back -- what is louder is \
                             its loudness",
                            words::name_of(&words::names(outline), who)
                        ),
                    });
                }
            }
            vec![Edit::Restack { node, over }]
        }
        // Take it out and close the hole. Two things in one breath, and one undo: the thing
        // goes, and everything of its own kind that came after it moves up by its length.
        //
        // The order is load-bearing. Every `set_value` is written against the text as it stands
        // now, so the removal goes last -- a statement taken out first would shift every line
        // after it and the moves would be aimed at the wrong ones.
        Gesture::TakeOutAndClose { node } => {
            let Some(span) = span_of(outline, &node) else {
                return Err(not_a_clip(outline, &node));
            };
            if span.duration <= 0.0 {
                return Err(EditRefusal::Conflict {
                    detail: format!(
                        "{} has no length, so there is no hole to close",
                        words::name_of(&words::names(outline), &node)
                    ),
                });
            }
            let sound = is_sound(outline, &node);
            let mut edits = ripple(
                outline,
                span.start + span.duration - 1e-6,
                -span.duration,
                sound,
                &node,
            )?;
            edits.push(Edit::Remove { node });
            edits
        }
        // The gap itself, closed. A hole in a lane is a thing a person can see and point at, so
        // it is a thing they can click -- and what it does is exactly what taking the clip out
        // would have done, minus the taking out.
        Gesture::CloseGap { after } => {
            let Some(span) = span_of(outline, &after) else {
                return Err(not_a_clip(outline, &after));
            };
            let sound = is_sound(outline, &after);
            let ends = span.start + span.duration;
            let frame = one_frame(outline);
            let next = placed(outline)
                .into_iter()
                .find(|(id, sp)| {
                    id != &after && is_sound(outline, id) == sound && sp.start > ends + 1e-6
                })
                .map(|(_, sp)| sp.start);
            let Some(next) = next else {
                return Err(EditRefusal::Conflict {
                    detail: format!(
                        "there is nothing after {}, so there is no gap to close",
                        words::name_of(&words::names(outline), &after)
                    ),
                });
            };
            let gap = next - ends;
            if gap < frame {
                return Err(EditRefusal::Conflict {
                    detail: "there is no gap there worth closing".into(),
                });
            }
            ripple(outline, next - 1e-6, -gap, sound, "")?
        }
        // A note, pinned where you were looking. It is `place` and nothing else -- a marker is a
        // node, so putting one in, moving it, renaming it and taking it out are the four verbs
        // the app already had, and none of them had to learn a thing.
        Gesture::Mark { t, text } => {
            let said = text.trim();
            if said.is_empty() {
                return Err(EditRefusal::Conflict {
                    detail: "a note with nothing written on it is not a note".into(),
                });
            }
            vec![Edit::Place {
                kind: "marker".into(),
                fields: vec![
                    ("at".into(), lower::fmt_num(round2(t.max(0.0)))),
                    (
                        "text".into(),
                        format!("\"{}\"", lower::escape_lua(said)),
                    ),
                ],
                what: said.to_string(),
            }]
        }
    })
}

pub(super) fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// Everything in the composition that has a length, in the order it starts.
///
/// "Everything" is narrower than it sounds: a rectangle is on screen whenever the composition
/// says so and has no start of its own, so it is not here and a ripple never touches it.
pub(super) fn placed(outline: &serde_json::Value) -> Vec<(String, Span)> {
    let mut out: Vec<(String, Span)> = outline["nodes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|n| {
                    let id = n["id"].as_str()?.to_string();
                    let span = span_of(outline, &id)?;
                    Some((id, span))
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| a.1.start.partial_cmp(&b.1.start).unwrap_or(Ordering::Equal));
    out
}

/// Is anything on the timeline deciding this thing's properties over time -- a movement or a
/// value pinned at a moment?
///
/// It is the question a ripple has to ask before it moves anything. A movement is written against
/// the composition's clock, not against the clip; moving the clip and leaving the movement where
/// it is would take a fade off the shot it belongs to, quietly, which is the one thing a ripple
/// must never do.
pub(super) fn timed(outline: &serde_json::Value, node: &str) -> bool {
    outline["tracks"]
        .as_array()
        .map(|tracks| {
            tracks.iter().any(|tr| {
                tr["node"].as_str() == Some(node)
                    && tr["segments"]
                        .as_array()
                        .map(|segs| !segs.is_empty())
                        .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}
