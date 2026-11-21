use graffitty_client_core::mirror::{Mirror, Update};
use serde_json::Value;

#[test]
fn every_adapter_mirror_replays_the_same_stream_at_any_packet_boundary() {
    let fixtures: Vec<Value> = serde_json::from_str(include_str!("../fixtures/terminal.json")).unwrap();
    for fixture in fixtures {
        let columns = fixture["columns"].as_u64().unwrap() as u16;
        let rows = fixture["rows"].as_u64().unwrap() as u16;
        let bytes = fixture["stream"].as_str().unwrap().as_bytes();
        let mut reference = None;
        for chunk_size in [1, 3, bytes.len()] {
            let mut mirror = Mirror::new(columns, rows, (12, 23), Default::default()).unwrap();
            let update = Update { columns, rows, reset: false, exited: false, limits: Default::default() };
            for chunk in bytes.chunks(chunk_size) { mirror.apply(&update, chunk).unwrap(); }
            assert!(mirror.text(true).unwrap().contains(fixture["contains"].as_str().unwrap()), "{}", fixture["name"]);
            let frame = serde_json::to_value(mirror.frame(18).unwrap().0).unwrap();
            if let Some(expected) = &reference { assert_eq!(&frame, expected, "{} packet size {chunk_size}", fixture["name"]); }
            else { reference = Some(frame); }
            let checkpoint = graffitty_terminal_core::checkpoint::capture(&mirror.vt).unwrap();
            let retained = mirror.text(true).unwrap();
            let mut reconnected = Mirror::new(80, 24, (12, 23), Default::default()).unwrap();
            reconnected.apply(&Update { reset: true, ..update }, &checkpoint).unwrap();
            assert_eq!(reconnected.text(true).unwrap(), retained, "{} checkpoint", fixture["name"]);
        }
    }
}
