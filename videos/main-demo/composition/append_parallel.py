#!/usr/bin/env python3
"""Append the verified Parallel session after SystemOne."""
import argparse,html,json,re,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('take',type=Path);p.add_argument('--start-frame',type=int,required=True);a=p.parse_args()
root=Path(__file__).resolve().parent;take=a.take.resolve()
meta=json.loads((take/'capture.json').read_text())
assert not meta['failures'],meta['failures']
wire_styles=json.loads((take/'wire-styles.json').read_text())
assert wire_styles['combined']=='solid' and wire_styles['manifest']['outputs'][0]['line_style']=='solid', 'Parallel automatically sends Combined through a solid wire'
assert (take/'godot.log').read_text().count('PASS Automatic Parallel pipeline wires are solid') == 4
assert (take/'received-combined.json').exists()
stream=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=width,height,r_frame_rate,nb_frames,duration','-of','json',str(take/'footage.mp4')]))['streams'][0]
assert (stream['width'],stream['height'],stream['r_frame_rate'])==(2400,1500,'60/1')
assert abs(float(stream['duration'])-meta['frames']/60)<1/60
voices={v['id']:v for v in json.loads((root/'demo-audio.json').read_text())['voices']}
combined=next(b['frame'] for b in meta['beats'] if b['action']=='Parallel: all three completed; compare combined implementation')
end_frame=meta['frames'] if meta.get('continuous_workspace') else combined+round((voices['parallel-combined']['duration_s']+.5)*60)
assert 0 <= a.start_frame < combined < end_frame <= meta['frames']
intro=next((b['frame'] for b in meta['beats'] if b['action']=='Parallel session clicked'),a.start_frame)
assert intro + round(voices['parallel-intro']['duration_s']*60) <= combined, 'Finish the Parallel introduction before the combined handoff'
source_range=[a.start_frame,end_frame]
meta['beats']=[{**b,'frame':b['frame']-a.start_frame,'seconds':(b['frame']-a.start_frame)/60} for b in meta['beats'] if a.start_frame<=b['frame']<end_frame]
systemone=json.loads((root/'systemone-capture.json').read_text());start=systemone['start']+systemone['duration'];duration=(end_frame-a.start_frame)/60
# Trim setup and the long review outro; every retained source frame stays at 1x.
subprocess.run(['ffmpeg','-v','error','-y','-i',str(take/'footage.mp4'),'-vf',f'trim=start_frame={a.start_frame}:end_frame={end_frame},setpts=PTS-STARTPTS','-an','-c:v','libx264','-preset','veryfast','-crf','15','-pix_fmt','yuv420p','-movflags','+faststart',str(root/'assets/parallel-footage.mp4')],check=True)
source=(root/'index.html').read_text()
source=re.sub(r'\s*<!-- parallel-chapter:start -->.*?<!-- parallel-chapter:end -->','',source,flags=re.S)
source=re.sub(r'\s*// parallel-stage:start.*?// parallel-stage:end','',source,flags=re.S)
source=re.sub(r'(data-composition-id="main"[^>]*data-duration=")([\d.]+)',lambda m:m[1]+f'{max(float(m[2]),start+duration):.6f}',source,count=1)  # Watcher, appended last, sets the exact total
caption='Parallel node: wait until all agents finish'
block=f'''    <!-- parallel-chapter:start -->
    <div id="parallel-window" style="--footage-scale:0.56;position:absolute;left:288px;top:56px;width:1344px;height:840px;border-radius:20px;overflow:hidden;background:#4a4d54;box-shadow:0 24px 70px #080a1080,0 0 0 1px #73798350;opacity:0">
      <video id="parallel-footage" class="clip footage" src="assets/parallel-footage.mp4" muted playsinline data-start="{start:.6f}" data-duration="{duration:.6f}" data-track-index="0"></video>
      <div id="parallel-traffic" class="clip" data-start="{start:.6f}" data-duration="{duration:.6f}" data-track-index="1" style="position:absolute;top:calc(14px * var(--footage-scale));left:calc(20px * var(--footage-scale));display:flex;gap:calc(10px * var(--footage-scale));height:calc(16px * var(--footage-scale));z-index:2">
        <span class="light close" style="width:calc(16px * var(--footage-scale));height:100%"></span><span class="light minimize" style="width:calc(16px * var(--footage-scale));height:100%"></span><span class="light maximize" style="width:calc(16px * var(--footage-scale));height:100%"></span>
      </div>
    </div>
    <p id="parallel-subtitle" class="clip subtitles" data-start="{start:.6f}" data-duration="{duration:.6f}" data-track-index="2" data-track-kind="captions">{html.escape(caption)}</p>
    <!-- parallel-chapter:end -->'''
source=source.replace('    <!-- systemone-chapter:end -->','    <!-- systemone-chapter:end -->\n'+block)
source=source.replace('    // systemone-stage:end','    // systemone-stage:end\n    // parallel-stage:start\n'+f'    window.__timelines["main"].set("#parallel-window", {{ opacity: 1 }}, {start:.6f});\n'+'    // parallel-stage:end')
(root/'index.html').write_text(source)
(root/'parallel-capture.json').write_text(json.dumps({'take':str(a.take),'continuous_workspace':meta.get('continuous_workspace'),'session_navigation':meta.get('session_navigation'),'workspace_source_frames':meta.get('source_frames'),'source_frames':source_range,'playback_rate':1.0,'wire_styles':{'turn_completed':'solid','combined':'solid'},'start':start,'duration':duration,'subtitle':caption,'window':{'x':288,'y':56,'width':1344,'height':840,'source_width':2400,'source_height':1500},'traffic_lights_source':{'x':20,'y':14,'width':68,'height':16},'beats':meta['beats'],'failures':meta['failures']},indent=2)+'\n')
print(f'Parallel {duration:.2f}s, starts {start:.2f}s; total {start+duration:.2f}s')
from narration import place_chapter
place_chapter(root, 'parallel')
from presentation import apply
apply(root)
