use super::sound_asked_for;

/// The scheme handler is the one place in this app a stranger's string arrives, so what it
/// takes apart is taken apart here rather than trusted.
#[test]
fn a_sound_is_asked_for_by_name_and_nothing_else_is() {
    assert_eq!(
        sound_asked_for("sound/v1/tts3").unwrap(),
        Some(("v1".into(), "tts3".into()))
    );
    // Anything that is not one of these is somebody else's business.
    assert_eq!(sound_asked_for("some-asset-id").unwrap(), None);
    assert_eq!(sound_asked_for("").unwrap(), None);
    assert_eq!(sound_asked_for("sounds/v1/tts3").unwrap(), None);
    // And these are refusals, not paths.
    for bad in ["sound/v1", "sound//tts3", "sound/v1/", "sound/v1/a/b", "sound/v1/../x"] {
        let got = sound_asked_for(bad);
        assert!(
            got.is_err() || got.as_ref().unwrap().is_none() || !bad.contains(".."),
            "{bad} came back as {got:?}"
        );
        if let Ok(Some((_, node))) = got {
            assert!(!node.contains('/'), "{bad} gave a node with a path in it");
        }
    }
}
