use super::*;
use graffitty_terminal_core::{
    images::Policy,
    vt::{Terminal},
};
use image::{Rgba, RgbaImage};
use std::ffi::OsStr;

fn options(args: &[&str]) -> Options {
    let mut argv = vec![OsStr::new("terminal"), OsStr::new("icat")];
    argv.extend(args.iter().map(OsStr::new));
    match crate::options::App::parse_from(&argv).unwrap().command.into_workspace() {
        crate::options::WorkspaceCommand::Icat(options) => options,
        _ => unreachable!(),
    }
}

const SIZE: WindowSize = WindowSize {
    columns: 80,
    rows: 24,
    width: 800,
    height: 480,
};

fn fixture(width: u32, height: u32) -> decode::Decoded {
    decode::Decoded {
        frames: vec![decode::Frame {
            pixels: RgbaImage::from_pixel(width, height, Rgba([200, 40, 80, 255])),
            delay: 100,
        }],
    }
}

fn render(image: &decode::Decoded, options: &Options, mode: &str) -> Vec<u8> {
    let mut output = Vec::new();
    protocol::display(
        &mut output,
        image,
        options,
        SIZE,
        options
            .place
            .as_deref()
            .map(Place::parse)
            .transpose()
            .unwrap(),
        z_index(&options.z_index).unwrap(),
        1234,
        mode,
        options.unicode_placeholder.0,
        options.passthrough == "tmux",
    )
    .unwrap();
    output
}

#[test]
fn kitty_flags_preserve_defaults_and_optional_yes_no() {
    let defaults = options(&[]);
    assert_eq!(defaults.align, "center");
    assert_eq!(defaults.fit, "width");
    assert_eq!(defaults.loops, -1);
    assert!(!defaults.scale_up.0);
    let opts = options(&[
        "--scale-up",
        "--clear=no",
        "--hold=yes",
        "-n",
        "--stdin",
        "no",
        "-z",
        "--1",
        "-l",
        "0",
        "--image-id",
        "-1",
        "input.png",
    ]);
    assert!(opts.scale_up.0 && opts.hold.0 && opts.no_trailing_newline.0);
    assert!(!opts.clear.0);
    assert_eq!(opts.images, ["input.png"]);
    assert_eq!(z_index(&opts.z_index).unwrap(), -1073741825);
    assert_eq!(image_id(&opts.image_id).unwrap(), u32::MAX);
}

#[test]
fn validates_rectangles_sizes_ids_and_z_order() {
    for invalid in ["0x2@0x0", "2x2@-1x0", "2x2", "2x2@0", "2x2@0x4294967295"] {
        assert!(Place::parse(invalid).is_err());
    }
    for invalid in [
        "80,24,0,480",
        "0,24,800,480",
        "80,24,79,480",
        "80,24,800,23",
        "80,24,800,480,1",
    ] {
        assert!(WindowSize::parse(invalid).is_err());
    }
    assert!(z_index("--2147483648").is_err());
    assert_eq!(image_id("4294967297").unwrap(), 1);
    assert_eq!(image_id("18446744073709551615").unwrap(), u32::MAX);
    for invalid in ["--1", "-+1", "+-1", "1x"] {
        assert!(image_id(invalid).is_err());
    }
}

#[test]
fn fit_modes_preserve_aspect_and_scale_up_is_opt_in() {
    for (fit, expected) in [
        ("width", (800, 1600)),
        ("height", (240, 480)),
        ("both", (240, 480)),
        ("none", (1000, 2000)),
    ] {
        assert_eq!(
            decode::scaled_size(1000, 2000, &options(&["--fit", fit]), SIZE, None),
            expected
        );
    }
    assert_eq!(
        decode::scaled_size(100, 50, &options(&[]), SIZE, None),
        (100, 50)
    );
    assert_eq!(
        decode::scaled_size(100, 50, &options(&["--scale-up"]), SIZE, None),
        (800, 400)
    );
    assert_eq!(
        decode::scaled_size(100, 50, &options(&["--scale-up", "--fit=none"]), SIZE, None),
        (100, 50)
    );
    assert_eq!(
        decode::scaled_size(
            100,
            50,
            &options(&["--scale-up"]),
            SIZE,
            Some(Place::parse("4x4@0x0").unwrap())
        ),
        (40, 20)
    );
}

#[test]
fn mirror_and_background_modify_pixels() {
    let mut image = fixture(2, 1);
    image.frames[0].pixels.put_pixel(0, 0, Rgba([255, 0, 0, 0]));
    image
        .transform(
            &options(&["--mirror=horizontal"]),
            SIZE,
            None,
            Some(decode::background("blue").unwrap()),
        )
        .unwrap();
    assert_eq!(image.frames[0].pixels.get_pixel(1, 0).0, [0, 0, 255, 255]);
    assert_eq!(image.frames[0].pixels.get_pixel(0, 0).0, [200, 40, 80, 255]);
    assert_eq!(
        decode::background("rgb:ffff/00/8080").unwrap(),
        [255, 0, 128, 255]
    );
}

