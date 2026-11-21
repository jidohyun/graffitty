"""Verify the active Chromium controls throughout the captured drag path."""
import subprocess,math,json,sys
from pathlib import Path
root=Path(__file__).resolve().parent
meta=json.loads((root/'native-window-capture.json').read_text())
path=sys.argv[1]
start=meta['timeline_start'] if 'main-demo' in path else 0
p=subprocess.Popen(['ffmpeg','-v','error','-ss',str(start),'-i',path,'-frames:v','720','-vf','crop=400:200:390:180','-pix_fmt','rgb24','-f','rawvideo','-'],stdout=subprocess.PIPE)
for n in range(720):
 raw=p.stdout.read(400*200*3);assert len(raw)==400*200*3
 t=n/60
 def ease(p):return (1-math.cos(math.pi*p))/2
 if t<2:x,y=650,160
 elif t<5:q=ease((t-2)/3);x,y=650-260*q,160+70*q
 elif t<6:x,y=390,230
 elif t<9:q=ease((t-6)/3);x,y=390+280*q,230-80*q
 else:x,y=670,150
 # Sample above the X glyph so the native hover symbol is not mistaken for an inactive control.
 px,py=round(x+40*.56-390),round(y+56+32*.56-180)
 r,g,b=raw[(py*400+px)*3:(py*400+px)*3+3]
 assert r>150 and r>g*1.4,(n,(r,g,b),(px,py))
assert p.wait()==0
print('PASS all 720 native-scene frames retain active red traffic light:',path)
