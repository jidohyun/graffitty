#!/usr/bin/env python3
"""Rebuild callout-bearing chapters, preserving the other chapters and audio."""
import json
import subprocess
from pathlib import Path

from refresh_nodes import prepare, render_chapter, packets
from render_navigation import join, run
from render_systemone import frame_hash

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parents[2] / 'videos/artifacts/main-demo'
WORK = ROOT / '.hyperframes/callout-refresh'


def main():
    prepare()
    WORK.mkdir(parents=True, exist_ok=True)
    film = OUT / 'main-demo.webm'
    total = packets(film)
    samples = [7, 81.3, 150, 240, 260, 325]
    before = [frame_hash(film, at) for at in samples]
    records = json.loads(subprocess.check_output(['ffprobe', '-v', 'error',
        '-select_streams', 'v:0', '-show_packets', '-show_entries',
        'packet=flags', '-of', 'json', str(film)]))['packets']
    parts = []

    def retain(first, last):
        if first == last:
            return
        assert 'K' in records[first]['flags'], 'Retained chapter must begin at a keyframe'
        path = WORK / f'retained-{first}.webm'
        run(['ffmpeg', '-v', 'error', '-y', '-i', film,
             '-ss', max(0, (first - .5) / 60), '-map', '0:v:0',
             '-frames:v', last - first, '-an', '-c:v', 'copy',
             '-avoid_negative_ts', 'make_zero', path])
        assert packets(path) == last - first
        parts.append((path, last - first))

    cursor = 0
    for kind in ['android', 'protocol']:
        meta = json.loads((ROOT / f'{kind}-capture.json').read_text())
        first = round(meta['start'] * 60)
        retain(cursor, first)
        parts.append(render_chapter(kind))
        cursor = first + round(meta['duration'] * 60)
    retain(cursor, total)
    joined = WORK / 'joined.webm'
    join(parts, joined)
    pending = WORK / 'final.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', joined, '-i', film,
         '-map', '0:v:0', '-map', '1:a:0', '-c', 'copy',
         '-bsf:v', 'setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)', pending])
    assert packets(pending) == total
    assert [frame_hash(pending, at) for at in samples] == before

    def audio_hash(path):
        return subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path),
            '-map', '0:a:0', '-c:a', 'copy', '-f', 'hash', '-hash', 'sha256', '-'])

    assert audio_hash(pending) == audio_hash(film)
    pending.replace(film)
    report_path = OUT / 'main-demo.webm.json'
    report = json.loads(report_path.read_text())
    report['output_bytes'] = film.stat().st_size
    report['callout_refresh'] = {'frames': total, 'retained_samples': samples,
                                 'original_audio_preserved': True}
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(f'Updated callouts: {total} frames, other chapters and original audio preserved')


if __name__ == '__main__':
    main()
