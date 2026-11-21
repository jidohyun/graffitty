"""Shared AV1 policy and validation for the effects and replay galleries."""

import json
import os
import shutil
import subprocess


def encoder_args():
    return [
        "-c:v",
        "libsvtav1",
        "-preset",
        os.environ.get("GRAFFITTY_AV1_PRESET", "8"),
        "-crf",
        os.environ.get("GRAFFITTY_AV1_CRF", "24"),
        "-svtav1-params",
        "lp=4",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
    ]


def check_encoder():
    ffmpeg = os.environ.get("GRAFFITTY_FFMPEG") or shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("FFmpeg is required for AV1 recording")
    result = subprocess.run(
        [ffmpeg, "-hide_banner", "-encoders"],
        capture_output=True,
        text=True,
        check=True,
    )
    if "libsvtav1" not in result.stdout:
        raise RuntimeError("FFmpeg must include the libsvtav1 encoder")
    return ffmpeg


def probe_av1(path):
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-count_frames",
            "-show_streams",
            "-show_format",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    probe = json.loads(result.stdout)
    stream = next(s for s in probe["streams"] if s["codec_type"] == "video")
    if stream["codec_name"] != "av1" or int(stream.get("nb_read_frames", 0)) < 1:
        raise RuntimeError(f"Expected a nonempty AV1 video: {path}")
    return probe, stream
