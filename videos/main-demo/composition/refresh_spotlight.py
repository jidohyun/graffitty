#!/usr/bin/env python3
"""Apply the connecting-line spotlight once to existing canonical exports."""
import json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent
OUT=ROOT.parents[2]/'videos/artifacts/main-demo'
WORK=ROOT/'.hyperframes/spotlight-refresh';WORK.mkdir(parents=True,exist_ok=True)
from spotlight import START, END, render_inputs
start=round(START*60);end=round(END*60)
marker=OUT/'final-review/spotlight-refresh.json'
if marker.exists():
    raise SystemExit('Spotlight already applied. Use the full render pipeline for subsequent visual revisions.')

def run(args): subprocess.run([str(x) for x in args],check=True)
def info(path,count=False):
    return json.loads(subprocess.check_output(['ffprobe','-v','error',*(['-count_frames'] if count else []),'-select_streams','v:0','-show_entries','stream=nb_frames,nb_read_frames,start_time,r_frame_rate,width,height','-of','json',str(path)]))['streams'][0]
def boundaries(path):
    packets=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_packets','-show_entries','packet=pts_time,flags','-of','json',str(path)]))['packets']
    zero=float(info(path).get('start_time',0))
    keys=[round((float(p['pts_time'])-zero)*60) for p in packets if 'K' in p['flags']]
    return max(n for n in keys if n<=start),min(n for n in keys if n>=end)

expected=int(info(OUT/'main-demo.mp4')['nb_frames'])
reports={}
for suffix in ['mp4','webm']:
    source=OUT/('main-demo.'+suffix);left,right=boundaries(source)
    before=WORK/('before.'+suffix);middle=WORK/('middle.'+suffix);after=WORK/('after.'+suffix)
    run(['ffmpeg','-v','error','-y','-i',source,'-map','0:v:0','-an','-frames:v',str(left),'-c','copy',before])
    # Half-frame seek tolerance preserves WebM keyframes rounded down by 1 ms.
    run(['ffmpeg','-v','error','-y','-i',source,'-ss',str(right/60-.5/60),'-map','0:v:0','-an','-c','copy','-avoid_negative_ts','make_zero',after])
    if suffix=='mp4':
        inputs, filters, label=render_inputs(ROOT,1,'0:v',left/60)
        run(['ffmpeg','-v','error','-y','-ss',str(left/60),'-i',source,*inputs,'-filter_complex',';'.join(filters),'-map',f'[{label}]','-frames:v',str(right-left),'-an','-r','60','-c:v','libx264','-preset','veryfast','-crf','16','-pix_fmt','yuv420p','-bf','0','-video_track_timescale','15360',middle])
    else:
        run(['ffmpeg','-v','error','-y','-ss',str(left/60),'-i',OUT/'main-demo.mp4','-map','0:v:0','-an','-frames:v',str(right-left),'-c:v','libvpx-vp9','-b:v','0','-crf','28','-deadline','good','-cpu-used','3','-row-mt','1','-tile-columns','2','-threads','8','-g','240','-pix_fmt','yuv420p',middle])
    listing=WORK/('concat-'+suffix+'.txt');listing.write_text(''.join(f"file '{p.name}'\n" for p in [before,middle,after]))
    joined=WORK/('joined.'+suffix)
    run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',listing,'-map','0:v:0','-c','copy',joined])
    result=OUT/('.main-demo.pending.'+suffix)
    run(['ffmpeg','-v','error','-y','-i',joined,'-i',source,'-map','0:v:0','-map','1:a:0','-c','copy',*(['-movflags','+faststart'] if suffix=='mp4' else []),result])
    stream=info(result,True);assert int(stream['nb_read_frames'])==expected,(suffix,stream,expected)
    assert (stream['width'],stream['height'],stream['r_frame_rate'])==(1920,1080,'60/1')
    def audio_hash(path):
        return subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-map','0:a:0','-c:a','copy','-f','hash','-hash','sha256','-'])
    assert audio_hash(result)==audio_hash(source), 'Audio stream changed'
    result.replace(source)
    reports[suffix]={'start_frame':left,'end_frame':right,'reencoded_frames':right-left,'copied_frames':expected-(right-left),'frames':expected}
    print(suffix,reports[suffix],flush=True)
report=OUT/'main-demo.webm.json';data=json.loads(report.read_text());data['source_bytes']=(OUT/'main-demo.mp4').stat().st_size;data['output_bytes']=(OUT/'main-demo.webm').stat().st_size;data['spotlight_refresh']=reports;report.write_text(json.dumps(data,indent=2)+'\n')
marker.write_text(json.dumps(reports,indent=2)+'\n')
