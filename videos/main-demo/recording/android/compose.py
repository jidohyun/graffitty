#!/usr/bin/env python3
"""Composite device or desktop mobile pixels into the one-second phone opening."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / 'videos/shared'))
from video_artifacts import artifact_path, export_path
p = argparse.ArgumentParser()
p.add_argument('take', type=Path)
p.add_argument('--output', type=Path, default=artifact_path('android-demo', 'android-phone-demo.mp4'))
a = p.parse_args()
a.output = export_path(a.output)
raw = a.take.resolve() / 'device-raw.mp4'
phone = ROOT / 'videos/main-demo/assets/takes/phone'
metadata = json.loads((phone / 'screen-overlay.json').read_text())
probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(raw)]))
video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
crop_path = a.take / 'screen-crop.json'
restore = ''
if crop_path.exists():
    crop = json.loads(crop_path.read_text())
    x, y, w, h = crop['app_rect']
    assert [video['width'], video['height']] == [w, h]
    assert crop['source_display'] == metadata['source_display']
    restore = f'pad={crop["source_display"][0]}:{crop["source_display"][1]}:{x}:{y}:black,'
else:
    assert [video['width'], video['height']] == metadata['source_display'], 'Expected the native Fold7 recording ratio'
assert metadata['fps'] == 60
beats = json.loads((a.take / 'beats.json').read_text())
capture_preroll = .15
# Keep the single pane, pointer approach, split-button click and pane opening.
screen_start = 0.0
length = float(probe['format']['duration']) - screen_start + 1
bounds = metadata['inner_screen_bounds']
# Preserve source aspect ratio; the even height rounds less than one screen pixel.
filters = (
    f'[0:v]fps=60,format=rgba,tpad=stop_mode=clone:stop_duration={length}[phone];'
    f'[1:v]trim=start={screen_start},setpts=PTS-STARTPTS,fps=60,{restore}scale={bounds["width"]}:-2:flags=lanczos,format=rgba,setpts=PTS+1/TB[screen];'
    f'color=c=0x15181f:s=1920x1080:r=60:d={length}[background];'
    '[background][phone]overlay=shortest=1:format=auto[body];'
    f'[body][screen]overlay=x={bounds["x"]}:y={bounds["y"]}:enable=\'gte(t,1)\':eof_action=pass:format=auto,format=yuv420p[out]'
)
a.output.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y',
    '-i', str(phone / 'phone-opening-alpha.mov'), '-i', str(raw),
    '-filter_complex', filters, '-map', '[out]', '-an', '-t', str(length),
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '17', '-r', '60',
    '-movflags', '+faststart', str(a.output)], check=True)
a.output.with_suffix('.json').write_text(json.dumps({
    'screen_source_start': screen_start, 'capture_preroll': capture_preroll,
    'opening_duration': 1.0,
}, indent=2) + '\n')
print(a.output)
