#!/usr/bin/env python3
"""Append a successful Android take after prepare.py's desktop timeline.

Render android-overlay first: its finished chapter includes system bars, Slack
notification, and captions. Raw phone composites are deliberately not accepted.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--video", type=Path, default=Path(__file__).resolve().parents[2] / "artifacts/android-demo/android-oneui.mp4")
parser.add_argument("--manager", type=Path, help="Rendered manager opening; replaces the old one-second phone opening")
args = parser.parse_args()
root = Path(__file__).resolve().parent
overlay = root.parent / "android-overlay"
overlay_meta = json.loads((overlay / "overlay.json").read_text())
repo = root.parents[2]
take = repo / overlay_meta["source"]
capture = json.loads((take / "capture.json").read_text())
assert overlay_meta['screen_source_start'] == 0, 'Keep the opening split-button click continuous'
assert 'Three-node overview is centered before double-tap navigation' in capture['checks']
assert 'Pointer clicks right-split to create one pane' in capture['checks']
assert 'Mobile tab strip reserves no desktop window-button space' in capture['checks']
if capture.get("failures"):
    raise SystemExit("Cannot append a failed take")
assert any(check.endswith('/send wire is dashed') for check in capture['checks']), 'Record Android with the dashed agent Send wire'
assert any(check.endswith('/turn_completed wire is solid') for check in capture['checks']), 'Record Android with the solid automatic completion wire'
pane_focuses = sum(check.startswith('Title-bar double tap focuses pane:') for check in capture['checks'])
overview_returns = capture['checks'].count('Title-bar double tap restores overview')
assert pane_focuses > 0 and overview_returns > 0, 'Use title-bar double taps for pane close-ups and overview returns'
probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0",
    "-show_entries", "stream=width,height,r_frame_rate,duration",
    "-of", "json", str(args.video),
]))["streams"][0]
if (probe["width"], probe["height"], probe["r_frame_rate"]) != (1920, 1080, "60/1"):
    raise SystemExit("Expected the 1080p/60fps phone composite")
desktop = json.loads((root / "capture.json").read_text())["timeline_duration"]
base_duration = float(probe["duration"])
duration = base_duration
if abs(duration - overlay_meta["duration"]) > 1 / 60:
    raise SystemExit("Render the current Android overlay before appending it")
manager = None
added = 0.0
if args.manager:
    manager = json.loads((overlay / 'manager-scene/capture.json').read_text())
    count = int(json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-count_packets', '-show_entries', 'stream=nb_read_packets', '-of', 'json', str(args.manager)]))['streams'][0]['nb_read_packets'])
    assert count == manager['frames']
    shutil.copyfile(args.manager, root / manager['source'])
    added = manager['duration'] - 1.0
    duration += added
overlay_html = (overlay / "index.html").read_text()
wiring = float(re.search(r'id="caption-nodes"[^>]*data-start="([\d.]+)"', overlay_html)[1])
wiring += added
chapters = [
    (0, wiring, "Connect to your PC from another computer—or your phone."),
    (wiring, duration - wiring,
     "Node-based agent orchestration: connect how agent should interact"),
]
shutil.copyfile(args.video, root / "assets/android-oneui.mp4")
source = (root / "index.html").read_text()
source = re.sub(r"\s*<!-- android-chapter:start -->.*?<!-- android-chapter:end -->", "", source, flags=re.S)
source = re.sub(r"\s*// android-stage:start.*?// android-stage:end", "", source, flags=re.S)
source = re.sub(r'(data-composition-id="main"[^>]*data-duration=")[\d.]+',
                lambda m: m[1] + f"{desktop + duration:.6f}", source, count=1)
lines = [
    '    <!-- android-chapter:start -->',
    '    <div style="position:absolute;left:0;top:56px;width:1920px;height:900px;overflow:hidden">',
    f'    <video id="android-phone" class="clip" src="assets/android-oneui.mp4" muted playsinline data-layout-allow-overflow '
    f'data-start="{desktop + (manager["duration"] if manager else 0):.6f}" data-duration="{base_duration - (1 if manager else 0):.6f}" data-media-start="{1 if manager else 0}" data-track-index="0" '
    'style="position:absolute;left:0;top:0;width:1920px;height:1080px;object-fit:contain"></video>',
]
if manager:
    lines.append(f'    <video id="android-manager" class="clip" src="{manager["source"]}" muted playsinline data-layout-allow-overflow '
                 f'data-start="{desktop:.6f}" data-duration="{manager["duration"]:.6f}" data-track-index="0" '
                 'style="position:absolute;left:0;top:0;width:1920px;height:1080px;object-fit:contain"></video>')
lines.append('    </div>')
lines.append('    <!-- android-chapter:end -->')
source = source.replace('    <!-- subtitles:end -->', '    <!-- subtitles:end -->\n' + '\n'.join(lines))
# The window is an untimed layout wrapper; its media retain individual timings.
source = source.replace('gsap.timeline({ paused: true });',
    'gsap.timeline({ paused: true });\n'
    '    // android-stage:start\n'
    f'    window.__timelines["main"].set("#window", {{ opacity: 0 }}, {desktop:.6f});\n'
    '    // android-stage:end')
(root / "index.html").write_text(source)
(root / "android-capture.json").write_text(json.dumps({
    "take": overlay_meta["source"], "overlay": "videos/main-demo/android-overlay/index.html", "start": desktop, "duration": duration,
    "chapters": [{"start": desktop + s, "duration": d, "text": t} for s, d, t in chapters],
    "checks": capture["checks"],
    "wire_styles": {"turn_completed": "solid", "send": "dashed"},
    "navigation": {"input": "title_double_tap", "pane_focuses": pane_focuses, "overview_returns": overview_returns},
    "manager": manager, "base_duration": base_duration,
    "screen_source_start": overlay_meta["screen_source_start"],
}, indent=2) + "\n")
print(f"Desktop {desktop:.2f}s + Android {duration:.2f}s = {desktop + duration:.2f}s")
from narration import place_chapter
place_chapter(root, "android")
