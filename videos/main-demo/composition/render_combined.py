#!/usr/bin/env python3
"""Join the desktop, finished One UI chapter, and optional Parallel chapter."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "videos/shared"))
from video_artifacts import artifact_path, export_path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--desktop", type=Path, required=True)
p.add_argument("--output", type=Path, default=artifact_path("main-demo", "main-demo.mp4"))
p.add_argument("--append", type=Path, help="Finished 1080p/60fps parallel chapter")
a = p.parse_args()
a.output = export_path(a.output)
root = Path(__file__).resolve().parent
meta = json.loads((root / "android-capture.json").read_text())

def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,duration,has_b_frames",
        "-of", "json", str(path),
    ]))["streams"][0]

desktop = probe(a.desktop)
assert (desktop["width"], desktop["height"], desktop["r_frame_rate"]) == (1920, 1080, "60/1")
assert abs(float(desktop["duration"]) - meta["start"]) < 1 / 60, "Desktop export must match the current timeline"
appended_duration = 0.0
if a.append:
    appended = probe(a.append)
    assert (appended["width"], appended["height"], appended["r_frame_rate"]) == (1920, 1080, "60/1")
    assert appended["has_b_frames"] == desktop["has_b_frames"]
    appended_duration = float(appended["duration"])
a.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="tiling-composite-") as temp:
    temp = Path(temp)
    phone = temp / "phone.mp4"
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
        "-i", str(root / "assets/android-oneui.mp4"),
        "-map", "0:v:0", "-an",
        "-t", str(meta["duration"]), "-r", "60", "-c:v", "libx264",
        "-preset", "veryfast", "-crf", "16", "-profile:v", "high",
        "-level:v", "5.0", "-bf", str(desktop["has_b_frames"]),
        "-video_track_timescale", "15360",
        "-movflags", "+faststart", str(phone),
    ], check=True)
    # Symlink known inputs into a private directory so concat paths need no
    # shell or ffconcat escaping, even when the workspace path contains quotes.
    (temp / "desktop.mp4").symlink_to(a.desktop.resolve())
    clips = "file 'desktop.mp4'\nfile 'phone.mp4'\n"
    if a.append:
        (temp / "parallel.mp4").symlink_to(a.append.resolve())
        clips += "file 'parallel.mp4'\n"
    (temp / "clips.txt").write_text(clips)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
        "-f", "concat", "-safe", "0", "-i", str(temp / "clips.txt"),
        "-map", "0:v:0", "-c", "copy", "-movflags", "+faststart", str(a.output),
    ], check=True)
result = probe(a.output)
assert result["r_frame_rate"] == "60/1"
assert abs(float(result["duration"]) - meta["start"] - meta["duration"] - appended_duration) < 1 / 60
print(a.output.resolve())
