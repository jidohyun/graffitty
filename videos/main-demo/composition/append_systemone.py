#!/usr/bin/env python3
"""Append the verified SystemOne routing chapter after Android, with narration."""
import argparse
import html
import json
from pathlib import Path
import re
import shutil
import subprocess

from narration import VOICE_GAIN

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('take', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent
take = args.take.resolve()
capture = json.loads((take/'capture.json').read_text())
assert not capture['failures'], capture['failures']
evidence = json.loads((take/'graph-evidence.json').read_text())
assert len(evidence['edges']) == 3 and not any(e.get('read') for e in evidence['edges'])
assert evidence['route']['output'] == 'claude' and evidence['jev_title'] == 'SystemOne JEV'
manual = next(node for node in evidence['nodes'].values() if node.get('manifest',{}).get('name') == 'Manual Prompt')
assert manual['manifest']['outputs'][0].get('line_style') == 'solid', 'Record Manual Prompt with its direct-output style'
router = next(node for node in evidence['nodes'].values() if node.get('manifest',{}).get('name') == 'SystemOne JEV')
assert {p['id'] for p in router['manifest']['outputs']} == {'claude', 'codex'}
assert all(p.get('line_style') == 'solid' for p in router['manifest']['outputs']), 'Record automatic SystemOne routing with solid wires'
stream = json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
    '-show_entries','stream=width,height,r_frame_rate,nb_frames,duration','-of','json',str(take/'footage.mp4')]))['streams'][0]
assert (stream['width'],stream['height'],stream['r_frame_rate']) == (2400,1500,'60/1')
assert int(stream['nb_frames']) == capture['frames']
android = json.loads((root/'android-capture.json').read_text())
start = android['start'] + android['duration']
duration = capture['frames']/60
shutil.copyfile(take/'footage.mp4',root/'assets/systemone-footage.mp4')
subtitle = 'SystemOne node: choose an agent for each prompt'
metadata = {'continuous_workspace':capture.get('continuous_workspace'), 'session_navigation':capture.get('session_navigation'), 'workspace_source_frames':capture.get('source_frames'), 'take':str(args.take), 'start':start, 'duration':duration, 'subtitle':subtitle,
            'window':{'x':288,'y':112,'width':1344,'height':840,'source_width':2400,'source_height':1500},
            'beats':capture['beats'], 'failures':[], 'mock':True, 'routing_edges':3,
            'route':evidence['route']['output'], 'jev_title':evidence['jev_title'],
            'manual_output_style':'solid', 'routing_output_style':'solid'}
(root/'systemone-capture.json').write_text(json.dumps(metadata,indent=2)+'\n')
source = (root/'index.html').read_text()
source = re.sub(r'\s*<!-- systemone-chapter:start -->.*?<!-- systemone-chapter:end -->','',source,flags=re.S)
source = re.sub(r'\s*// systemone-stage:start.*?// systemone-stage:end','',source,flags=re.S)
source = re.sub(r'(data-composition-id="main"[^>]*data-duration=")([\d.]+)',lambda m:m[1]+f'{max(float(m[2]),start+duration):.6f}',source,count=1)  # Watcher, appended last, sets the exact total
block = f'''    <!-- systemone-chapter:start -->
    <div id="systemone-window" style="--footage-scale:0.56;position:absolute;left:288px;top:112px;width:1344px;height:840px;border-radius:20px;overflow:hidden;background:#4a4d54;box-shadow:0 24px 70px #080a1080,0 0 0 1px #73798350;opacity:0">
      <video id="systemone-footage" class="clip footage" src="assets/systemone-footage.mp4" muted playsinline data-start="{start:.6f}" data-duration="{duration:.6f}" data-track-index="0"></video>
      <div id="systemone-traffic" class="clip" data-start="{start:.6f}" data-duration="{duration:.6f}" data-track-index="1" style="position:absolute;top:calc(14px * var(--footage-scale));left:calc(20px * var(--footage-scale));display:flex;gap:calc(10px * var(--footage-scale));height:calc(16px * var(--footage-scale));z-index:2">
        <span class="light close" style="width:calc(16px * var(--footage-scale));height:100%"></span><span class="light minimize" style="width:calc(16px * var(--footage-scale));height:100%"></span><span class="light maximize" style="width:calc(16px * var(--footage-scale));height:100%"></span>
      </div>
    </div>
    <!-- systemone-chapter:end -->'''
source = source.replace('    <!-- android-chapter:end -->','    <!-- android-chapter:end -->\n'+block)
source = source.replace('    // android-stage:end','    // android-stage:end\n    // systemone-stage:start\n'
    +f'    window.__timelines["main"].set("#systemone-window", {{opacity:1}}, {start:.6f});\n    // systemone-stage:end')
voices = {v['id']:v for v in json.loads((root/'demo-audio.json').read_text())['voices']}
beats = {b['action']:b['frame']/60 for b in capture['beats']}
placed = json.loads((root/'demo-narration-cues.json').read_text())
placed['cues'] = [c for c in placed['cues'] if not c['id'].startswith('systemone-')]
audio = []
for name in ['intro']:
    id = 'systemone-'+name
    voice = voices[id]
    at = start + beats['SystemOne: '+name]
    assert at + voice['duration_s'] <= start + duration
    cue = {'id':id,'path':voice['path'],'start':at,'duration':voice['duration_s'],
           'end':at+voice['duration_s'],'volume':VOICE_GAIN}
    placed['cues'].append(cue)
    audio.append(f'    <audio id="voice-{id}" src="{html.escape(cue["path"])}" data-start="{at:.6f}" '
                 f'data-duration="{cue["duration"]:.6f}" data-media-start="0" data-track-index="5" '
                 f'data-audio-group="voiceover" data-volume="{VOICE_GAIN}"></audio>')
source = re.sub(r'\s*<audio id="voice-systemone-[^>]+></audio>','',source)
source = source.replace('    <!-- demo-narration:end -->','\n'.join(audio)+'\n    <!-- demo-narration:end -->')
placed['cues'].sort(key=lambda cue: cue['start'])
(root/'demo-narration-cues.json').write_text(json.dumps(placed,indent=2)+'\n')
(root/'index.html').write_text(source)
from presentation import apply
apply(root)
print(f'SystemOne: {duration:.2f}s, starts {start:.2f}s; total {start+duration:.2f}s')
