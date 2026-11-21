use super::*;
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use libghostty_vt::{terminal::ScrollViewport};

fn terminal() -> Terminal<'static, 'static> {
    let mut vt = crate::new_vt(10, 5, 20).unwrap();
    crate::images::configure(&mut vt).unwrap();
    vt.resize(10, 5, 10, 20).unwrap();
    vt
}
fn upload(vt: &mut Terminal<'_, '_>, id: u32, pid: u32, cols: u32, rows: u32) {
    let data = B64.encode([255, 0, 0, 255].repeat(4));
    vt.vt_write(
        format!("\x1b_Ga=T,f=32,s=2,v=2,i={id},p={pid},U=1,c={cols},r={rows},q=2;{data}\x1b\\")
            .as_bytes(),
    );
}
fn cell(row: usize, col: usize, high: usize) -> String {
    format!(
        "{PLACEHOLDER}{}{}{}",
        DIACRITICS[row], DIACRITICS[col], DIACRITICS[high]
    )
}
fn view(vt: &Terminal<'_, '_>) -> Vec<Placement> {
    placements(vt, (10., 20.)).unwrap()
}

#[test]
fn replicated_placement_geometry_matches_owner_without_pixel_replay() {
    let mut source = terminal();
    let mut publisher = crate::scene::Publisher::default();
    let originals = crate::images::State::default();
    let payload = B64.encode([255, 0, 0, 255].repeat(8));
    for command in [
        format!("\x1b[2;3H\x1b_Ga=T,f=32,s=4,v=2,i=9,p=4,c=3,r=2,C=1,q=2;{payload}\x1b\\"),
        "\x1b_Ga=p,i=9,p=5,c=3,C=1,q=2;\x1b\\".into(),
        "\x1b[5;1H\r\n\r\n".into(),
    ] {
        source.vt_write(command.as_bytes());
        let graphics = publisher.capture(&source, &originals).unwrap();
        let text = crate::checkpoint::capture_frontend(&mut source).unwrap();
        let mut replica = terminal();
        replica.vt_write(&text);
        for offset in [0, 1, 2] {
            source.scroll_viewport(ScrollViewport::Row(offset));
            replica.scroll_viewport(ScrollViewport::Row(offset));
            let expected = placements(&source, (10., 20.)).unwrap();
            let actual = scene_placements(&replica, &graphics, (10., 20.)).unwrap();
            assert_eq!(actual.len(), expected.len());
            for (a, b) in actual.iter().zip(&expected) {
                assert_eq!(a.dest, b.dest);
                assert_eq!(a.source, b.source);
            }
        }
    }
}

#[test]
fn placeholders_follow_cells_erase_and_screen_switches() {
    let mut vt = terminal();
    upload(&mut vt, 42, 7, 4, 2);
    assert!(
        view(&vt).is_empty(),
        "virtual uploads do not paint without cells"
    );
    vt.vt_write(
        format!(
            "\x1b[38;2;0;0;42m\x1b[58;2;0;0;7m{}{}{}{}\r\n{}{}{}{}\x1b[0m",
            cell(0, 0, 0),
            PLACEHOLDER,
            PLACEHOLDER,
            PLACEHOLDER,
            cell(1, 0, 0),
            PLACEHOLDER,
            PLACEHOLDER,
            PLACEHOLDER
        )
        .as_bytes(),
    );
    let quads = view(&vt);
    assert_eq!(quads.len(), 2);
    assert_eq!(quads[0].dest, [0., 0., 40., 20.]);
    assert_eq!(quads[1].source, [0., 1., 2., 1.]);
    vt.vt_write(b"\x1b[1;2H\x1b[X");
    let quads = view(&vt);
    assert_eq!(quads.len(), 3, "erasing a cell splits the first strip");
    assert_eq!(quads[0].dest[2], 10.);
    vt.vt_write(b"\x1b[?1049h");
    assert!(view(&vt).is_empty());
    vt.vt_write(b"\x1b[?1049l");
    assert_eq!(view(&vt).len(), 3);
    vt.vt_write(b"\x1b[1;1H\x1b[2K\x1b[2;1H\x1b[2K");
    assert!(
        view(&vt).is_empty(),
        "fzf clears placeholders by erasing text"
    );
}

#[test]
fn high_ids_palette_ids_and_letterboxing() {
    let mut vt = terminal();
    upload(&mut vt, 0xab000005, 9, 4, 1);
    vt.vt_write(
        format!(
            "\x1b[38;5;5m\x1b[58;5;9m{}{}{}{}",
            cell(0, 0, 0xab),
            PLACEHOLDER,
            PLACEHOLDER,
            PLACEHOLDER
        )
        .as_bytes(),
    );
    let q = view(&vt);
    assert_eq!(q.len(), 1);
    assert_eq!(q[0].image_id, 0xab000005);
    assert_eq!(q[0].dest, [10., 0., 20., 20.]);
    assert_eq!(q[0].source, [0., 0., 2., 2.]);
    vt.vt_write(b"\x1b_Ga=d,d=I,i=2868903941,q=2;\x1b\\");
    assert!(
        view(&vt).is_empty(),
        "deleted images leave no rendered placeholder glyphs"
    );
}

#[test]
fn placeholders_survive_replay_and_scroll() {
    let mut vt = terminal();
    upload(&mut vt, 42, 7, 2, 1);
    vt.vt_write(
        format!(
            "\x1b[38;2;0;0;42m\x1b[58;2;0;0;7m{}{}\x1b[0m\r\n\r\n\r\n\r\n\r\n",
            cell(0, 0, 0),
            PLACEHOLDER
        )
        .as_bytes(),
    );
    assert!(view(&vt).is_empty());
    vt.scroll_viewport(ScrollViewport::Top);
    let expected = view(&vt);
    assert_eq!(expected.len(), 1);
    let bytes = crate::images::State::default()
        .capture(&vt, crate::checkpoint::capture(&vt).unwrap())
        .unwrap();
    let mut client = terminal();
    client.vt_write(&bytes);
    client.scroll_viewport(ScrollViewport::Top);
    assert_eq!(view(&client)[0].dest, expected[0].dest);
}

#[test]
fn fzf_sixel_cleanup_preserves_kitty_and_other_rows() {
    let mut vt = terminal();
    let (png, w, h) = crate::inline_images::sixel(b"0;1q\"1;1;2;6#1;2;100;0;0!2~").unwrap();
    vt.vt_write(b"\x1b[2;4H");
    crate::inline_images::place(&mut vt, &png, w, h, (10, 20));
    vt.vt_write(b"\x1b[4;4H");
    crate::inline_images::place(&mut vt, &png, w, h, (10, 20));
    vt.vt_write(b"\x1b[2;1H\x1b_Ga=T,f=32,s=1,v=1,i=123,q=2,C=1;/wAA/w==\x1b\\");
    assert_eq!(view(&vt).len(), 3);
    vt.vt_write(b"\x1b[2;1H\x1b[2K");
    crate::inline_images::erase(&mut vt, b'K', 2);
    assert_eq!(view(&vt).len(), 2);
    assert!(view(&vt).iter().any(|p| p.image_id == 123));
    vt.vt_write(b"\x1b[4;1H\x1b[2K");
    crate::inline_images::erase(&mut vt, b'K', 2);
    assert_eq!(view(&vt).len(), 1);
}
