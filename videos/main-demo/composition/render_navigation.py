#!/usr/bin/env python3
"""Insert the three new scenes into the accepted render, retaining its other pixels."""
import json
from pathlib import Path
import shutil
import subprocess

from edit_decisions import edited_frame
from narration import audio_inputs
from presentation import render_inputs
from render_systemone import frame_hash

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
OUT=REPO/'videos/artifacts/main-demo'
WORK=ROOT/'.hyperframes/navigation-edit'


def run(args):
    subprocess.run([str(x) for x in args],check=True)


def probe(path,count=False):
    return json.loads(subprocess.check_output(['ffprobe','-v','error',*(['-count_frames'] if count else []),
        '-select_streams','v:0','-show_streams','-of','json',str(path)]))['streams'][0]


def codec(suffix):
    if suffix=='mp4':
        return ['-c:v','libx264','-preset','veryfast','-crf','16','-bf','0','-video_track_timescale','15360']
    return ['-c:v','libvpx-vp9','-b:v','0','-crf','28','-deadline','good','-cpu-used','3',
            '-row-mt','1','-tile-columns','2','-threads','8','-g','240']


def join(parts,output):
    playlist=output.with_suffix('.txt')
    playlist.write_text(''.join(f"file '{p}'\nduration {n/60:.9f}\n" for p,n in parts))
    run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',playlist,
         '-map','0:v:0','-an','-c:v','copy',output])


def extract(source,start,end,suffix,keyframes,label):
    """Only re-encode incomplete GOPs on either side of an exact frame cut."""
    first=next(n for n in keyframes if n>=start)
    last=max(n for n in keyframes if n<=end)
    assert start<=first<=last<=end
    pieces=[]
    for kind,a,b in [('head',start,first),('copy',first,last),('tail',last,end)]:
        if a==b:continue
        target=WORK/f'{label}-{kind}.{suffix}'
        if kind=='copy':
            run(['ffmpeg','-v','error','-y','-i',source,'-ss',max(0,a/60-.5/60),
                 '-map','0:v:0','-frames:v',b-a,'-an','-c:v','copy','-avoid_negative_ts','make_zero',target])
        else:
            run(['ffmpeg','-v','error','-y','-ss',a/60,'-i',source,'-map','0:v:0',
                 '-frames:v',b-a,'-an',*codec(suffix),'-pix_fmt','yuv420p',target])
        pieces.append((target,b-a))
    output=WORK/f'{label}.{suffix}'
    join(pieces,output)
    return output,end-start


