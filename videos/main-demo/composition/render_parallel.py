#!/usr/bin/env python3
"""Composite recorded pixels into the verified HyperFrames window/caption plate."""
import argparse,json,math,subprocess,tempfile,sys
from pathlib import Path
from PIL import Image,ImageDraw
sys.path.insert(0,str(Path(__file__).resolve().parents[3]/'videos/shared'))
from video_artifacts import artifact_path,export_path
p=argparse.ArgumentParser();p.add_argument('--plate',type=Path,default=Path(__file__).resolve().parents[1]/'assets/fixtures/castle-composite/parallel-plate.png');p.add_argument('--output',type=Path,default=artifact_path('main-demo','parallel-demo.mp4'));a=p.parse_args()
a.output=export_path(a.output)
a.output.parent.mkdir(parents=True,exist_ok=True)
root=Path(__file__).resolve().parent
meta=json.loads((root/'parallel-capture.json').read_text())
window=meta['window']; lights=meta['traffic_lights_source']
sx=window['width']/window['source_width'];sy=window['height']/window['source_height']
lx=math.floor(window['x']+lights['x']*sx)-1;ly=math.floor(window['y']+lights['y']*sy)-1
rx=math.ceil(window['x']+(lights['x']+lights['width'])*sx)+1;by=math.ceil(window['y']+(lights['y']+lights['height'])*sy)+1
with tempfile.TemporaryDirectory(prefix='parallel-composite-') as folder:
 folder=Path(folder)
 mask=Image.new('L',(1344,840));ImageDraw.Draw(mask).rounded_rectangle((0,0,1343,839),radius=20,fill=255);mask.save(folder/'mask.png')
 plate=Image.open(a.plate);assert plate.size==(1920,1080)
 plate.crop((lx,ly,rx,by)).save(folder/'traffic.png')
 filters=f'[0:v]scale=1344:840:flags=lanczos,format=rgba[scaled];[scaled][2:v]alphamerge[window];[1:v][window]overlay=288:56:shortest=1[stage];[stage][3:v]overlay={lx}:{ly},format=yuv420p[out]'
 subprocess.run(['ffmpeg','-hide_banner','-loglevel','warning','-y','-i',str(root/'assets/parallel-footage.mp4'),'-loop','1','-framerate','60','-i',str(a.plate),'-loop','1','-framerate','60','-i',str(folder/'mask.png'),'-i',str(folder/'traffic.png'),'-filter_complex',filters,'-map','[out]','-an','-t',str(meta['duration']),'-r','60','-c:v','libx264','-preset','veryfast','-crf','16','-profile:v','high','-level:v','5.0','-bf','0','-video_track_timescale','15360','-movflags','+faststart',str(a.output)],check=True)
print(a.output.resolve())
