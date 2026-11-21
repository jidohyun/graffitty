#!/usr/bin/env python3
"""Frame a Castle desktop take with the existing captions; append finished demos."""
import argparse,json,shutil,subprocess
from pathlib import Path
from edit_decisions import timeline_cuts,edited_frame
from narration import cues, mux
from presentation import render_inputs
p=argparse.ArgumentParser();p.add_argument('take',type=Path);p.add_argument('--output',type=Path);p.add_argument('--native-scene',type=Path,help='Verified HyperFrames render of the native-window scene');a=p.parse_args()
root=Path(__file__).resolve().parents[3]
a.take=a.take.resolve();plate=root/'videos/main-demo/assets/fixtures/castle-composite'
meta=json.loads((a.take/'capture.json').read_text());assert not meta['failures'],meta['failures']
assert meta.get('castle_surfaces') == ['LiveTerminalWall1', 'Royal Palace', 'National War Museum', 'LiveTerminalWall3', 'LiveTerminalWall5'], 'Capture must verify a distinct Castle area for every prepared session'
cut=timeline_cuts(meta,a.take)
chapters=[{'start':0,'text':'terminal with tiling windows'}]+[{'start':edited_frame(b['frame'],cut)/60,'text':b['action'].removeprefix('Chapter: ')} for b in meta['beats'] if b['action'].startswith('Chapter: ')]
assert len(chapters)==11 and [c['text'] for c in chapters[-5:]]==['Chromium: markdown preview','Chromium: visual explanations','Chromium: automation','tabs: status at a glance','command line: fuzzy finder built in'],chapters
frames=edited_frame(meta['frames'],cut);duration=frames/60
outdir=root/'videos/artifacts/main-demo';outdir.mkdir(parents=True,exist_ok=True)
desktop=outdir/'castle-desktop.mp4'
encode=['-an','-r','60','-c:v','libx264','-preset','veryfast','-crf','16','-pix_fmt','yuv420p','-bf','0','-video_track_timescale','15360','-movflags','+faststart']
def run(cmd):subprocess.run([str(x) for x in cmd],check=True)
def probe(path):return json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=nb_frames,width,height,r_frame_rate','-of','json',str(path)]))['streams'][0]
cmd=['ffmpeg','-v','error','-y','-i',a.take/'footage.mp4','-loop','1','-framerate','60','-i',plate/'plate.png','-loop','1','-framerate','60','-i',plate/'mask.png','-i',plate/'traffic.png']
native=meta.get('native_window')
if native:
 if not a.native_scene or not a.native_scene.is_file():
  raise SystemExit('Render composition/native-scene first, then pass --native-scene; the native reveal must not be omitted')
 native_probe=probe(a.native_scene)
 assert (native_probe['width'],native_probe['height'],native_probe['r_frame_rate'],int(native_probe['nb_frames']))==(1920,1080,'60/1',native['end_frame']-native['start_frame'])
 cmd+=['-i',a.native_scene]
selection='*'.join(f"not(between(n,{span['start_frame']},{span['end_frame']-1}))" for span in cut)
f=[f"[0:v]select='{selection}',setpts=N/(60*TB),scale=1344:840:flags=lanczos,format=rgba[s]",'[s][2:v]alphamerge[w]','[1:v][w]overlay=288:112:shortest=1[b]','[b][3:v]overlay=299:132[c0]']
result_label='c0'
if native:
 start=edited_frame(native['start_frame'],cut)/60;end=edited_frame(native['end_frame'],cut)/60
 f.append(f'[4:v]setpts=PTS-STARTPTS+{start}/TB[native]')
 f.append(f"[{result_label}][native]overlay=0:0:enable='gte(t,{start})*lt(t,{end})':eof_action=pass[with_native]")
 result_label='with_native'
cmd+=['-filter_complex',';'.join(f),'-map',f'[{result_label}]','-frames:v',str(frames),*encode,desktop];run(cmd)
android=root/'videos/artifacts/android-demo/android-oneui.mp4'
parallel=root/'videos/artifacts/main-demo/parallel-demo.mp4'
output=a.output.resolve() if a.output else outdir/'main-demo.mp4';temp=output.with_suffix('.next.mp4')
output.parent.mkdir(parents=True,exist_ok=True)
composition=Path(__file__).resolve().parent
text_inputs,text_filters,text_output=render_inputs(composition)
# Finished phone/system UI and Parallel footage retain their pixels. Remove
# their baked bottom labels and move the complete picture down 56 pixels.
shift="crop=1920:900:0:0,pad=1920:1080:0:56:color=0x15181f"
assemble=f"[1:v]{shift}[phone];[2:v]{shift}[parallel];[0:v][phone][parallel]concat=n=3:v=1:a=0[film];{text_filters}"
total_frames=frames+int(probe(android)['nb_frames'])+int(probe(parallel)['nb_frames'])
run(['ffmpeg','-v','error','-y','-i',desktop,'-i',android,'-i',parallel,*text_inputs,'-filter_complex',assemble,'-map',f'[{text_output}]','-frames:v',str(total_frames),*encode,temp])
result=probe(temp);assert result['r_frame_rate']=='60/1';assert int(result['nb_frames'])==frames+int(probe(android)['nb_frames'])+int(probe(parallel)['nb_frames'])
run(['ffmpeg','-v','error','-i',temp,'-f','null','-']);temp.replace(output)
placed=cues(composition,meta,lambda t:edited_frame(round(t*60),cut)/60) if native else []
mux(composition,output,placed,int(result['nb_frames'])/60)
for suffix in ['srt','vtt']:
 shutil.copyfile(composition/f'demo-subtitles.{suffix}',output.with_suffix('.'+suffix))
# Extract the newly titled/captioned desktop from the assembled film.
run(['ffmpeg','-v','error','-y','-i',output,'-map','0:v:0','-map','0:a:0',
     '-t',str(duration),'-c','copy','-movflags','+faststart',desktop])
if placed:
 chromium_start=next(chapter['start'] for chapter in chapters if chapter['text']=='Chromium: markdown preview')
 chromium_frames=frames-round(chromium_start*60)
 run(['ffmpeg','-v','error','-y','-ss',str(chromium_start),'-i',desktop,
      '-map','0:v:0','-map','0:a:0','-frames:v',str(chromium_frames),
      '-r','60','-c:v','libx264','-preset','fast','-crf','16','-pix_fmt','yuv420p',
      '-c:a','aac','-b:a','192k','-t',str(chromium_frames/60),'-movflags','+faststart',outdir/'chromium-demo.mp4'])
output.with_suffix('.castle.json').write_text(json.dumps({'take':str(a.take.relative_to(root)),'alpha':.5,'desktop_frames':frames,'cuts':cut,'chapters':chapters,'result':result},indent=2)+'\n')
if (composition/'systemone-capture.json').exists():
 run(['python3',composition/'render_systemone.py','--append','--film',output])
print(output)
