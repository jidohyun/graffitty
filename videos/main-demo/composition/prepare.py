#!/usr/bin/env python3
"""Freeze a successful Movie Maker take into the HyperFrames composition."""
import argparse
import html
import json
from pathlib import Path
import re
import shutil
import subprocess
from edit_decisions import timeline_cuts, require_original_speed
from native_window import compose as compose_native_window
from narration import compose as compose_narration

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("take", type=Path, help="Directory produced by videos/main-demo/recording/tiling/record.py")
args = parser.parse_args()
root = Path(__file__).resolve().parent
take = args.take.resolve()
capture = json.loads((take / "capture.json").read_text())
require_original_speed(capture)
if capture["failures"]:
    raise SystemExit("The replay failed; do not use this take")
if capture.get("castle_surfaces") != ["LiveTerminalWall1", "Royal Palace", "National War Museum", "LiveTerminalWall3", "LiveTerminalWall5"]:
    raise SystemExit("The main demo requires five prepared sessions in distinct Castle areas")
if set(capture['session_navigation']['prepared']) != {'Workspace', 'Filetree', 'Markdown', 'Diagram', 'Automation'}:
    raise SystemExit("Prepare all five feature sessions before recording")
probe = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
    "-show_entries", "stream=width,height,r_frame_rate,nb_read_frames", "-of", "json",
    str(take / "footage.mp4"),
]))["streams"][0]
if (probe["width"], probe["height"]) not in [(1600, 1000), (2400, 1500)] or probe["r_frame_rate"] != "60/1":
    raise SystemExit("Expected a 16:10 native-DPI, 60 FPS take")
if int(probe["nb_read_frames"]) != capture["frames"]:
    raise SystemExit("Encoded frames do not match the replay's video clock")
capture["size"] = [probe["width"], probe["height"]]
source = (root / "index.html").read_text()
# Frame-specific patches belong to their source take. A fresh filetree capture
# already includes the direct session transition; only explicitly retained popup
# footage is reinserted below using its source-frame evidence.
for marker in ["filetree-transition", "markdown-transition", "search-menu"]:
    source = re.sub(r"\s*<!-- " + marker + r":start -->.*?<!-- " + marker + r":end -->", "", source, flags=re.S)
(root / "filetree-transition.json").unlink(missing_ok=True)
(root / "markdown-transition.json").unlink(missing_ok=True)
# Rebuilding the desktop chapter clears the appended Android chapter. Re-run
# append_android.py after preparing/replacing desktop footage.
source = re.sub(r"\s*<!-- android-chapter:start -->.*?<!-- android-chapter:end -->", "", source, flags=re.S)
source = re.sub(r"\s*// android-stage:start.*?// android-stage:end", "", source, flags=re.S)
for chapter in ["parallel", "systemone", "protocol", "watcher", "native-window", "demo-narration"]:
    # Appended chapters are regenerated from their own unchanged capture files.
    marker = chapter + "-chapter" if chapter in ["parallel", "systemone", "protocol", "watcher"] else chapter
    stage = chapter + "-stage" if chapter in ["parallel", "systemone", "protocol", "watcher"] else "native-window-stage"
    source = re.sub(r"\s*<!-- " + marker + r":start -->.*?<!-- " + marker + r":end -->", "", source, flags=re.S)
    source = re.sub(r"\s*// " + stage + r":start.*?// " + stage + r":end", "", source, flags=re.S)
source = re.sub(r"--footage-scale: [\d.]+", f'--footage-scale: {1344 / probe["width"]:.6f}', source)
# Input cadence and idle pauses belong to the replay; preserve real-time motion.
playback_rate = 1.0
source_duration = int(probe["nb_read_frames"]) / 60
segments = []
duration = 0.0
# Preserve the approved text-viewer -> loaded-PNG edit on every new take.
cuts = timeline_cuts(capture, take)
spans = []
cursor = 0.0
for cut in cuts:
    if cut["source_start"] > cursor:
        spans.append(("footage" if not spans else f"footage-{len(spans)}",
                      cursor, cut["source_start"], playback_rate))
    cursor = max(cursor, cut["source_end"])
if cursor < source_duration:
    spans.append(("footage" if not spans else f"footage-{len(spans)}", cursor, source_duration, playback_rate))
for clip_id, start, end, rate in spans:
    length = (end - start) / rate
    segments.append({"id": clip_id, "source_start": start, "source_end": end,
                     "start": duration, "duration": length, "playback_rate": rate})
    duration += length
