#!/usr/bin/env python3
"""Prepare the native-window interval as a short, independently renderable scene."""
import argparse
import copy
import json
from pathlib import Path
import re
import subprocess
from native_window import compose

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("take", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent
take = args.take.resolve()
metadata = json.loads((take / "capture.json").read_text())
if metadata["failures"]:
    raise SystemExit("Cannot prepare a failed replay")
native = metadata["native_window"]
frames = round(native["end_frame"] - native["start_frame"] + native.get("cursor_return_frames", 0))
duration = frames / 60
scene = root / "native-scene"
scene.mkdir(exist_ok=True)
if not (scene / "assets").exists():
    (scene / "assets").symlink_to("../assets", target_is_directory=True)
pin = re.search(r"hyperframes@([\d.]+)", (root / "package.json").read_text())[1]
(scene / "package.json").write_text(json.dumps({"name": "native-chromium-scene", "private": True,
    "scripts": {"check": f"bunx hyperframes@{pin} check",
                "render": "python3 ../../../shared/render.py --project ."}}, indent=2) + "\n")
(scene / "hyperframes.json").write_text('{"media":{"autoProxy":true}}\n')
# A short H.264 extract makes this scene quick to inspect and render. The
# complete original AV1 take remains the source of the surrounding film.
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-ss", str(native["start_frame"] / 60), "-i", str(take / "footage.mp4"),
                "-frames:v", str(frames), "-an", "-c:v", "libx264", "-crf", "15", "-preset", "fast",
                "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(scene / "assets/native-background.mp4")], check=True)
html, script = compose(scene, take, copy.deepcopy(metadata), lambda t: t - native["start_frame"] / 60)
parent = (root / "index.html").read_text()
head = re.search(r"<head>.*?</head>", parent, re.S)[0]
lights = re.search(r'<div[^>]*id="traffic-lights".*?</div>', parent, re.S)[0]
lights = re.sub(r'data-duration="[\d.]+"', f'data-duration="{duration:.6f}"', lights)
source = f'''<!doctype html>
<html lang="en">{head}<body>
  <div id="root" data-composition-id="main" data-width="1920" data-height="1080" data-duration="{duration:.6f}" data-fps="60">
    <div id="window">
      <video id="footage" class="clip footage" src="assets/native-background.mp4" muted playsinline data-start="0" data-duration="{duration:.6f}" data-track-index="0"></video>
      {lights}
    </div>
    {html}
  </div>
  <script>
    window.__timelines["main"] = gsap.timeline({{paused:true}});
    {script}
  </script>
</body></html>'''
(scene / "index.html").write_text(source)
print(scene)
