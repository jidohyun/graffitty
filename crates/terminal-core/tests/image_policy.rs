//! Exercise the public policy API with a real VT, including a reset boundary.
use base64::{Engine as _, engine::general_purpose::STANDARD};
use graffitty_terminal_core::{
    TerminalLimits,
    images::Policy,
    protocol::{Event, Observer},
};
use libghostty_vt::{Terminal};

fn terminal(policy: Policy) -> Terminal<'static, 'static> {
    let mut vt = graffitty_terminal_core::new_vt(20, 5, policy.limits.scrollback_bytes as usize).unwrap();
    policy.configure(&mut vt).unwrap();
    vt
}

fn feed(vt: &mut Terminal<'_, '_>, policy: Policy, observer: &mut Observer, bytes: &[u8]) {
    let mut offset = 0;
    for (end, event) in observer.feed(bytes) {
        vt.vt_write(&bytes[offset..end]);
        offset = end;
        if matches!(event, Event::Reset) {
            policy.apply(vt).unwrap();
        }
    }
    vt.vt_write(&bytes[offset..]);
}

#[test]
fn mirror_rejects_owner_files_before_and_after_fragmented_reset() {
    let path =
        std::env::temp_dir().join(format!("terminal-core-policy-{}.png", uuid::Uuid::new_v4()));
    let png = STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==").unwrap();
    std::fs::write(&path, &png).unwrap();
    let owner = Policy::owner(TerminalLimits::default(), (12, 23));
    let mirror = Policy::mirror(TerminalLimits::default(), (10, 22));
    assert!(owner.allows_external_uploads());
    assert!(!mirror.allows_external_uploads());
    let mut source = terminal(owner);
    let mut client = terminal(mirror);
    let mut source_observer = Observer::default();
    let mut client_observer = Observer::default();
    let upload = format!(
        "\x1b_Ga=T,t=f,f=100,i=91,p=1,c=2,r=2,q=2;{}\x1b\\",
        STANDARD.encode(path.to_string_lossy().as_bytes())
    );
    for prefix in ["", "\x1bc"] {
        let bytes = format!("{prefix}{upload}");
        for byte in bytes.as_bytes() {
            feed(&mut source, owner, &mut source_observer, &[*byte]);
            feed(&mut client, mirror, &mut client_observer, &[*byte]);
        }
        assert!(source.kitty_graphics().unwrap().unwrap().image(91).is_some());
        assert!(client.kitty_graphics().unwrap().is_none_or(|graphics| graphics.image(91).is_none()));
    }
    std::fs::remove_file(path).unwrap();

    // The same mirror can receive inline pixels resolved by the owner.
    let inline = format!(
        "\x1b_Ga=T,t=d,f=100,i=91,p=1,c=2,r=2,q=2;{}\x1b\\",
        STANDARD.encode(&png)
    );
    feed(&mut client, mirror, &mut client_observer, inline.as_bytes());
    assert_eq!(
        source
            .kitty_graphics()
            .unwrap()
            .unwrap()
            .image(91)
            .unwrap()
            .data()
            .unwrap(),
        client
            .kitty_graphics()
            .unwrap()
            .unwrap()
            .image(91)
            .unwrap()
            .data()
            .unwrap(),
    );
}

#[test]
fn configuration_rejects_zero_cell_geometry() {
    let mut vt = graffitty_terminal_core::new_vt(20, 5, 0).unwrap();
    for cell in [(0, 22), (10, 0)] {
        assert!(
            Policy::mirror(TerminalLimits::default(), cell)
                .configure(&mut vt)
                .is_err()
        );
    }
}
