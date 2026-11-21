//! Compatibility policy around libghostty's key encoder.
use libghostty_vt::{Terminal, error::Result, key};

pub fn encode(
    term: &Terminal<'_, '_>,
    encoder: &mut key::Encoder<'_>,
    event: &key::Event<'_>,
    output: &mut Vec<u8>,
) -> Result<()> {
    encoder.set_options_from_terminal(term);
    // Frontends resolve native text/IME first. An Alt modifier reaching the
    // terminal is a shortcut, including both Option keys on macOS. Syncing VT
    // modes resets this encoder option, so set it after every sync.
    encoder.set_macos_option_as_alt(key::OptionAsAlt::True);
    let start = output.len();
    match encoder.encode_to_vec(event, output) {
        // 0.2.2's growable-buffer helper can under-reserve when a reused
        // buffer already has some spare capacity (e.g. Alt+B then CSI-u).
        Err(libghostty_vt::Error::OutOfSpace { required }) => {
            output.reserve(required);
            encoder.encode_to_vec(event, output)?;
        }
        result => result?,
    }

    // Ghostty reports Shift+Enter distinctly even in legacy mode. Match kitty's
    // carriage return there, but retain extended encodings requested by apps.
    if event.key() == key::Key::Enter
        && &output[start..] == b"\x1b[27;2;13~"
        && term.kitty_keyboard_flags()?.is_empty()
    {
        // The VT API has no modifyOtherKeys getter. Encoding Shift+A against
        // these same options distinguishes mode 2 without parsing PTY output
        // ourselves or changing terminal state. Nothing from this probe is sent.
        let mut probe = key::Event::new()?;
        probe
            .set_action(key::Action::Press)
            .set_key(key::Key::A)
            .set_mods(key::Mods::SHIFT)
            .set_unshifted_codepoint('a')
            .set_utf8(Some("A"));
        let mut bytes = [0; 32];
        let len = encoder.encode(&probe, &mut bytes)?;
        if &bytes[..len] == b"A" {
            output.truncate(start);
            output.push(b'\r');
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal() -> Terminal<'static, 'static> {
        crate::new_vt(80, 24, 0).unwrap()
    }

    fn enter(term: &Terminal<'_, '_>, mods: key::Mods, action: key::Action) -> Vec<u8> {
        let mut encoder = key::Encoder::new().unwrap();
        let mut event = key::Event::new().unwrap();
        event
            .set_key(key::Key::Enter)
            .set_mods(mods)
            .set_action(action);
        let mut bytes = Vec::new();
        encode(term, &mut encoder, &event, &mut bytes).unwrap();
        bytes
    }

    #[test]
    fn legacy_shift_enter_matches_enter() {
        let term = terminal();
        assert!(term.kitty_keyboard_flags().unwrap().is_empty());
        for mods in [
            key::Mods::SHIFT,
            key::Mods::SHIFT | key::Mods::CAPS_LOCK,
            key::Mods::SHIFT | key::Mods::SHIFT_SIDE,
        ] {
            for action in [key::Action::Press, key::Action::Repeat] {
                assert_eq!(enter(&term, mods, action), b"\r");
            }
            assert!(enter(&term, mods, key::Action::Release).is_empty());
        }
        assert_eq!(enter(&term, key::Mods::empty(), key::Action::Press), b"\r");
        assert_eq!(
            enter(
                &term,
                key::Mods::CTRL | key::Mods::SHIFT,
                key::Action::Press
            ),
            b"\x1b[27;6;13~"
        );
    }

    #[test]
    fn kitty_opt_in_and_pop_restore_legacy() {
        let mut term = terminal();
        term.vt_write(b"\x1b[>11u");
        assert_eq!(
            enter(&term, key::Mods::SHIFT, key::Action::Press),
            b"\x1b[13;2u"
        );
        assert_eq!(
            enter(&term, key::Mods::SHIFT, key::Action::Release),
            b"\x1b[13;2:3u"
        );
        term.vt_write(b"\x1b[<u");
        assert_eq!(enter(&term, key::Mods::SHIFT, key::Action::Press), b"\r");
    }

    #[test]
    fn modify_other_keys_opt_in_and_reset() {
        let mut term = terminal();
        term.vt_write(b"\x1b[>4;2m");
        assert_eq!(
            enter(&term, key::Mods::SHIFT, key::Action::Press),
            b"\x1b[27;2;13~"
        );
        term.vt_write(b"\x1b[>4;0m");
        assert_eq!(enter(&term, key::Mods::SHIFT, key::Action::Press), b"\r");
    }

    #[test]
    fn alt_shortcuts_and_extended_modes() {
        let mut term = terminal();
        let mut encoder = key::Encoder::new().unwrap();
        let mut event = key::Event::new().unwrap();
        for (key, cp) in [(key::Key::B, 'b'), (key::Key::F, 'f'), (key::Key::E, 'e')] {
            for action in [
                key::Action::Press,
                key::Action::Repeat,
                key::Action::Release,
            ] {
                event
                    .set_key(key)
                    .set_unshifted_codepoint(cp)
                    .set_mods(key::Mods::ALT)
                    .set_action(action)
                    .set_utf8(Some(&cp.to_string()));
                let mut bytes = Vec::new();
                encode(&term, &mut encoder, &event, &mut bytes).unwrap();
                assert_eq!(
                    bytes,
                    if action == key::Action::Release {
                        vec![]
                    } else {
                        vec![27, cp as u8]
                    }
                );
            }
        }
        event
            .set_key(key::Key::B)
            .set_unshifted_codepoint('b')
            .set_action(key::Action::Press)
            .set_mods(key::Mods::ALT | key::Mods::SHIFT)
            .set_consumed_mods(key::Mods::SHIFT)
            .set_utf8(Some("B"));
        let mut bytes = Vec::new();
        encode(&term, &mut encoder, &event, &mut bytes).unwrap();
        assert_eq!(bytes, b"\x1bB");
        event
            .set_mods(key::Mods::ALT)
            .set_consumed_mods(key::Mods::empty())
            .set_utf8(Some("b"));
        for (mode, expected) in [
            (b"\x1b[>11u".as_slice(), b"\x1b[98;3u".as_slice()),
            (b"\x1b[<u\x1b[>4;2m", b"\x1b[27;3;98~"),
            (b"\x1b[>4;0m", b"\x1bb"),
        ] {
            term.vt_write(mode);
            bytes.clear();
            encode(&term, &mut encoder, &event, &mut bytes).unwrap();
            assert_eq!(bytes, expected);
        }
        event
            .set_key(key::Key::B)
            .set_unshifted_codepoint('b')
            .set_mods(key::Mods::CTRL | key::Mods::ALT)
            .set_utf8(None::<String>);
        bytes.clear();
        encode(&term, &mut encoder, &event, &mut bytes).unwrap();
        assert_eq!(bytes, b"\x1b\x02");
        event
            .set_key(key::Key::ArrowLeft)
            .set_unshifted_codepoint('\0')
            .set_mods(key::Mods::ALT);
        bytes.clear();
        encode(&term, &mut encoder, &event, &mut bytes).unwrap();
        assert_eq!(bytes, b"\x1b[1;3D");
    }
}
