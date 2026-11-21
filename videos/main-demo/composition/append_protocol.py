#!/usr/bin/env python3
"""Append the real Python SDK demonstration, keeping accepted chapters intact."""
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
    evidence = json.loads((take / 'graph-evidence.json').read_text())
    assert not capture['failures'], capture['failures']
    replay = 'PROTOCOLDEMO'
    if capture.get('continuous_workspace'):
        replay = 'WATCHERDEMO' if 'Watcher' in capture['session_navigation']['prepared'] else 'NODESESSIONSDEMO'
    assert replay + '_REPLAY_PASS' in (take / 'godot.log').read_text(), 'The recording must also pass its rendering diagnostic guard'
    assert evidence['command'] == 'uv run node.py'
    assert evidence['delivered'] and evidence['original_session_reference']
    assert evidence['empty_manual_sessions']
    intro = evidence['live_agent_intro']
    assert 0 <= intro['connected_frame'] < intro['prompt_start_frame'] < intro['submitted_frame'] < intro['response_started_frame'] < intro['received_frame'] < capture['frames']
    assert intro['provider'] == 'claude' and intro['source_port'] == 'turn_completed'
    assert any(e['from'] == intro['source'] and e['to'] == intro['target'] and e.get('turn_completed') for e in evidence['edges'])
    assert evidence['result'] == 'HELLO GRAPH'
    example = root.parents[2] / 'examples/uppercase-node/node.py'
    assert (take / 'node.py').read_bytes() == example.read_bytes()
    stream = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height,r_frame_rate,nb_frames', '-of', 'json', str(take / 'footage.mp4')]))['streams'][0]
    assert (stream['width'], stream['height'], stream['r_frame_rate']) == (2400, 1500, '60/1')
    assert int(stream['nb_frames']) == capture['frames']
    previous = json.loads((root / 'parallel-capture.json').read_text())
    start, duration = previous['start'] + previous['duration'], capture['frames'] / 60
    shutil.copyfile(take / 'footage.mp4', root / 'assets/protocol-footage.mp4')
    title = 'Graffitty Graph Protocol (GGP): Make your custom node'
    meta = dict(continuous_workspace=capture.get('continuous_workspace'), session_navigation=capture.get('session_navigation'), workspace_source_frames=capture.get('source_frames'), take=str(args.take), start=start, duration=duration, subtitle=title,
        window=dict(x=288, y=112, width=1344, height=840, source_width=2400, source_height=1500),
        beats=capture['beats'], failures=[], command=evidence['command'], result=evidence['result'],
        delivered=True, original_session_reference=True, empty_manual_sessions=True,
        live_agent_intro=intro,
        example='examples/uppercase-node/node.py')
    (root / 'protocol-capture.json').write_text(json.dumps(meta, indent=2) + '\n')
    source = (root / 'index.html').read_text()
    source = re.sub(r'\s*<!-- protocol-chapter:start -->.*?<!-- protocol-chapter:end -->', '', source, flags=re.S)
    source = re.sub(r'\s*// protocol-stage:start.*?// protocol-stage:end', '', source, flags=re.S)
    # Later chapters follow; Watcher, appended last, sets the exact total.
    source = re.sub(r'(data-composition-id="main"[^>]*data-duration=")([\d.]+)',
        lambda m: m[1] + f'{max(float(m[2]), start + duration):.6f}', source, count=1)
    block = f'''    <!-- protocol-chapter:start -->
    <div id="protocol-window" style="--footage-scale:0.56;position:absolute;left:288px;top:112px;width:1344px;height:840px;border-radius:20px;overflow:hidden;background:#4a4d54;box-shadow:0 24px 70px #080a1080,0 0 0 1px #73798350;opacity:0">
      <video id="protocol-footage" class="clip footage" src="assets/protocol-footage.mp4" muted playsinline data-start="{start:.6f}" data-duration="{duration:.6f}" data-track-index="0"></video>
      <div id="protocol-traffic" class="clip" data-start="{start:.6f}" data-duration="{duration:.6f}" data-track-index="1" style="position:absolute;top:calc(14px * var(--footage-scale));left:calc(20px * var(--footage-scale));display:flex;gap:calc(10px * var(--footage-scale));height:calc(16px * var(--footage-scale));z-index:2">
        <span class="light close" style="width:calc(16px * var(--footage-scale));height:100%"></span><span class="light minimize" style="width:calc(16px * var(--footage-scale));height:100%"></span><span class="light maximize" style="width:calc(16px * var(--footage-scale));height:100%"></span>
      </div>
    </div>
    <!-- protocol-chapter:end -->'''
    source = source.replace('    <!-- parallel-chapter:end -->', '    <!-- parallel-chapter:end -->\n' + block)
    source = source.replace('    // parallel-stage:end', '    // parallel-stage:end\n    // protocol-stage:start\n'
        + f'    window.__timelines["main"].set("#protocol-window", {{opacity:1}}, {start:.6f});\n    // protocol-stage:end')
    (root / 'index.html').write_text(source)
    place_chapter(root, 'protocol')
    apply(root)
    print(f'Protocol: {duration:.2f}s; total {start + duration:.2f}s')


if __name__ == '__main__':
    main()
