#!/usr/bin/env python3
"""Replace only the reused native scene, retaining accepted captions and audio."""
import json
from pathlib import Path
import shutil
import subprocess

import render_navigation as nav
from refresh_nodes import packets
from render_systemone import frame_hash
from verify_delivery import verify_timestamps

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parents[1] / 'artifacts/main-demo'


def main():
    work = ROOT / '.hyperframes/native-cursor'
    work.mkdir(parents=True, exist_ok=True)
    nav.WORK = work
    target = OUT / 'main-demo.webm'
    original = work / 'original.webm'
    if not original.exists():
        shutil.copy2(target, original)
    native = json.loads((ROOT / 'native-window-capture.json').read_text())
    start = round(native['timeline_start'] * 60)
    count = native['end_frame'] - native['start_frame'] + native['cursor_return_frames']
    end = start + count
    total = packets(original)
    scene = OUT / 'native-click-scene.mp4'
    assert packets(scene) == count
    data = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_packets', '-show_entries', 'packet=pts_time,flags', '-of', 'json', str(original)]))['packets']
    origin = float(data[0]['pts_time'])
    keys = [round((float(p['pts_time']) - origin) * 60) for p in data if 'K' in p['flags']]
    replacement = work / 'replacement.webm'
    # Copy the existing title and subtitle bands exactly; only the app scene changes.
    graph = ('[1:v]split=2[a][b];[a]crop=1920:112:0:0[top];'
             '[b]crop=1920:128:0:952[bottom];'
             '[0:v][top]overlay=0:0[x];[x][bottom]overlay=0:952[v]')
    nav.run(['ffmpeg', '-v', 'error', '-y', '-i', scene, '-ss', start / 60, '-i', original,
             '-filter_complex', graph, '-map', '[v]', '-frames:v', count, '-an',
             *nav.codec('webm'), '-pix_fmt', 'yuv420p', replacement])
    before = nav.extract(original, 0, start, 'webm', keys, 'before')
    after = nav.extract(original, end, total, 'webm', keys, 'after')
    joined = work / 'joined.webm'
    nav.join([before, (replacement, count), after], joined)
    pending = work / 'final.webm'
    nav.run(['ffmpeg', '-v', 'error', '-y', '-i', joined, '-i', original,
             '-map', '0:v:0', '-map', '1:a:0', '-c', 'copy',
             '-bsf:v', 'setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)', pending])
    verify_timestamps(pending, total)
    for t in [10, 70, 150, 220, 300]:
        assert frame_hash(original, t) == frame_hash(pending, t), t
    nav.run(['ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin',
             '-i', pending, '-vn', '-f', 'null', '-'])
    pending.replace(target)
    report_path = OUT / 'main-demo.webm.json'
    report = json.loads(report_path.read_text())
    report.update(output_bytes=target.stat().st_size, frames=total)
    report['native_cursor'] = {'frames': [start, end], 'scale': native['cursor_scale'],
        'continuous_return_frames': native['cursor_return_frames'], 'audio': 'stream copied',
        'unchanged_frame_samples': [10, 70, 150, 220, 300]}
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    current_take = ROOT.parents[2] / json.loads((ROOT / 'capture.json').read_text())['take']
    for destination in [ROOT / 'assets/reused-native-scene.mp4',
            current_take / 'native-click-scene.mp4']:
        shutil.copy2(scene, destination)
    print('Native cursor replacement verified', flush=True)


if __name__ == '__main__':
    main()
