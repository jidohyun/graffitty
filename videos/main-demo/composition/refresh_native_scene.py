#!/usr/bin/env python3
"""Replace only the native-window interval; retain the encoded surrounding film."""
import json, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent
OUT=ROOT.parents[2]/'videos/artifacts/main-demo'
WORK=ROOT/'.hyperframes/native-refresh';WORK.mkdir(parents=True,exist_ok=True)
meta=json.loads((ROOT/'native-window-capture.json').read_text())
# The short scene has its own local metadata; use the parent's global cue.
start=round(meta['timeline_start']*60);end=round(meta['timeline_end']*60)

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
    # Output seeking drops preroll. Half a frame of tolerance keeps a keyframe
    # whose millisecond WebM timestamp rounds just below the 60 fps boundary.
    run(['ffmpeg','-v','error','-y','-i',source,'-ss',str(right/60-.5/60),'-map','0:v:0','-an','-c','copy','-avoid_negative_ts','make_zero',after])
    if suffix=='mp4':
        # Keep the existing title and narration captions above/below the scene.
        graph=f'[1:v]crop=1920:860:0:100,settb=expr=1/60,setpts=N+{start-left}[native];[0:v][native]overlay=0:100:enable=\'gte(n,{start-left})*lt(n,{end-left})\':eof_action=pass[out]'
        run(['ffmpeg','-v','error','-y','-ss',str(left/60),'-i',source,'-i',OUT/'native-chromium-scene.mp4','-filter_complex',graph,'-map','[out]','-frames:v',str(right-left),'-an','-r','60','-c:v','libx264','-preset','veryfast','-crf','16','-pix_fmt','yuv420p','-bf','0','-video_track_timescale','15360',middle])
    else:
        run(['ffmpeg','-v','error','-y','-ss',str(left/60),'-i',OUT/'main-demo.mp4','-map','0:v:0','-an','-frames:v',str(right-left),'-c:v','libvpx-vp9','-b:v','0','-crf','28','-deadline','good','-cpu-used','3','-row-mt','1','-tile-columns','2','-threads','8','-g','240','-pix_fmt','yuv420p',middle])
    listing=WORK/('concat-'+suffix+'.txt');listing.write_text(''.join(f"file '{p.name}'\n" for p in [before,middle,after]))
    joined=WORK/('joined.'+suffix)
    run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',listing,'-map','0:v:0','-c','copy',joined])
    result=OUT/('.main-demo.pending.'+suffix)
    run(['ffmpeg','-v','error','-y','-i',joined,'-i',source,'-map','0:v:0','-map','1:a:0','-c','copy',*(['-movflags','+faststart'] if suffix=='mp4' else []),result])
    stream=info(result,True);assert int(stream['nb_read_frames'])==expected,(suffix,stream,expected)
    assert (stream['width'],stream['height'],stream['r_frame_rate'])==(1920,1080,'60/1')
    result.replace(source)
    reports[suffix]={'start_frame':left,'end_frame':right,'reencoded_frames':right-left,'copied_frames':expected-(right-left),'frames':expected}
    print(suffix,reports[suffix],flush=True)
report=OUT/'main-demo.webm.json';data=json.loads(report.read_text());data['source_bytes']=(OUT/'main-demo.mp4').stat().st_size;data['output_bytes']=(OUT/'main-demo.webm').stat().st_size;data['native_refresh']=reports;report.write_text(json.dumps(data,indent=2)+'\n')
(OUT/'final-review/native-refresh.json').write_text(json.dumps(reports,indent=2)+'\n')
run(['ffmpeg','-v','error','-y','-ss',str((start-60)/60),'-i',OUT/'main-demo.mp4','-t','14','-c','copy',OUT/'chromium-native-review.mp4'])
