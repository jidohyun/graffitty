#!/usr/bin/env python3
"""Freeze the current HyperFrames window framing for the FFmpeg assembly."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent
source = (root / 'index.html').read_text()
head = re.search(r'<head>.*?</head>', source, re.S)[0]
lights = re.search(r'<div[^>]*id="traffic-lights".*?</div>', source, re.S)[0]
lights = re.sub(r' data-[\w-]+="[^"]*"', '', lights).replace('class="clip"', '')
pin = re.search(r'hyperframes@([\d.]+)', (root / 'package.json').read_text())[1]
plate = root.parent / 'assets/fixtures/castle-composite'
with tempfile.TemporaryDirectory(prefix='graffitty-plate-') as folder:
    folder = Path(folder)
    (folder / 'assets').symlink_to((root / 'assets').resolve(), target_is_directory=True)
    (folder / 'index.html').write_text(f'''<!doctype html><html lang="en">{head}<body>
<div id="root" data-composition-id="main" data-width="1920" data-height="1080" data-duration="1">
<div id="window">{lights}</div></div>
<script>window.__timelines["main"]=gsap.timeline({{paused:true}});</script></body></html>''')
    snapshots = folder / 'snapshots'
    subprocess.run(['bunx', f'hyperframes@{pin}', 'snapshot', str(folder),
                    '--at', '.5', '--no-end', '--output', str(snapshots)], check=True)
    paths = [p for p in snapshots.rglob('*.png') if 'contact' not in p.name and 'sheet' not in p.name]
    assert len(paths) == 1, paths
    shutil.copyfile(paths[0], plate / 'plate.png')
    # Only circles are overlaid on the footage; never paste the empty plate's
    # gray rectangle over the recorded title bar between its controls.
    controls = Image.new('RGBA', (69 * 8, 17 * 8))
    draw = ImageDraw.Draw(controls)
    for i, color in enumerate([(236,103,101),(242,202,68),(101,196,102)]):
        x, y = .2 + i * 25.76, .16
        draw.ellipse((x*8,y*8,(x+15.68)*8,(y+15.68)*8), fill=(*color,255),
                     outline=(*(round(c*207/255) for c in color),255), width=8)
    controls.resize((69,17), Image.Resampling.LANCZOS).save(plate / 'traffic.png')
    (plate / 'frame.json').write_text(json.dumps({'window': [288, 112, 1344, 840],
        'traffic': [299, 132, 69, 17], 'source': 'HyperFrames composition CSS'}, indent=2) + '\n')
print(plate)
