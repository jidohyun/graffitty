#!/usr/bin/env python3
"""Replace only the filetree-to-tab pointer transition; preserve film timing/audio."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

from edit_decisions import edited_frame
from render_navigation import codec, join, probe, run
from render_systemone import frame_hash
from refresh_nodes import packets

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
OUT = REPO / 'videos/artifacts/main-demo'
WORK = ROOT / '.hyperframes/filetree-direct-transition'


def prepare(take):
    WORK.mkdir(parents=True, exist_ok=True)
    capture = json.loads((ROOT / 'capture.json').read_text())
    fresh = json.loads((take / 'capture.json').read_text())
    assert not fresh['failures']
    assert 'PASS Typing effects settle before the direct session transition' in (take/'godot.log').read_text()
    beats = {row['action']: row['frame'] for row in capture['beats']}
    # The retired replay explicitly moved for .4 * .4 seconds, then held .35.
    # Replace from its last stationary frame through the settled new tab.
    raw_start = beats['Select the Markdown session'] - 32
    raw_end = beats['Markdown session ready for typing']
    start, end = (edited_frame(n, capture['cuts']) for n in (raw_start, raw_end))
    length = end - start
    assert fresh['frames'] <= length, (fresh['frames'], length)
    points = fresh['transition_pointer']
    assert len(points) > 20
    # The direct path must never go near the old bottom-right waypoint.
    width, height = (n / fresh['ui_scale'] for n in fresh['size'])
    assert all(row['x'] < 0.85 * width or row['y'] < 0.85 * height for row in points)
    first, last = points[0], points[-1]
    distance = ((first['x']-last['x'])**2 + (first['y']-last['y'])**2)**.5
    traveled = sum(((a['x']-b['x'])**2 + (a['y']-b['y'])**2)**.5 for a,b in zip(points,points[1:]))
    assert distance > 100 and traveled <= distance * 1.06, (distance, traveled)
    source = ROOT / 'assets/filetree-transition.webm'
    run(['ffmpeg','-v','error','-y','-i',take/'footage.mp4','-vf',
         f'tpad=stop_mode=clone:stop_duration={length/60},trim=end_frame={length},setpts=N/(60*TB)',
         '-frames:v',length,'-an',*codec('webm'),'-pix_fmt','yuv420p',source])
    assert packets(source) == length
    meta = {'take':str(take.relative_to(REPO)), 'source':'assets/filetree-transition.webm',
            'start_frame':start,'end_frame':end,'start':start/60,'duration':length/60,
            'recorded_frames':fresh['frames'],'direct_pointer':True,'effects_settled':True,
            'pointer_distance':distance,'pointer_traveled':traveled,'failures':fresh['failures']}
    (ROOT/'filetree-transition.json').write_text(json.dumps(meta,indent=2)+'\n')
    html = (ROOT/'index.html').read_text()
    html = re.sub(r'\n\s*<!-- filetree-transition:start -->.*?<!-- filetree-transition:end -->','',html,flags=re.S)
    marker = '<!-- recorded-footage:end -->'
    html = html.replace(marker, marker+f'''
      <!-- filetree-transition:start -->
      <video id="filetree-direct-transition" class="clip footage" src="assets/filetree-transition.webm" muted playsinline data-start="{start/60:.6f}" data-duration="{length/60:.6f}" data-media-start="0" data-track-index="1" style="z-index:1;pointer-events:none"></video>
      <!-- filetree-transition:end -->''')
    (ROOT/'index.html').write_text(html)
    print(json.dumps(meta,indent=2),flush=True)


def render(metadata_name='filetree-transition.json', work=WORK):
    """Replace one recorded session transition and retain the accepted audio."""
    work.mkdir(parents=True, exist_ok=True)
    meta=json.loads((ROOT/metadata_name).read_text())
    film=OUT/'main-demo.webm'
    total=packets(film)
    source=work/'accepted.webm'
    shutil.copy2(film,source)
    stream=probe(source)
    records=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
        '-show_packets','-show_entries','packet=pts_time,flags','-of','json',str(source)]))['packets']
    origin=float(stream.get('start_time',0))
    keys=[round((float(p['pts_time'])-origin)*60) for p in records if 'K' in p['flags']]
    begin=max(k for k in keys if k<=meta['start_frame'])
    end=next(k for k in keys if k>=meta['end_frame'])
    offset=(meta['start_frame']-begin)/60
    finish=(meta['end_frame']-begin)/60
    plate=ROOT.parent/'assets/fixtures/castle-composite'
    replacement=work/'transition.webm'
    # Overlay only app pixels; existing titles/subtitles outside the app survive.
    graph=(f'[0:v]setpts=PTS-STARTPTS[base];[1:v]scale=1344:840:flags=lanczos,format=rgba[s];'
           '[s][2:v]alphamerge[window];[window][3:v]overlay=11:20[lit];'
           f'[lit]setpts=PTS-STARTPTS+{offset}/TB[fresh];'
           f"[base][fresh]overlay=288:112:enable='gte(t,{offset})*lt(t,{finish})':eof_action=pass[film]")
    run(['ffmpeg','-v','error','-y','-ss',begin/60,'-i',source,'-i',ROOT/meta['source'],
         '-loop','1','-framerate','60','-i',plate/'mask.png','-i',plate/'traffic.png',
         '-filter_complex',graph,'-map','[film]','-frames:v',end-begin,'-an',*codec('webm'),
         '-pix_fmt','yuv420p',replacement])
    assert packets(replacement)==end-begin
    prefix,suffix=work/'prefix.webm',work/'suffix.webm'
    run(['ffmpeg','-v','error','-y','-i',source,'-map','0:v:0','-frames:v',begin,'-an','-c:v','copy',prefix])
    run(['ffmpeg','-v','error','-y','-i',source,'-ss',end/60-.5/60,'-map','0:v:0',
         '-frames:v',total-end,'-an','-c:v','copy','-avoid_negative_ts','make_zero',suffix])
    assert packets(prefix)==begin and packets(suffix)==total-end
    joined=work/'joined.webm'
    join([(prefix,begin),(replacement,end-begin),(suffix,total-end)],joined)
    pending=work/'final.webm'
    run(['ffmpeg','-v','error','-y','-i',joined,'-i',source,'-map','0:v:0','-map','1:a:0',
         '-c','copy','-bsf:v','setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)',pending])
    assert int(probe(pending,count=True)['nb_read_frames'])==total
    samples=[at for at in [7,40,80,90,100,150,230,310,360]
             if at * 60 < total and not begin <= at * 60 < end]
    for at in samples: assert frame_hash(source,at)==frame_hash(pending,at),at
    run(['ffmpeg','-v','error','-xerror','-fflags','+noparse+nofillin','-i',pending,'-vn','-f','null','-'])
    pending.replace(film)
    path=OUT/'main-demo.webm.json'
    report=json.loads(path.read_text())
    key=metadata_name.removesuffix('.json').replace('-', '_')
    report.update(output_bytes=film.stat().st_size, **{key: meta})
    report['video']['assembly']='Updated session transition; other video packets and original audio retained'
    report[key]['unchanged_samples']=samples
    path.write_text(json.dumps(report,indent=2)+'\n')
    print(f'Updated only frames {begin}–{end}; {total} frames and original audio preserved',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--take',type=Path)
    parser.add_argument('--render',action='store_true')
    args=parser.parse_args()
    if args.take: prepare(args.take.resolve())
    if args.render: render()
