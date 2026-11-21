#!/usr/bin/env python3
"""Refresh narrated node chapters directly to WebM, preserving desktop pixels."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from PIL import Image, ImageDraw
from narration import audio_inputs
from presentation import render_inputs
from render_navigation import codec, join, probe, run
from render_systemone import frame_hash

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parents[1] / 'artifacts/main-demo'
WORK = ROOT / '.hyperframes/node-refresh'


def packets(path):
    return int(json.loads(subprocess.check_output(['ffprobe', '-v', 'error',
        '-select_streams', 'v:0', '-count_packets', '-show_entries',
        'stream=nb_read_packets', '-of', 'json', str(path)]))['streams'][0]['nb_read_packets'])


def render_chapter(kind):
    meta = json.loads((ROOT / f'{kind}-capture.json').read_text())
    frames = round(meta['duration'] * 60)
    source = ROOT / ('assets/android-oneui.mp4' if kind == 'android' else f'assets/{kind}-footage.mp4')
    presentation = json.loads((ROOT / 'presentation.json').read_text())
    cues = {name: [c for c in presentation.get(name, [])
                   if meta['start'] <= c['start'] < meta['start'] + meta['duration'] - 1e-6]
            for name in ['chapters', 'subtitles', 'underlines']}
    manager_source = ROOT / meta['manager']['source'] if meta.get('manager') else None
    manager_signature = [manager_source.stat().st_size, manager_source.stat().st_mtime_ns] if manager_source else None
    signature = hashlib.sha256(json.dumps([source.stat().st_size, source.stat().st_mtime_ns, manager_signature,
        meta, cues, Path(__file__).read_text(), (ROOT / "payload_underlines.py").read_text(), (ROOT / "presentation.py").read_text()], sort_keys=True).encode()).hexdigest()
    target, stamp = WORK / f'{kind}.webm', WORK / f'{kind}.signature'
    if target.exists() and stamp.exists() and stamp.read_text() == signature and packets(target) == frames:
        print(f'Reusing rendered {kind} chapter', flush=True)
        return target, frames
    if kind == 'android':
        text_inputs, text_filters, last = render_inputs(ROOT, 1, meta['start'], meta['duration'])
        # Match the composition's phone wrapper: crop the old caption strip,
        # shift the complete phone down 56 px, and add the current narration.
        inputs = ['-i', source]
        if meta.get('manager'):
            manager = meta['manager']
            inputs += ['-i', ROOT / manager['source']]
            text_inputs, text_filters, last = render_inputs(ROOT, 2, meta['start'], meta['duration'])
            filters = (f'[1:v]trim=end_frame={manager["frames"]},setpts=PTS-STARTPTS[intro];'
                       '[0:v]trim=start_frame=60,setpts=PTS-STARTPTS[demo];'
                       '[intro][demo]concat=n=2:v=1:a=0[phone];'
                       '[phone]crop=1920:900:0:0,pad=1920:1080:0:56:color=0x15181f,setsar=1[film];')
        else:
            filters = '[0:v]crop=1920:900:0:0,pad=1920:1080:0:56:color=0x15181f,setsar=1[film];'
    else:
        plate = ROOT.parent / 'assets/fixtures/castle-composite'
        text_inputs, text_filters, last = render_inputs(ROOT, 4, meta['start'], meta['duration'])
        inputs = ['-i', source, '-loop', '1', '-framerate', '60', '-i', plate / 'plate.png',
                  '-loop', '1', '-framerate', '60', '-i', plate / 'mask.png', '-i', WORK / 'traffic.png']
        filters = ('[0:v]scale=1344:840:flags=lanczos,format=rgba[s];[s][2:v]alphamerge[w];'
                   '[1:v][w]overlay=288:112:shortest=1[b];[b][3:v]overlay=299:120[film];')
    pending = target.with_suffix('.pending.webm')
    run(['ffmpeg', '-v', 'error', '-y', *inputs, *text_inputs, '-filter_complex', filters + text_filters,
         '-map', f'[{last}]', '-frames:v', frames, '-an', *codec('webm'), '-pix_fmt', 'yuv420p',
         '-progress', WORK / f'{kind}.progress', pending])
    assert packets(pending) == frames
    pending.replace(target)
    stamp.write_text(signature)
    print(f'Rendered {kind}: {frames / 60:.2f}s directly to WebM', flush=True)
    return target, frames


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    lights = Image.new('RGBA', (69 * 8, 17 * 8))
    draw = ImageDraw.Draw(lights)
    for i, color in enumerate(['#ec6765', '#f2ca44', '#65c466']):
        x = i * 26 * 8
        draw.ellipse((x, 0, x + 16 * 8, 16 * 8), fill=color)
    lights.resize((39, 10), Image.Resampling.LANCZOS).save(WORK / 'traffic.png')


# The graph chapters follow Android in this order.
NODES = ['systemone', 'parallel', 'protocol', 'watcher']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    chapter = parser.add_mutually_exclusive_group()
    chapter.add_argument('--nodes-only', action='store_true', help='Copy desktop and Android; replace the four prepared node sessions')
    chapter.add_argument('--android-only', action='store_true', help='Copy the accepted desktop and later node chapters')
    parser.add_argument('--baseline', type=Path, help='Frozen capture metadata from before the Android edit')
    args = parser.parse_args()
    if args.android_only and not args.baseline:
        parser.error('An Android refresh requires --baseline with the previous chapter timing')
    prepare()
    film = OUT / 'main-demo.webm'
    desktop = json.loads((ROOT / 'capture.json').read_text())
    nodes = {kind: json.loads((ROOT / f'{kind}-capture.json').read_text()) for kind in NODES}
    routing, watcher = nodes['systemone'], nodes['watcher']
    prefix_frames = round(desktop['timeline_duration'] * 60)
    if args.nodes_only:
        prefix_frames = round(nodes[NODES[0]]['start'] * 60)
    total = round((watcher['start'] + watcher['duration']) * 60)
    sample_times = [7, 90, 150, desktop['timeline_duration'] - 1]
    sample_times = [at for at in sample_times if at < prefix_frames / 60]
    before = [frame_hash(film, at) for at in sample_times]
    suffix = None
    suffix_samples = []
    if args.android_only:
        old = {kind: json.loads((args.baseline / f'{kind}-capture.json').read_text()) for kind in NODES}
        for kind in NODES:
            assert round(nodes[kind]['duration'] * 60) == round(old[kind]['duration'] * 60), f'Retained {kind} length must remain unchanged'
        first_old, first_new = old[NODES[0]]['start'], nodes[NODES[0]]['start']
        suffix_start = round(first_old * 60)
        suffix_frames = round(sum(nodes[kind]['duration'] for kind in NODES) * 60)
        assert packets(film) == suffix_start + suffix_frames
        # Accepted chapters begin with keyframes, so their complete VP9 streams
        # can move on the timeline without re-encoding their already approved pixels.
        stream = probe(film)
        # WebM seeks can land on an earlier cluster even when the requested
        # chapter starts on a keyframe. Inspect its exact frame index instead.
        first = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
            '-show_packets', '-show_entries', 'packet=pts_time,flags', '-of', 'json', str(film)]))['packets'][suffix_start]
        assert 'K' in first['flags'] and abs(float(first['pts_time']) - float(stream.get('start_time', 0)) - suffix_start / 60) < 1 / 120
        suffix = WORK / 'accepted-later-chapters.webm'
        run(['ffmpeg', '-v', 'error', '-y', '-i', film, '-ss', suffix_start / 60 - .5 / 60,
             '-map', '0:v:0', '-frames:v', suffix_frames, '-an', '-c:v', 'copy',
             '-avoid_negative_ts', 'make_zero', suffix])
        assert packets(suffix) == suffix_frames
        offsets = [2, 20, nodes[NODES[0]]['duration'] + 3, suffix_frames / 60 - 2]
        for offset in offsets:
            suffix_samples.append((first_old + offset, first_new + offset, frame_hash(film, first_old + offset)))
    prefix = WORK / 'desktop.webm'
    # The retained desktop ends on the existing chapter boundary. Its VP9
    # packets are copied exactly; no Chromium capture or video encoding.
    run(['ffmpeg', '-v', 'error', '-y', '-i', film, '-map', '0:v:0', '-frames:v', prefix_frames,
         '-an', '-c:v', 'copy', prefix])
    assert packets(prefix) == prefix_frames
    parts = [(prefix, prefix_frames)]
    kinds = NODES if args.nodes_only else ['android'] if args.android_only else ['android', *NODES]
    for kind in kinds:
        parts.append(render_chapter(kind))
    if suffix:
        parts.append((suffix, suffix_frames))
    assert sum(frames for _, frames in parts) == total
    joined = WORK / 'joined.webm'
    join(parts, joined)
    placed = json.loads((ROOT / 'demo-narration-cues.json').read_text())['cues']
    inputs, mix = audio_inputs(ROOT, placed, total / 60)
    pending = WORK / 'final.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', joined, *inputs, '-filter_complex', mix,
         '-map', '0:v:0', '-map', '[voice]', '-c:v', 'copy',
         '-bsf:v', 'setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)',
         '-c:a', 'libopus', '-b:a', '128k', '-ac', '2', '-ar', '48000', pending])
    assert int(probe(pending, count=True)['nb_read_frames']) == total
    run(['ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin', '-i', pending,
         '-vn', '-f', 'null', '-'])
    assert [frame_hash(pending, at) for at in sample_times] == before, 'Retained desktop pixels changed'
    assert all(frame_hash(pending, at) == expected for _, at, expected in suffix_samples), 'Retained node chapter pixels changed'
    pending.replace(film)
    report = json.loads((OUT / 'main-demo.webm.json').read_text())
    report.update({'frames': total, 'output_bytes': film.stat().st_size,
              'video': {'codec': 'vp9', 'crf': 28, 'cpu_used': 3,
                        'assembly': 'Four Bistro node sessions refreshed; accepted desktop and Android copied' if args.nodes_only else 'Android refreshed; accepted desktop and later chapters copied' if args.android_only else 'Desktop copied; Android and node chapters refreshed'},
              'systemone_start_frame': round(routing['start'] * 60),
              'verification': {'unchanged_desktop_samples': sample_times,
                               'unchanged_later_chapter_samples': [[a, b] for a, b, _ in suffix_samples], 'full_video_frames': total,
                               'full_audio_decode': 'passed'}})
    (OUT / 'main-demo.webm.json').write_text(json.dumps(report, indent=2) + '\n')
    (OUT / 'main-demo.castle.json').write_text(json.dumps({
        'take': desktop['take'], 'desktop_frames': round(desktop['timeline_duration'] * 60), 'cuts': desktop['cuts'],
        'chapters': desktop['chapters'], 'result': probe(film), 'systemone': routing}, indent=2) + '\n')
    for ext in ['srt', 'vtt']:
        shutil.copyfile(ROOT / f'demo-subtitles.{ext}', OUT / f'main-demo.{ext}')
    (WORK / 'verification.json').write_text(json.dumps(report['verification'], indent=2) + '\n')
    print(f'Verified {total} frames, {total / 60:.2f}s; desktop unchanged: {film}', flush=True)


if __name__ == '__main__':
    main()
