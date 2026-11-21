#!/usr/bin/env python3
"""Render the final node chapter, then append without re-encoding earlier footage."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw
from narration import audio_inputs, mux
from presentation import render_inputs


def run(args):
    subprocess.run([str(x) for x in args], check=True)


def probe(path):
    return json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
        '-show_entries','stream=width,height,r_frame_rate,nb_frames','-of','json',str(path)]))['streams'][0]


def frame_hash(path, at):
    # Sample the requested 60 FPS frame just before its timestamp. WebM's
    # millisecond rounding can otherwise select the next frame after remuxing.
    at = max(0, (round(at * 60) - .5) / 60)
    return subprocess.check_output(['ffmpeg','-v','error','-ss',str(at),'-i',str(path),
        '-map','0:v:0','-frames:v','1','-pix_fmt','rgb24','-f','hash','-hash','sha256','-']).decode().strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--append', action='store_true')
    parser.add_argument('--film', type=Path, help='Existing full MP4 to append to')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    artifacts = root.parents[1]/'artifacts/main-demo'
    plate = root.parent/'assets/fixtures/castle-composite'
    meta = json.loads((root/'systemone-capture.json').read_text())
    offset, duration = meta['start'], meta['duration']
    frames = round(duration*60)
    output = artifacts/'systemone-demo.mp4'
    cache = root/'.hyperframes/systemone-render'
    cache.mkdir(parents=True,exist_ok=True)
    # Same source coordinates, colors and 0.56 scale as the HTML chapter.
    image = Image.new('RGBA',(69*8,17*8))
    draw = ImageDraw.Draw(image)
    for i, color in enumerate(['#ec6765','#f2ca44','#65c466']):
        x = i*26*8
        draw.ellipse((x,0,x+16*8,16*8),fill=color)
    image.resize((39,10),Image.Resampling.LANCZOS).save(cache/'traffic.png')
    text_inputs, text_filters, text_output = render_inputs(root,4,offset,duration)
    filters = ('[0:v]scale=1344:840:flags=lanczos,format=rgba[s];[s][2:v]alphamerge[w];'
               '[1:v][w]overlay=288:112:shortest=1[b];[b][3:v]overlay=299:120[film];'+text_filters)
    temporary = output.with_suffix('.pending.mp4')
    run(['ffmpeg','-v','error','-y','-i',root/'assets/systemone-footage.mp4',
         '-loop','1','-framerate','60','-i',plate/'plate.png',
         '-loop','1','-framerate','60','-i',plate/'mask.png','-i',cache/'traffic.png',*text_inputs,
         '-filter_complex',filters,'-map',f'[{text_output}]','-an','-frames:v',frames,
         '-r','60','-c:v','libx264','-preset','veryfast','-crf','16','-pix_fmt','yuv420p',
         '-profile:v','high','-level','5','-bf','0','-video_track_timescale','15360','-movflags','+faststart',temporary])
    info = probe(temporary)
    assert (info['width'],info['height'],info['r_frame_rate'],int(info['nb_frames'])) == (1920,1080,'60/1',frames)
    all_cues = json.loads((root/'demo-narration-cues.json').read_text())['cues']
    cues = [{**c,'start':c['start']-offset,'end':c['end']-offset} for c in all_cues if c['id'].startswith('systemone-')]
    inputs, mix = audio_inputs(root,cues,duration,offset)
    run(['ffmpeg','-v','error','-y','-i',temporary,*inputs,'-filter_complex',mix,
         '-map','0:v:0','-map','[voice]','-c:v','copy','-c:a','aac','-b:a','192k','-ar','48000','-movflags','+faststart',output])
    temporary.unlink()
    if args.append:
        film = args.film.resolve() if args.film else artifacts/'main-demo.mp4'
        source_frames = int(probe(film)['nb_frames'])
        if source_frames != round(offset*60):
            prior = json.loads(film.with_suffix('.castle.json').read_text()).get('systemone',{})
            assert abs(prior.get('start',-1)-offset)<1/120 and source_frames == round((offset+prior['duration'])*60), 'Full-film timing changed; re-append the chapter metadata first'
        proof_times = [0, round(offset/2,3), offset-.5]
        before = [frame_hash(film,at) for at in proof_times]
        with tempfile.TemporaryDirectory(prefix='systemone-append-') as directory:
            directory = Path(directory)
            prefix = directory/'prefix.mp4'
            # A repeat render replaces this chapter instead of appending it twice.
            run(['ffmpeg','-v','error','-y','-i',film,'-map','0:v:0','-frames:v',round(offset*60),'-an','-c:v','copy',prefix])
            assert int(probe(prefix)['nb_frames']) == round(offset*60)
            playlist = directory/'concat.txt'
            playlist.write_text(f"file '{prefix}'\nfile '{output}'\n")
            run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',playlist,
                 '-map','0:v:0','-an','-c:v','copy','-movflags','+faststart',temporary])
            assert int(probe(temporary)['nb_frames']) == round((offset+duration)*60)
            mux(root,temporary,all_cues,offset+duration)
            run(['ffmpeg','-v','error','-xerror','-i',temporary,'-f','null','-'])
            assert [frame_hash(temporary,at) for at in proof_times] == before, 'Earlier film frames changed'
            (cache/'verification.json').write_text(json.dumps({'prefix_samples':dict(zip(proof_times,before)),
                'frames':round((offset+duration)*60),'new_segment_frames':frames,'decode':'complete'},indent=2)+'\n')
            temporary.replace(film)
        for extension in ['srt','vtt']:
            shutil.copyfile(root/f'demo-subtitles.{extension}',film.with_suffix('.'+extension))
        sidecar = film.with_suffix('.castle.json')
        if sidecar.exists():
            report = json.loads(sidecar.read_text())
            report.update(result=probe(film), systemone={'start':offset,'duration':duration,'take':meta['take']})
            sidecar.write_text(json.dumps(report,indent=2)+'\n')
    print(output)


if __name__ == '__main__': main()
