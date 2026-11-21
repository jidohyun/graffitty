#!/usr/bin/env python3
"""Add the filetree keycaps to the delivery, copying all unaffected video/audio."""
import json
from pathlib import Path
import shutil
import subprocess

import shortcuts

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parents[1]/'artifacts/main-demo'
WORK = ROOT/'.hyperframes/filetree-shortcut'


def run(args):
    subprocess.run([str(value) for value in args], check=True)


def probe(path, count=False):
    return json.loads(subprocess.check_output([
        'ffprobe','-v','error',*(['-count_frames'] if count else []),
        '-select_streams','v:0','-show_streams','-of','json',str(path)]))['streams'][0]


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    cues = [c for c in json.loads((ROOT/'presentation.json').read_text())['shortcuts']
            if c['combo'] in ['2', '2+minus']]
    assert cues, 'Prepare presentation.py first'
    first, last = min(c['start_frame'] for c in cues), max(c['end_frame'] for c in cues)
    expected = int(probe(OUT/'main-demo.mp4')['nb_frames'])
    results = {}
    for suffix in ['mp4', 'webm']:
        target = OUT/f'main-demo.{suffix}'
        source = WORK/f'original.{suffix}'
        # Keep the unmodified render for repeatable edits without stacked overlays.
        if not source.exists():
            shutil.copy2(target, source)
        stream = probe(source)
        packets = json.loads(subprocess.check_output([
            'ffprobe','-v','error','-select_streams','v:0','-show_packets',
            '-show_entries','packet=pts_time,flags','-of','json',str(source)]))['packets']
        origin = float(stream.get('start_time', 0))
        keyframes = [round((float(p['pts_time'])-origin)*60) for p in packets if 'K' in p['flags']]
        start, end = max(n for n in keyframes if n <= first), min(n for n in keyframes if n >= last)
        shifted = [{**c, 'start':c['start']-start/60,
                    'start_frame':c['start_frame']-start, 'end_frame':c['end_frame']-start} for c in cues]
        inputs, filters, final = shortcuts.render_inputs(ROOT, shifted, 1, '0:v')
        middle = WORK/f'middle.{suffix}'
        codec = (['-c:v','libx264','-preset','veryfast','-crf','16','-bf','0',
                  '-video_track_timescale','15360'] if suffix == 'mp4' else
                 ['-c:v','libvpx-vp9','-b:v','0','-crf','28','-deadline','good',
                  '-cpu-used','3','-row-mt','1','-tile-columns','2','-threads','8','-g','240'])
        run(['ffmpeg','-v','error','-y','-ss',start/60,'-i',WORK/'original.mp4',
             *inputs,'-filter_complex',';'.join(filters),'-map',f'[{final}]',
             '-frames:v',end-start,'-an','-r','60',*codec,'-pix_fmt','yuv420p',middle])
        prefix, tail = WORK/f'prefix.{suffix}', WORK/f'tail.{suffix}'
        run(['ffmpeg','-v','error','-y','-i',source,'-map','0:v:0',
             '-frames:v',start,'-an','-c:v','copy',prefix])
        run(['ffmpeg','-v','error','-y','-i',source,'-ss',end/60-.5/60,
             '-map','0:v:0','-an','-c:v','copy','-avoid_negative_ts','make_zero',tail])
        playlist = WORK/f'concat-{suffix}.txt'
        playlist.write_text(f"file '{prefix.name}'\nduration {start/60:.9f}\n"
                            f"file '{middle.name}'\nduration {(end-start)/60:.9f}\n"
                            f"file '{tail.name}'\n")
        pending = WORK/f'updated.{suffix}'
        run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',playlist,
             '-i',source,'-map','0:v:0','-map','1:a:0','-c','copy',
             *(['-movflags','+faststart'] if suffix=='mp4' else []),pending])
        result = probe(pending, count=True)
        assert int(result['nb_read_frames']) == expected, (suffix, result['nb_read_frames'], expected)
        assert (result['width'],result['height'],result['r_frame_rate']) == (1920,1080,'60/1')
        framing = ['-fflags','+noparse+nofillin'] if suffix=='webm' else []
        run(['ffmpeg','-v','error','-xerror',*framing,'-i',pending,'-vn','-f','null','-'])
        pending.replace(target)
        results[suffix] = {'changed_start_frame':start,'changed_end_frame':end,
                           'frames':expected,'audio':'original stream copied',
                           'unchanged_video':'prefix and tail stream copied'}
        print(f'{suffix}: updated {start/60:.3f}–{end/60:.3f}s; {expected} frames verified',flush=True)
    report_path = OUT/'main-demo.webm.json'
    report = json.loads(report_path.read_text())
    report.update(source_bytes=(OUT/'main-demo.mp4').stat().st_size,
                  output_bytes=(OUT/'main-demo.webm').stat().st_size,
                  filetree_shortcut_refresh=results)
    report_path.write_text(json.dumps(report,indent=2)+'\n')
    (WORK/'verification.json').write_text(json.dumps(results,indent=2)+'\n')


if __name__ == '__main__':
    main()
