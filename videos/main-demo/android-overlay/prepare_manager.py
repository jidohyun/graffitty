#!/usr/bin/env python3
"""Frame a short manager recording with the accepted phone opening and system UI."""
import argparse
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent
repo = root.parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('take', type=Path)
args = parser.parse_args()
take = args.take.resolve()
capture = json.loads((take / 'capture.json').read_text())
assert not capture['failures']
# The recorder now follows the shortened narration directly. Keep the complete
# current take at 1x, including the real connection click and connected tail.
beats = {b['action']:b['seconds'] for b in json.loads((take/'beats.json').read_text())}
frames = capture['frames'] + 60
duration = frames / 60
phone = repo / 'videos/main-demo/assets/takes/phone'
layout = json.loads((phone / 'screen-overlay.json').read_text())
bounds = layout['inner_screen_bounds']
scene = root / 'manager-scene'
scene.mkdir(exist_ok=True)
if not (scene / 'assets').exists(): (scene / 'assets').symlink_to('../assets', target_is_directory=True)
source = scene / 'assets/manager-phone.mp4'
filters = (
    f'[0:v]fps=60,format=rgba,tpad=stop_mode=clone:stop_duration={duration}[phone];'
    f'[1:v]fps=60,pad=1968:2184:0:90:black,scale={bounds["width"]}:-2:flags=lanczos,format=rgba,setpts=PTS+1/TB[screen];'
    f'color=c=0x15181f:s=1920x1080:r=60:d={duration}[background];'
    '[background][phone]overlay=shortest=1:format=auto[body];'
    f'[body][screen]overlay=x={bounds["x"]}:y={bounds["y"]}:enable=\'gte(t,1)\':eof_action=pass:format=auto,format=yuv420p[out]'
)
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(phone/'phone-opening-alpha.mov'),
    '-i', str(take/'device-raw.mp4'), '-filter_complex', filters, '-map', '[out]', '-an',
    '-frames:v', str(frames), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '15',
    '-movflags', '+faststart', str(source)], check=True)
html = (root / 'index.html').read_text().replace('assets/phone-native.mp4', 'assets/manager-phone.mp4')
html = html.replace('data-composition-id="android-oneui"', 'data-composition-id="android-manager"')
html = re.sub(r'data-duration="[\d.]+"', f'data-duration="{duration:.6f}"', html)
html = re.sub(r'(<div[^>]*id="system"[^>]*data-duration=")[\d.]+', lambda m: m[1]+f'{duration-1:.6f}', html)
html = re.sub(r'<p[^>]*class="clip caption".*?</p>', '', html)
html = re.sub(r'<script>.*?</script>', '<script>window.__timelines=window.__timelines||{};window.__timelines["android-manager"]=gsap.timeline({paused:true});</script>', html, flags=re.S)
(scene / 'index.html').write_text(html)
pin = re.search(r'hyperframes@([\d.]+)', (root.parent/'composition/package.json').read_text())[1]
(scene / 'package.json').write_text(json.dumps({'name':'android-manager', 'private':True,
    'scripts':{'check':f'bunx hyperframes@{pin} check', 'render':'python3 ../../../shared/render.py --project .'}}, indent=2)+'\n')
(scene / 'hyperframes.json').write_text('{"media":{"autoProxy":true}}\n')
metadata = {'take':str(take.relative_to(repo)), 'frames':frames, 'duration':duration,
    'source_cut_frames':[],
    'connected_at':1+beats['Android: workspace connected'],
    'connect_clicked_at':1+beats['Android: connect chosen workspace'],
    'source':'assets/android-manager.webm', 'checks':capture['checks']}
(scene / 'capture.json').write_text(json.dumps(metadata,indent=2)+'\n')
print(json.dumps(metadata,indent=2))