def main():
    meta=json.loads((ROOT/'capture.json').read_text())
    old=json.loads((WORK/'capture.json').read_text())
    old_routing=json.loads((WORK/'systemone-capture.json').read_text())
    added=[s for s in meta['reused_recordings'] if s['label'] in ['chromium-diagram','tabs-summary','command-line']]
    plate=ROOT.parent/'assets/fixtures/castle-composite'
    # The new scenes use the same frozen plate, title/caption renderer and masks.
    rendered={}
    for section in added:
        label=section['label'];frames=section['end_frame']-section['start_frame']
        at=edited_frame(section['timeline_start_frame'],meta['cuts'])/60
        inputs,filters,last=render_inputs(ROOT,4,at,frames/60)
        graph=('[0:v]scale=1344:840:flags=lanczos,format=rgba[s];[s][2:v]alphamerge[w];'
               '[1:v][w]overlay=288:112:shortest=1[b];[b][3:v]overlay=299:132[film];'+filters)
        target=WORK/f'{label}.mp4'
        run(['ffmpeg','-v','error','-y','-ss',section['start_frame']/60,'-i',REPO/section['source']/'footage.mp4',
             '-loop','1','-framerate','60','-i',plate/'plate.png','-loop','1','-framerate','60','-i',plate/'mask.png',
             '-i',plate/'traffic.png',*inputs,'-filter_complex',graph,'-map',f'[{last}]',
             '-frames:v',frames,'-an',*codec('mp4'),'-pix_fmt','yuv420p',target])
        assert int(probe(target)['nb_frames'])==frames
        rendered[label]=(target,frames)
        print(f'Rendered {label}: {frames/60:.3f}s',flush=True)
    routing=json.loads((ROOT/'systemone-capture.json').read_text())
    total=round((routing['start']+routing['duration'])*60)
    placed=json.loads((ROOT/'demo-narration-cues.json').read_text())['cues']
    insertion=next(c['start'] for c in old['chapters'] if c['text']=='Chromium: automation')
    boundaries=[0,round(insertion*60),round(old['timeline_duration']*60),round(old_routing['start']*60)]
    proof={}
    for suffix in ['mp4','webm']:
        source=WORK/f'original.{suffix}'
        info=probe(source)
        packets=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
            '-show_packets','-show_entries','packet=pts_time,flags','-of','json',str(source)]))['packets']
        origin=float(info.get('start_time',0))
        keyframes=[round((float(p['pts_time'])-origin)*60) for p in packets if 'K' in p['flags']]
        originals=[extract(source,a,b,suffix,keyframes,f'accepted-{i}') for i,(a,b) in enumerate(zip(boundaries,boundaries[1:]))]
        scenes={}
        for label,(mp4,frames) in rendered.items():
            target=mp4.with_suffix('.'+suffix)
            if suffix=='webm':
                run(['ffmpeg','-v','error','-y','-i',mp4,'-map','0:v:0','-an',
                     '-frames:v',frames,*codec(suffix),'-pix_fmt','yuv420p',target])
            scenes[label]=(target,frames)
        ending=(OUT/f'systemone-demo.{suffix}',round(routing['duration']*60))
        parts=[originals[0],scenes['chromium-diagram'],originals[1],scenes['tabs-summary'],
               scenes['command-line'],originals[2],ending]
        assert sum(n for _,n in parts)==total
        joined=WORK/f'joined.{suffix}'
        join(parts,joined)
        inputs,mix=audio_inputs(ROOT,placed,total/60)
        pending=WORK/f'final.{suffix}'
        run(['ffmpeg','-v','error','-y','-i',joined,*inputs,'-filter_complex',mix,
             '-map','0:v:0','-map','[voice]','-c:v','copy','-c:a','aac' if suffix=='mp4' else 'libopus',
             '-b:a','192k' if suffix=='mp4' else '128k','-ac','2','-ar','48000','-t',total/60,
             *(['-movflags','+faststart'] if suffix=='mp4' else []),pending])
        stream=probe(pending,count=True)
        assert int(stream['nb_read_frames'])==total,(suffix,stream['nb_read_frames'],total)
        framing=['-fflags','+noparse+nofillin'] if suffix=='webm' else []
        run(['ffmpeg','-v','error','-xerror',*framing,'-i',pending,'-vn','-f','null','-'])
        times=[(10,10),(70,70),(105,105+added[0]['end_frame']/60-added[0]['start_frame']/60),
               (200,200+sum(n for _,n in rendered.values())/60)]
        for before,after in times:
            assert frame_hash(source,before)==frame_hash(pending,after),(suffix,before,after)
        pending.replace(OUT/f'main-demo.{suffix}')
        proof[suffix]={'frames':total,'unchanged_frame_samples':times,'audio_decode':'passed'}
        print(f'{suffix}: {total} decoded frames; unchanged footage samples verified',flush=True)
    report_path=OUT/'main-demo.webm.json'
    report=json.loads(report_path.read_text())
    report.update(frames=total,source_bytes=(OUT/'main-demo.mp4').stat().st_size,
                  output_bytes=(OUT/'main-demo.webm').stat().st_size,
                  systemone_start_frame=round(routing['start']*60),navigation_insertions=proof)
    report['video']['assembly']='Accepted footage copied with exact frame cuts; three inserted scenes and revised SystemOne ending'
    report_path.write_text(json.dumps(report,indent=2)+'\n')
    castle=json.loads((OUT/'main-demo.castle.json').read_text())
    castle.update(take=meta['take'],desktop_frames=round(meta['timeline_duration']*60),
                  cuts=meta['cuts'],chapters=meta['chapters'],result=probe(OUT/'main-demo.mp4'),
                  systemone={'start':routing['start'],'duration':routing['duration'],'take':routing['take']})
    (OUT/'main-demo.castle.json').write_text(json.dumps(castle,indent=2)+'\n')
    for suffix in ['srt','vtt']:
        shutil.copyfile(ROOT/f'demo-subtitles.{suffix}',OUT/f'main-demo.{suffix}')
    (WORK/'verification.json').write_text(json.dumps(proof,indent=2)+'\n')


if __name__=='__main__':main()
