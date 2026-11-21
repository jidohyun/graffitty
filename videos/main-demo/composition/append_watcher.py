#!/usr/bin/env python3
"""Append verified watcher footage immediately after the accepted uppercase example."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

from narration import place_chapter
from presentation import apply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('take', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    take = args.take.resolve()
    capture = json.loads((take / 'capture.json').read_text())
    evidence = json.loads((take / 'watcher-evidence.json').read_text())
    assert not capture['failures'], capture['failures']
    assert evidence['delivered'] and evidence['silent_before_email'] and evidence['claude_prepared'] and evidence['podcast_created'] and evidence['messages'] == 1
    assert evidence['prepared_sessions'] == 4 and evidence['watcher_session'].startswith('$')
    assert capture['beats'][0]['action'] == 'Watcher: session click'
    assert evidence['continuous_after_session_click']
    assert 0 <= evidence['released_frame'] <= evidence['received_frame'] < capture['frames']
    assert (take / 'node.py').read_bytes() == (root.parents[2] / 'examples/watcher-node/node.py').read_bytes()
    stream = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height,r_frame_rate,nb_frames', '-of', 'json', str(take / 'footage.mp4')]))['streams'][0]
    assert (stream['width'], stream['height'], stream['r_frame_rate']) == (2400, 1500, '60/1')
    assert int(stream['nb_frames']) == capture['frames']
    previous = json.loads((root / 'protocol-capture.json').read_text())
    start, duration = previous['start'] + previous['duration'], capture['frames'] / 60
    shutil.copyfile(take / 'footage.mp4', root / 'assets/watcher-footage.mp4')
    meta = dict(session_navigation=capture['session_navigation'], take=str(take.relative_to(root.parents[2])), start=start, duration=duration,
        subtitle='Watcher: turn new email into a podcast', beats=capture['beats'],
        failures=[], command=evidence['command'], messages=1, delivered=True,
        silent_before_email=True, claude_prepared=True, podcast_created=True, recipient='claude', prepared_sessions=evidence['prepared_sessions'], watcher_session=evidence['watcher_session'],
        example='examples/watcher-node/node.py',
        email='Local email CLI fixture released on camera; real GGP delivery and podcast tool',
        window=previous['window'])
    (root / 'watcher-capture.json').write_text(json.dumps(meta, indent=2) + '\n')
    source = (root / 'index.html').read_text()
    source = re.sub(r'\s*<!-- watcher-chapter:start -->.*?<!-- watcher-chapter:end -->', '', source, flags=re.S)
    source = re.sub(r'\s*// watcher-stage:start.*?// watcher-stage:end', '', source, flags=re.S)
    # Reuse the accepted framing, not the earlier chapter's pixels or timing.
    block = re.search(r'    <!-- protocol-chapter:start -->.*?<!-- protocol-chapter:end -->', source, re.S)[0]
    block = block.replace('protocol-', 'watcher-')
    block = re.sub(r'data-start="[\d.]+"', f'data-start="{start:.6f}"', block)
    block = re.sub(r'data-duration="[\d.]+"', f'data-duration="{duration:.6f}"', block)
    source = source.replace('<!-- protocol-chapter:end -->', '<!-- protocol-chapter:end -->\n' + block)
    source = source.replace('// protocol-stage:end', '// protocol-stage:end\n    // watcher-stage:start\n'
        + f'    window.__timelines["main"].set("#watcher-window", {{opacity:1}}, {start:.6f});\n    // watcher-stage:end')
    source = re.sub(r'(data-composition-id="main"[^>]*data-duration=")[\d.]+',
        lambda m: m[1] + f'{start + duration:.6f}', source, count=1)
    (root / 'index.html').write_text(source)
    place_chapter(root, 'watcher')
    apply(root)
    print(f'Watcher: {duration:.2f}s; full demo: {start + duration:.2f}s')


if __name__ == '__main__':
    main()
