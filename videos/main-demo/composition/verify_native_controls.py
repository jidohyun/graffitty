#!/usr/bin/env python3
"""Check idle, hover, and pressed pixels in the rendered native controls."""
import json
from pathlib import Path
import subprocess
import sys

root=Path(__file__).resolve().parent
path=Path(sys.argv[1])
start=json.loads((root/'native-window-capture.json').read_text())['timeline_start'] if 'main-demo' in path.name else 0

def frame(t):
    return subprocess.check_output(['ffmpeg','-v','error','-ss',str(start+t),'-i',str(path),
        '-frames:v','1','-vf','crop=100:40:670:206','-pix_fmt','rgb24','-f','rawvideo','-'])

def patch(raw,x,y):
    # Source-title-bar coordinates, converted to final rendered pixels.
    x,y=round(x*.56),round(y*.56)
    return tuple(sum(raw[((y+dy)*100+x+dx)*3+c] for dx in [-1,0,1] for dy in [-1,0,1])/9 for c in range(3))

idle,hover,pressed=[frame(t) for t in [10.8,11.4,11.8]]
# The minus appears on yellow while red is under the pointer.
assert patch(hover,86,41)[1] < patch(idle,86,41)[1]-25, 'Missing minimize hover glyph'
# The top of red avoids both the X and the cursor.
assert patch(pressed,40,32)[0] < patch(hover,40,32)[0]-25, 'Close did not darken while pressed'
assert patch(hover,132-4,41-4)[1] < patch(idle,132-4,41-4)[1]-15, 'Missing expand hover glyph'
print('PASS native traffic lights: idle, hover symbols, red press:',path)
