import sys,json,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent
sys.path.insert(0,str(root));import shortcuts
cues=json.loads((root/'presentation.json').read_text())['shortcuts']
for a,b in zip(cues,cues[1:]):
 if a['group']==b['group']:assert a['end_frame']==b['start_frame']
frames=max(c['end_frame'] for c in cues)+1
inputs,filters,last=shortcuts.render_inputs(root,cues,1,'0:v')
width,height=shortcuts.WIDTH,shortcuts.KEY_HEIGHT
key_y=shortcuts.Y+shortcuts.HEIGHT-height
cmd=['ffmpeg','-v','error','-f','lavfi','-i',f'color=c=magenta:s=1920x1080:r=60:d={frames/60}',*inputs,'-filter_complex',';'.join(filters)+f';[{last}]crop={width}:{height}:{shortcuts.X}:{key_y},format=rgb24[out]','-map','[out]','-frames:v',str(frames),'-f','rawvideo','-']
p=subprocess.Popen(cmd,stdout=subprocess.PIPE)
for n in range(frames):
 data=p.stdout.read(width*height*3)
 assert len(data)==width*height*3
 current=[c for c in cues if c['start_frame']<=n<c['end_frame']]
 if current and n < current[0]['end_frame']-(15 if current[0]['fade_out'] else 0):
  # Test visible key area, not just the persistent dark frame. Include short
  # stages and every transition frame; only exclude the intentional fade.
  assert sum(value>100 for value in data[1::3])>6000,(n,current)
assert p.wait()==0
print(f'PASS: all stages contiguous; {frames:,} rendered frames inspected, no disappearing shortcut frame.')
