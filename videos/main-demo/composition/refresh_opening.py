#!/usr/bin/env python3
"""Refresh the opening and automation captions, copying other accepted WebM scenes."""
import json
from pathlib import Path
import shutil
import subprocess

from narration import audio_inputs
from presentation import render_inputs
from render_navigation import codec, join, probe, run
from render_systemone import frame_hash
from refresh_nodes import packets

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
OUT = REPO / 'videos/artifacts/main-demo'
WORK = ROOT / '.hyperframes/opening-edit'


def main():
    old = json.loads((WORK / 'capture.json').read_text())
    old_routing = json.loads((WORK / 'systemone-capture.json').read_text())
    current = json.loads((ROOT / 'capture.json').read_text())
    routing = json.loads((ROOT / 'systemone-capture.json').read_text())
    source = WORK / 'original.webm'
    old_total = round((old_routing['start'] + old_routing['duration']) * 60)
    total = round((routing['start'] + routing['duration']) * 60)
    delta = round((current['timeline_duration'] - old['timeline_duration']) * 60)
    assert total - old_total == delta
    old_boundary = next(b['frame'] for b in old['beats'] if b['action'] == 'Select the Filetree session')
    new_boundary = next(b['frame'] for b in current['beats'] if b['action'] == 'Select the Filetree session')
    assert new_boundary - old_boundary == delta
    # Use the next existing keyframe, so the entire later film can be copied
    # without decoding/re-encoding even the final GOP or the Chromium scenes.
    stream = probe(source)
    raw = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_packets', '-show_entries', 'packet=pts_time,flags', '-of', 'json', str(source)]))['packets']
    origin = float(stream.get('start_time', 0))
    keys = [round((float(p['pts_time']) - origin) * 60) for p in raw if 'K' in p['flags']]
    boundary = next(k for k in keys if k >= old_boundary)
    prefix_frames = boundary + delta
    assert all(cut['start_frame'] >= prefix_frames for cut in current['cuts'])
    plate = ROOT.parent / 'assets/fixtures/castle-composite'
    inputs, overlays, last = render_inputs(ROOT, 4, 0, prefix_frames / 60, allow_tail_overlap=True)
    graph = ('[0:v]scale=1344:840:flags=lanczos,format=rgba[s];[s][2:v]alphamerge[w];'
             '[1:v][w]overlay=288:112:shortest=1[b];[b][3:v]overlay=299:132[film];' + overlays)
    prefix = WORK / 'opening.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', ROOT / 'assets/footage.mp4',
         '-loop', '1', '-framerate', '60', '-i', plate / 'plate.png',
         '-loop', '1', '-framerate', '60', '-i', plate / 'mask.png', '-i', plate / 'traffic.png',
         *inputs, '-filter_complex', graph, '-map', f'[{last}]', '-frames:v', prefix_frames,
         '-an', *codec('webm'), '-pix_fmt', 'yuv420p', '-progress', WORK / 'opening.progress', prefix])
    assert packets(prefix) == prefix_frames
    voices = json.loads((ROOT / 'demo-narration-cues.json').read_text())['cues']
    automation = [v for v in voices if v['id'].startswith('chromium-automation')]
    assert len(automation) == 3
    first = min(v['start'] for v in automation) * 60 - delta
    last_frame = max(v['end'] for v in automation) * 60 - delta
    auto_start = max(k for k in keys if k <= first)
    auto_end = next(k for k in keys if k >= last_frame)
    assert boundary < auto_start < auto_end < old_total
    old_voices = json.loads((WORK / 'demo-narration-cues.json').read_text())['cues']
    assert not any(v['start'] < auto_end / 60 and v['end'] > auto_start / 60 for v in old_voices), 'Use a caption-free source span'
    text_inputs, text_filters, text_last = render_inputs(ROOT, 1,
        (auto_start + delta) / 60, (auto_end - auto_start) / 60,
        voice_ids={v['id'] for v in automation})
    captioned = WORK / 'automation.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-ss', auto_start / 60, '-i', source,
         *text_inputs, '-filter_complex', '[0:v]setpts=PTS-STARTPTS[film];' + text_filters,
         '-map', f'[{text_last}]', '-frames:v', auto_end - auto_start, '-an',
         *codec('webm'), '-pix_fmt', 'yuv420p', '-progress', WORK / 'automation.progress', captioned])
    assert packets(captioned) == auto_end - auto_start

    def copy_span(start, end, name):
        target = WORK / f'{name}.webm'
        run(['ffmpeg', '-v', 'error', '-y', '-i', source, '-ss', max(0, start / 60 - .5 / 60),
             '-map', '0:v:0', '-frames:v', end - start, '-an', '-c:v', 'copy',
             '-avoid_negative_ts', 'make_zero', target])
        assert packets(target) == end - start
        return target, end - start

    parts = [(prefix, prefix_frames), copy_span(boundary, auto_start, 'retained-middle'),
             (captioned, auto_end - auto_start), copy_span(auto_end, old_total, 'retained-ending')]
    assert sum(n for _, n in parts) == total
    joined = WORK / 'joined.webm'
    join(parts, joined)
    audio, mix = audio_inputs(ROOT, voices, total / 60)
    pending = WORK / 'final.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', joined, *audio, '-filter_complex', mix,
         '-map', '0:v:0', '-map', '[voice]', '-c:v', 'copy', '-c:a', 'libopus',
         '-b:a', '128k', '-ac', '2', '-ar', '48000', '-t', total / 60, pending])
    assert int(probe(pending, count=True)['nb_read_frames']) == total
    run(['ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin', '-i', pending,
         '-vn', '-f', 'null', '-'])
    samples = [40, 100, 200, 300, 380]
    for at in samples:
        assert frame_hash(source, at) == frame_hash(pending, at + delta / 60), at
    target = OUT / 'main-demo.webm'
    pending.replace(target)
    proof = {'frames': total, 'duration': total / 60, 'reencoded_prefix_frames': prefix_frames,
             'automation_caption_frames': auto_end - auto_start,
             'copied_frames': old_total - boundary - (auto_end - auto_start), 'tail_shift_frames': delta,
             'unchanged_tail_samples': samples, 'full_audio_decode': 'passed'}
    report = {'frames': total, 'output_bytes': target.stat().st_size,
              'video': {'codec': 'vp9', 'crf': 28, 'cpu_used': 3,
                        'assembly': 'Status before stashing and automation narration; other scenes copied'},
              'systemone_start_frame': round(routing['start'] * 60), 'verification': proof}
    (OUT / 'main-demo.webm.json').write_text(json.dumps(report, indent=2) + '\n')
    (OUT / 'main-demo.castle.json').write_text(json.dumps({
        'take': current['take'], 'desktop_frames': round(current['timeline_duration'] * 60),
        'cuts': current['cuts'], 'chapters': current['chapters'],
        'result': probe(target), 'systemone': routing}, indent=2) + '\n')
    for ext in ['srt', 'vtt']:
        shutil.copyfile(ROOT / f'demo-subtitles.{ext}', OUT / f'main-demo.{ext}')
    (WORK / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof, indent=2), flush=True)


if __name__ == '__main__':
    main()