#[test]
fn every_transfer_mode_loads_in_the_real_terminal() {
    let mut modes = vec!["stream", "file"];
    if cfg!(unix) {
        modes.push("memory");
    }
    for mode in modes {
        let image = fixture(13, 25);
        let output = render(&image, &options(&["--align=left"]), mode);
        let mut vt = graffitty_terminal_core::new_vt(80, 24, 0).unwrap();
        Policy::owner(Default::default(), (10, 20))
            .configure(&mut vt)
            .unwrap();
        // Exercise fragmented APC parsing as it happens across PTY reads.
        for chunk in output.chunks(17) {
            vt.vt_write(chunk);
        }
        let graphics = vt.kitty_graphics().unwrap().unwrap();
        let loaded = graphics
            .image(1234)
            .unwrap_or_else(|| panic!("{mode}: image not loaded"));
        assert_eq!(
            (loaded.width().unwrap(), loaded.height().unwrap()),
            (13, 25)
        );
        assert_eq!(loaded.data().unwrap(), Some(image.frames[0].pixels.as_raw().as_slice()));
        drop(graphics);
        let mut clear = Vec::new();
        protocol::command(&mut clear, "a=d,d=A,q=2", &[], false).unwrap();
        vt.vt_write(&clear);
        assert!(vt.kitty_graphics().unwrap().is_none_or(|graphics| graphics.image(1234).is_none()));
    }
}

#[test]
fn chunks_are_bounded_and_reassemble_without_corruption() {
    use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
    let bytes: Vec<_> = (0..10000).map(|i| (i % 251) as u8).collect();
    let mut output = Vec::new();
    protocol::command(&mut output, "a=T,f=100,q=2", &bytes, false).unwrap();
    let text = String::from_utf8(output).unwrap();
    let packets: Vec<_> = text.split("\x1b_G").skip(1).collect();
    assert_eq!(packets.len(), 4);
    let mut payload = String::new();
    for (index, packet) in packets.iter().enumerate() {
        let (keys, data) = packet.trim_end_matches("\x1b\\").split_once(';').unwrap();
        assert!(data.len() <= 4096);
        assert!(keys.ends_with(if index + 1 == packets.len() {
            "m=0"
        } else {
            "m=1"
        }));
        payload.push_str(data);
    }
    assert_eq!(B64.decode(payload).unwrap(), bytes);
}

#[test]
fn placement_preserves_cursor_and_no_newline_is_respected() {
    let image = fixture(13, 25);
    let output = String::from_utf8(render(
        &image,
        &options(&["--place=10x5@3x2", "--align=right"]),
        "stream",
    ))
    .unwrap();
    assert!(output.starts_with("\r\x1b[3;12H"));
    assert!(output.contains(",X=7,C=1,"));
    assert!(!output.ends_with('\n'));
    assert!(render(&image, &options(&[]), "stream").ends_with(b"\n"));
    assert!(!render(&image, &options(&["-n"]), "stream").ends_with(b"\n"));
}

#[test]
fn tmux_wraps_apcs_and_placeholders_remain_text() {
    let output = String::from_utf8(render(
        &fixture(13, 25),
        &options(&["--unicode-placeholder", "--passthrough=tmux"]),
        "stream",
    ))
    .unwrap();
    assert!(output.contains("\x1bPtmux;\x1b\x1b_G"));
    assert!(output.contains(",U=1,c=2,r=2,"));
    assert_eq!(output.matches('\u{10eeee}').count(), 4);
    assert!(output.contains("\x1b[39m"));
}

#[test]
fn emitted_placeholders_render_and_erase_in_graffitty() {
    let mut vt = graffitty_terminal_core::new_vt(80, 24, 100).unwrap();
    Policy::owner(Default::default(), (10, 20)).configure(&mut vt).unwrap();
    let output = render(&fixture(40, 40), &options(&[
        "--unicode-placeholder", "--place=4x2@0x0", "--align=left",
    ]), "stream");
    assert_eq!(output.iter().filter(|&&byte| byte == b'\n').count(), 1,
        "fzf needs newline-separated placeholder rows even with --place");
    vt.vt_write(&output);
    let images = graffitty_terminal_core::image_render::placements(&vt, (10., 20.)).unwrap();
    assert_eq!(images.len(), 2);
    assert_eq!(images[0].dest, [0., 0., 40., 20.]);
    assert_eq!(images[1].dest, [0., 20., 40., 20.]);
    vt.vt_write(b"\x1b[1;1H\x1b[2K\x1b[2;1H\x1b[2K");
    assert!(graffitty_terminal_core::image_render::placements(&vt, (10., 20.)).unwrap().is_empty());
}

#[test]
fn gif_frames_keep_delays_and_loop_zero_is_static() {
    let mut bytes = Vec::new();
    {
        let mut encoder = image::codecs::gif::GifEncoder::new(&mut bytes);
        for delay in [120, 230] {
            encoder
                .encode_frame(image::Frame::from_parts(
                    RgbaImage::from_pixel(2, 2, Rgba([255, 0, 0, 255])),
                    0,
                    0,
                    image::Delay::from_numer_denom_ms(delay, 1),
                ))
                .unwrap();
        }
    }
    let opts = options(&["--engine=builtin", "--loop=2"]);
    let decoded = decode::decode(&bytes, &opts).unwrap();
    assert_eq!(decoded.frames.len(), 2);
    let output = String::from_utf8(render(&decoded, &opts, "stream")).unwrap();
    assert!(output.contains("a=f,"));
    assert!(output.contains("z=120,v=3,s=2"));
    assert!(output.contains("z=230,X=1"));
    assert!(output.contains("a=a,q=2,i=1234,s=3"));
    assert_eq!(
        decode::decode(&bytes, &options(&["--loop=0"]))
            .unwrap()
            .frames
            .len(),
        1
    );
}
