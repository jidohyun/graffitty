#!/usr/bin/env python3
"""Split one verified prepared-session recording at the real click boundaries, at 1x."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "composition"))
from edit_decisions import session_navigation_span

p = argparse.ArgumentParser()
p.add_argument('take', type=Path)
a = p.parse_args()
take = a.take
capture = json.loads((take / 'capture.json').read_text())
assert not capture['failures']
log = (take / 'godot.log').read_text()
with_watcher = 'Watcher' in capture['session_navigation']['prepared']
assert ('WATCHERDEMO_REPLAY_PASS' if with_watcher else 'NODESESSIONSDEMO_REPLAY_PASS') in log
chapters = json.loads((take / 'chapter-frames.json').read_text())
# The edit opens on the arrived SystemOne graph. Parallel's workers were
# started off camera and resume when their session is clicked.
spans = {'systemone': [chapters['systemone'], chapters['parallel']],
         'parallel': [chapters['parallel'], chapters['protocol']],
         'protocol': [chapters['protocol'], chapters['end']]}
for name, (first, end) in spans.items():
    dest = take / name
    dest.mkdir(exist_ok=True)
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{first / 60:.9f}', '-i', str(take / 'footage.mp4'),
        '-vf', 'setpts=PTS-STARTPTS',
        '-frames:v', str(end-first), '-an', '-c:v', 'libx264', '-crf', '15', '-preset', 'veryfast',
        str(dest / 'footage.mp4')], check=True)
    meta = {**capture, 'frames': end-first, 'source_frames': [first, end],
            'session_navigation': session_navigation_span(capture, first, end, -first),
            'continuous_workspace': {'world': 'bistro', 'session': capture['session_navigation']['prepared'][{'parallel':'Parallel','systemone':'SystemOne','protocol':'Custom nodes'}[name]]['id'], 'prepared_sessions': len(capture['session_navigation']['prepared'])},
            'beats': [{**b, 'frame': b['frame']-first, 'seconds': (b['frame']-first)/60}
                      for b in capture['beats'] if first <= b['frame'] < end]}
    (dest / 'capture.json').write_text(json.dumps(meta, indent=2)+'\n')
    shutil.copy2(take / 'godot.log', dest / 'godot.log')
    if name == 'parallel':
        for f in ['wire-styles.json', 'received-combined.json']: shutil.copy2(take / f, dest / f)
    else:
        evidence = json.loads((take / ('systemone-evidence.json' if name == 'systemone' else 'graph-evidence.json')).read_text())
        if name == 'protocol':
            intro = evidence['live_agent_intro']
            for key in list(intro):
                if key.endswith('_frame'): intro[key] -= first
            shutil.copy2(take / ('protocol-node.py' if with_watcher else 'node.py'), dest / 'node.py')
        (dest / 'graph-evidence.json').write_text(json.dumps(evidence, indent=2)+'\n')
print(json.dumps(spans, indent=2))
