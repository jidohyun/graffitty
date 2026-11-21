#!/usr/bin/env python3
"""Frame a successful mobile capture with clean simulated system UI."""
from pathlib import Path
import argparse,json,re,shutil,subprocess
project=Path(__file__).resolve().parent
repo=project.parents[2]
p=argparse.ArgumentParser();p.add_argument('take',type=Path);p.add_argument('--arrival',type=float);a=p.parse_args()
take=a.take.resolve()
assert not json.loads((take/'capture.json').read_text()).get('failures')
output=repo/'videos/artifacts/android-demo/android-phone-native.mp4'
subprocess.run(['python3',str(repo/'videos/main-demo/recording/android/compose.py'),str(take),'--output',str(output)],check=True)
shutil.copyfile(output,project/'assets/phone-native.mp4')
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=nb_frames','-of','json',str(output)]))['streams'][0]
duration=int(probe['nb_frames'])/60
beats=json.loads((take/'beats.json').read_text());edit=json.loads(output.with_suffix('.json').read_text())
cue={}
if a.arrival is None:
 cue=json.loads((take/'slack-arrival.json').read_text())
 a.arrival=cue['capture_seconds']+edit['opening_duration']-edit['screen_source_start']
wiring=edit['opening_duration']+edit['capture_preroll']-edit['screen_source_start']+next(b['seconds'] for b in beats if b['action']=='Android: connect Turn completed to Receive')
s=(project/'index.html').read_text()
s=re.sub(r'data-duration="[\d.]+"',f'data-duration="{duration:.6f}"',s,count=1)
s=re.sub(r'(<video[^>]*data-duration=")[\d.]+',rf'\g<1>{duration:.6f}',s)
s=s.replace('assets/phone-inset.mp4','assets/phone-native.mp4')
s=re.sub(r'(<div[^>]*id="system"[^>]*data-duration=")[\d.]+',rf'\g<1>{duration-1:.6f}',s)
s=re.sub(r'(<p[^>]*data-start="0" data-duration=")[\d.]+',rf'\g<1>{wiring:.6f}',s)
s=re.sub(r'(<p[^>]*data-start=")[^0][\d.]+(" data-duration=")[\d.]+',rf'\g<1>{wiring:.6f}\g<2>{duration-wiring:.6f}',s)
s=re.sub(r'const arrival=[\d.]+;',f'const arrival={a.arrival};',s)
s=re.sub(r'// (?:The first incoming Slack payload|Frame \d+ is the first visible DELIVERED).*','// Notification cue measured when the delivery log becomes visible.',s)
s=s.replace('height:30.6px;display:flex','height:32px;background:#000;display:flex').replace('height:34.2px;display:flex','height:46px;display:flex').replace('gap:110px;background:#20242c','gap:110px;background:#000')
(project/'index.html').write_text(s)
(project/'overlay.json').write_text(json.dumps({'source':str(a.take),'screen_source_start':edit['screen_source_start'],'arrival_seconds':a.arrival,'arrival_frame':round(a.arrival*60),'arrival_event':cue.get('event','measured_delivery_log'),'fps':60,'duration':duration,'frames':int(probe['nb_frames']),'source_system_bars_cropped':json.loads((take/'screen-crop.json').read_text()).get('system_bars_removed',False),'capture_backend':json.loads((take/'capture.json').read_text()).get('capture_backend','android-device'),'notification_simulated':True},indent=2)+'\n')
print(duration,wiring)
