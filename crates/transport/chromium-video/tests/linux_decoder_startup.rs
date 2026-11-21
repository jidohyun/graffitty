#![cfg(target_os = "linux")]

/// A fresh frontend asks for decoders before it ever tries an encoder. Keep
/// this in its own test executable so another probe cannot initialize libva.
#[test]
fn decoder_discovery_can_be_the_first_video_call() {
    let _ = graffitty_chromium_video::decoders();
}
