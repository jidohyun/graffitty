#!/usr/bin/env python3
"""Build a small, reproducible LGPL FFmpeg codec library for chromium streaming.
No FFmpeg executable, software encoder, GPL component or external codec library.
The resulting prefix is detected automatically by crates/transport/chromium-video/build.rs.
"""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "9.0.2"
PATCHES = ROOT / "crates/transport/chromium-video/patches"
# Applied in order; each marker shows its patch is already in the source.
VIDEOTOOLBOX_PATCHES = [
    # Keep low-delay VT output from lagging one frame on static chromium pages.
    (PATCHES / "videotoolbox-low-delay.patch", "((avctx->flags & AV_CODEC_FLAG_LOW_DELAY) && !vtctx->has_b_frames)"),
    # A new bit rate applies to the live session, without a keyframe.
    (PATCHES / "videotoolbox-live-bitrate.patch", "vtctx->applied_bit_rate = avctx->bit_rate"),
    # A frame rate control dropped completes instead of blocking low delay.
    (PATCHES / "videotoolbox-dropped-frames.patch", "Rate control dropped this frame."),
]
BUILD_STAMP = VERSION + "-macos11-v2-" + hashlib.sha256(
    b"".join(patch.read_bytes() for patch, _ in VIDEOTOOLBOX_PATCHES)).hexdigest()[:12]
SHA256 = "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"


def build(target=None):
    native = subprocess.check_output(["rustc", "-vV"], text=True)
    target = target or next(line.split(": ", 1)[1] for line in native.splitlines() if line.startswith("host:"))
    if "windows-msvc" in target:
        from build_chromium_video_windows import build as build_windows
        return build_windows(ROOT, target, VERSION, SHA256)
    if "-linux-gnu" in target:
        from build_chromium_video_linux import build as build_linux
        return build_linux(ROOT, target, VERSION, SHA256)
    cache = ROOT / ".cache/chromium-video"
    prefix = cache / target
    stamp = prefix / ".version"
    if stamp.exists() and stamp.read_text() == BUILD_STAMP:
        return prefix
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"ffmpeg-{VERSION}.tar.xz"
    if not archive.exists():
        with urllib.request.urlopen(f"https://ffmpeg.org/releases/{archive.name}") as source:
            archive.write_bytes(source.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("FFmpeg source checksum mismatch")
    source = cache / f"ffmpeg-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(cache, filter="data")
    encoder_source = source / "libavcodec/videotoolboxenc.c"
    for patch, marker in VIDEOTOOLBOX_PATCHES:
        if marker not in encoder_source.read_text():
            subprocess.run(["patch", "--batch", "--forward", "-p1", "-i", str(patch)], cwd=source, check=True)
        if marker not in encoder_source.read_text():
            raise SystemExit(f"FFmpeg patch {patch.name} did not apply")
    work = cache / f"build-{target}"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir()
    options = [
        f"--prefix={prefix}", "--disable-everything", "--disable-autodetect",
        "--disable-programs", "--disable-doc", "--disable-debug",
        "--disable-avformat", "--disable-avfilter", "--disable-avdevice",
        "--disable-swresample", "--enable-swscale", "--enable-static",
        "--disable-shared", "--enable-pic", "--enable-small",
        "--enable-decoder=h264,hevc,av1", "--enable-parser=h264,hevc,av1",
        "--enable-bsf=extract_extradata,h264_mp4toannexb,hevc_mp4toannexb",
        "--enable-pthreads",
    ]
    if "apple-darwin" in target:
        options += ["--extra-cflags=-mmacosx-version-min=11.0",
                    "--extra-objcflags=-mmacosx-version-min=11.0",
                    "--extra-ldflags=-mmacosx-version-min=11.0", "--enable-videotoolbox",
                    "--enable-encoder=h264_videotoolbox,hevc_videotoolbox",
                    "--enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,av1_videotoolbox"]
    else:
        raise SystemExit(f"No chromium video FFmpeg recipe for {target}.")
    subprocess.run([str(source / "configure"), *options], cwd=work, check=True)
    subprocess.run(["make", f"-j{min(os.cpu_count() or 4, 12)}"], cwd=work, check=True)
    subprocess.run(["make", "install"], cwd=work, check=True)
    shutil.copy2(source / "COPYING.LGPLv2.1", prefix / "COPYING.LGPLv2.1")
    stamp.write_text(BUILD_STAMP)
    return prefix


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target")
    print(build(parser.parse_args().target))
