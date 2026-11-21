use graffitty_client_config::{bindings::{Action, Platform}, config::{Dirs, parse, resolve_documents}};
use std::path::Path;

#[test]
fn attention_sounds_are_typed_client_settings_and_merge_per_field() {
    let parse_doc = |text| parse(text, Path::new("/config/client.toml"), &Dirs::home("/home/test")).unwrap();
    let resolved = resolve_documents(vec![
        parse_doc("[sounds]\nenabled = true\nblocked = '~/sounds/request.ogg'\ndone = 'done.mp3'"),
        parse_doc("[sounds]\nenabled = false"),
    ], Platform::Linux).unwrap();
    let sounds = resolved.settings.sounds.unwrap();
    assert_eq!(sounds.enabled, Some(false));
    assert_eq!(sounds.blocked.as_deref(), Some("/home/test/sounds/request.ogg"));
    assert_eq!(sounds.done.as_deref(), Some("done.mp3"));
    assert!(Action::from_name("Agents").is_some());
}

#[test]
fn invalid_sound_settings_are_rejected() {
    for text in ["[sounds]\nenabled = 'yes'", "[sounds]\nblocked = 12", "[sounds]\nlegacy = true"] {
        assert!(parse(text, Path::new("client.toml"), &Dirs::default()).is_err());
    }
}