shutil.copyfile(take / "footage.mp4", root / "assets/footage.mp4")
for selector in [r'data-composition-id="main"', r'id="traffic-lights"']:
    source = re.sub('(' + selector + r'[^>]*data-duration=")[\d.]+',
                    lambda m: m[1] + f'{duration:.6f}', source, count=1)
clips = []
for segment in segments:
    hf_id = ' data-hf-id="hf-dkpw"' if segment["id"] == "footage" else ""
    clips.append(
        f'      <video{hf_id} id="{segment["id"]}" class="clip footage" '
        f'src="assets/footage.mp4" muted playsinline '
        f'data-start="{segment["start"]:.6f}" data-duration="{segment["duration"]:.6f}" '
        f'data-media-start="{segment["source_start"]:.6f}" '
        f'data-playback-rate="{segment["playback_rate"]:g}" data-track-index="0"></video>'
    )
source, replaced = re.subn(
    r'<!-- recorded-footage:start -->.*?<!-- recorded-footage:end -->',
    '<!-- recorded-footage:start -->\n' + '\n'.join(clips) + '\n      <!-- recorded-footage:end -->',
    source, flags=re.DOTALL,
)
if replaced != 1:
    raise SystemExit("Expected one recorded-footage section in index.html")

def timeline_time(source_time):
    for segment in segments:
        if source_time <= segment["source_end"]:
            return segment["start"] + max(0, source_time - segment["source_start"]) / segment["playback_rate"]
    return duration

search_recording = capture.get("tabs_summary", {}).get("search", {}).get("recording")
if search_recording:
    start = timeline_time(search_recording["raw_start_frame"] / 60)
    end = timeline_time(search_recording["raw_end_frame"] / 60)
    search_recording.update(start=start, duration=end - start)
    source = source.replace('<!-- recorded-footage:end -->',
        '<!-- recorded-footage:end -->\n      <!-- search-menu:start -->\n'
        f'      <video id="typo-search-menu" class="clip footage" src="{search_recording["asset"]}" muted playsinline '
        f'data-start="{start:.6f}" data-duration="{end-start:.6f}" data-media-start="0" data-track-index="1" '
        'style="z-index:1;pointer-events:none"></video>\n      <!-- search-menu:end -->')

chapters = [{"start": 0, "text": "terminal with tiling windows"}]
chapters += [{"start": timeline_time(beat["frame"] / 60), "text": beat["action"].removeprefix("Chapter: ")}
             for beat in capture["beats"] if beat["action"].startswith("Chapter: ")]
captions = []
for i, chapter in enumerate(chapters):
    end = chapters[i + 1]["start"] if i + 1 < len(chapters) else duration
    chapter["duration"] = end - chapter["start"]
    captions.append(f'    <p id="subtitle-{i}" class="clip subtitles" data-start="{chapter["start"]:.6f}" '
                    f'data-duration="{chapter["duration"]:.6f}" data-track-index="2" data-track-kind="captions">'
                    + html.escape(chapter["text"]) + '</p>')
source, replaced = re.subn(
    r'<!-- subtitles:start -->.*?<!-- subtitles:end -->',
    '<!-- subtitles:start -->\n' + '\n'.join(captions) + '\n    <!-- subtitles:end -->',
    source, flags=re.DOTALL,
)
if replaced != 1:
    raise SystemExit("Expected one subtitles section in index.html")
native_html, native_script = compose_native_window(root, take, capture, timeline_time)
if native_html:
    source = source.replace('    <!-- subtitles:start -->', native_html + '\n    <!-- subtitles:start -->')
    source = source.replace('gsap.timeline({ paused: true });',
                            'gsap.timeline({ paused: true });\n' + native_script)
if capture.get("native_window"):
    source = source.replace('    <!-- subtitles:start -->',
                            compose_narration(root, capture, timeline_time) + '\n    <!-- subtitles:start -->')
(root / "index.html").write_text(source)
capture["take"] = str(take.relative_to(root.parents[2]))
capture["playback_rate"] = playback_rate
capture["timeline_duration"] = duration
capture["segments"] = segments
capture["chapters"] = chapters
capture["cuts"] = cuts
capture["quit_settling_pause"] = None
capture["cwd_settling_pause"] = None
capture["post_typing_pause"] = None
(root / "capture.json").write_text(json.dumps(capture, indent=2) + "\n")
print(f"Prepared {duration:.3f}s at {playback_rate:g}x with replay-controlled typing and pauses")
