#!/usr/bin/env python3
"""Render every current demo chapter directly to WebM from shared edit cues."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from edit_decisions import edited_frame, require_original_speed
from narration import audio_inputs
from presentation import render_inputs
import refresh_nodes
from render_navigation import codec, join, probe, run
from render_systemone import frame_hash
from verify_delivery import verify_timestamps

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
OUT = REPO / 'videos/artifacts/main-demo'
LATER = ['android', 'systemone', 'parallel', 'protocol', 'watcher']


def desktop(work, native_scene, start_frame=0):
    meta = json.loads((ROOT / 'capture.json').read_text())
    require_original_speed(meta)
    assert not meta['failures']
    frames = round(meta['timeline_duration'] * 60) - start_frame
    offset = start_frame / 60
    native = meta['native_window']
    assert refresh_nodes.packets(native_scene) == native['end_frame'] - native['start_frame'] + native.get('cursor_return_frames', 0)
    start = edited_frame(native['start_frame'], meta['cuts']) / 60 - offset
    end = edited_frame(native['end_frame'], meta['cuts']) / 60 - offset + native.get('cursor_return_frames', 0) / 60
    plate = ROOT.parent / 'assets/fixtures/castle-composite'
    search = meta.get('tabs_summary', {}).get('search', {}).get('recording')
    replacements = [json.loads(path.read_text()) for path in
                    [ROOT / 'filetree-transition.json', ROOT / 'markdown-transition.json']
                    if path.exists()]
    presentation = json.loads((ROOT / 'presentation.json').read_text())
    presentation = {key: [cue for cue in value if cue['start'] < meta['timeline_duration']]
                    if isinstance(value, list) else value for key, value in presentation.items()}
    sources = [REPO / meta['take'] / 'footage.mp4', native_scene,
               *(plate / name for name in ['plate.png', 'mask.png', 'traffic.png'])]
    sources.append(ROOT / 'assets/connecting-line-spotlight.png')
    if search: sources.append(ROOT / search['asset'])
    sources.extend(ROOT / replacement['source'] for replacement in replacements)
    signature = hashlib.sha256(json.dumps([meta, presentation, start_frame, replacements,
        [(str(p), p.stat().st_size, p.stat().st_mtime_ns) for p in sources],
        Path(__file__).read_text(), (ROOT / 'presentation.py').read_text()], sort_keys=True).encode()).hexdigest()
    target, stamp = work / 'desktop.webm', work / 'desktop.signature'
    if target.exists() and stamp.exists() and stamp.read_text() == signature and refresh_nodes.packets(target) == frames:
        print('Reusing rendered desktop chapter', flush=True)
        return target, frames
    inputs = ['-i', REPO / meta['take'] / 'footage.mp4',
              '-loop', '1', '-framerate', '60', '-i', plate / 'plate.png',
              '-loop', '1', '-framerate', '60', '-i', plate / 'mask.png',
              '-i', plate / 'traffic.png', '-i', native_scene]
    selection = '*'.join(f"not(between(n,{c['start_frame']},{c['end_frame']-1}))" for c in meta['cuts'])
    trim = f"select='{selection}'," if selection else ''
    graph = [f'[0:v]{trim}trim=start_frame={start_frame},setpts=N/(60*TB)[recorded]']
    picture = 'recorded'
    for index, replacement in enumerate(replacements):
        assert refresh_nodes.packets(ROOT / replacement['source']) == replacement['end_frame'] - replacement['start_frame']
        stream = inputs.count('-i')
        inputs += ['-i', ROOT / replacement['source']]
        at, until = replacement['start'] - offset, replacement['end_frame'] / 60 - offset
        graph += [f'[{stream}:v]setpts=PTS-STARTPTS+{at}/TB[replacement{index}]',
                  f"[{picture}][replacement{index}]overlay=0:0:enable='gte(t,{at})*lt(t,{until})':eof_action=pass[replaced{index}]"]
        picture = f'replaced{index}'
    graph += [f'[{picture}]scale=1344:840:flags=lanczos,format=rgba[s]',
             '[s][2:v]alphamerge[w]', '[1:v][w]overlay=288:112:shortest=1[b]',
             '[b][3:v]overlay=299:132[c]', f'[4:v]setpts=PTS-STARTPTS+{start}/TB[native]',
             f"[c][native]overlay=0:0:enable='gte(t,{start})*lt(t,{end})':eof_action=pass[picture]"]
    if search:
        stream = inputs.count('-i')
        inputs += ['-c:v', 'libvpx-vp9', '-i', ROOT / search['asset']]
        at, until = search['start'] - offset, search['start'] + search['duration'] - offset
        graph += [f'[{stream}:v]scale=1344:840:flags=lanczos,format=rgba,setpts=PTS-STARTPTS+{at}/TB[menu]',
                  f"[picture][menu]overlay=288:112:enable='gte(t,{at})*lt(t,{until})':eof_action=pass[film]"]
    else:
        graph.append('[picture]null[film]')
    text_inputs, text_filters, last = render_inputs(ROOT, inputs.count('-i'), offset, frames / 60)
    graph.append(text_filters)
    run(['ffmpeg', '-v', 'error', '-y', *inputs, *text_inputs,
         '-filter_complex', ';'.join(graph), '-map', f'[{last}]',
         '-frames:v', frames, '-an', *codec('webm'), '-pix_fmt', 'yuv420p',
         '-progress', work / 'desktop.progress', target])
    assert refresh_nodes.packets(target) == frames
    stamp.write_text(signature)
    return target, frames


def accepted_later(work, baseline, desktop_frames):
    """Copy the accepted mobile and node chapters' VP9 packets after a new desktop."""
    film = baseline / 'original.webm'
    start = round(json.loads((baseline / 'capture.json').read_text())['timeline_duration'] * 60)
    frames = 0
    for kind in LATER:
        before = json.loads((baseline / f'{kind}-capture.json').read_text())
        after = json.loads((ROOT / f'{kind}-capture.json').read_text())
        assert round(before['start'] * 60) - start == round(after['start'] * 60) - desktop_frames, kind
        assert round(before['duration'] * 60) == round(after['duration'] * 60), f'{kind} keeps its accepted length'
        frames += round(after['duration'] * 60)
    assert refresh_nodes.packets(film) == start + frames
    # Each accepted chapter was encoded separately, so the first one starts on a keyframe.
    first = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_packets', '-show_entries', 'packet=flags', '-of', 'json', str(film)]))['packets'][start]
    assert 'K' in first['flags'], 'The accepted Android chapter must start on a keyframe'
    target = work / 'accepted-later-chapters.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', film, '-ss', start / 60 - .5 / 60,
         '-map', '0:v:0', '-frames:v', frames, '-an', '-c:v', 'copy',
         '-avoid_negative_ts', 'make_zero', target])
    assert refresh_nodes.packets(target) == frames
    samples = [(start / 60 + offset, desktop_frames / 60 + offset) for offset in [2, 30, 70, frames / 60 - 2]]
    return (target, frames), [(old, new, frame_hash(film, old)) for old, new in samples]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-scene', required=True, type=Path)
    parser.add_argument('--work', type=Path, default=ROOT / '.hyperframes/full-refresh')
    parser.add_argument('--retain-later', type=Path, metavar='BASELINE',
                        help='Frozen revision directory; copy its accepted mobile and node chapters unchanged')
    args = parser.parse_args()
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    refresh_nodes.WORK = work / 'chapters'
    refresh_nodes.prepare()
    parts = [desktop(work, args.native_scene.resolve())]
    chapters = {}
    cursor = parts[0][1]
    for kind in LATER:
        meta = json.loads((ROOT / f'{kind}-capture.json').read_text())
        assert round(meta['start'] * 60) == cursor, kind
        chapters[kind] = meta
        if not args.retain_later:
            parts.append(refresh_nodes.render_chapter(kind))
        cursor += round(meta['duration'] * 60)
    samples = []
    if args.retain_later:
        later, samples = accepted_later(work, args.retain_later.resolve(), parts[0][1])
        parts.append(later)
    frames = sum(n for _, n in parts)
    joined = work / 'joined.webm'
    join(parts, joined)
    cues = json.loads((ROOT / 'demo-narration-cues.json').read_text())['cues']
    inputs, mix = audio_inputs(ROOT, cues, frames / 60)
    pending = work / 'final.webm'
    # Copied packets keep their own timestamps; renumber every frame at 60 fps.
    timing = ['-bsf:v', 'setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)'] if args.retain_later else []
    run(['ffmpeg', '-v', 'error', '-y', '-i', joined, *inputs, '-filter_complex', mix,
         '-map', '0:v:0', '-map', '[voice]', '-c:v', 'copy', *timing,
         '-c:a', 'libopus', '-b:a', '128k', '-ac', '2', '-ar', '48000', pending])
    assert int(probe(pending, count=True)['nb_read_frames']) == frames
    verify_timestamps(pending, frames)
    run(['ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin',
         '-i', pending, '-vn', '-f', 'null', '-'])
    assert all(frame_hash(pending, new) == expected for _, new, expected in samples), 'Retained chapter pixels changed'
    OUT.mkdir(parents=True, exist_ok=True)
    film = OUT / 'main-demo.webm'
    pending.replace(film)
    capture = json.loads((ROOT / 'capture.json').read_text())
    report = dict(frames=frames, output_bytes=film.stat().st_size,
        source_take=capture['take'], chapters=chapters,
        video=dict(codec='vp9', crf=28, cpu_used=3,
                   assembly='Current desktop (including Chromium); accepted mobile and node chapters copied'
                   if args.retain_later else 'Current desktop (including Chromium), mobile and node recordings'),
        audio=dict(codec='opus', target_bitrate=128000, channels=2,
                   source='Existing FLAC narration masters and carved stereo music bed'),
        verification=dict(full_video_frames=frames, full_audio_decode='passed',
                          **({'unchanged_later_chapter_samples': [[a, b] for a, b, _ in samples]} if samples else {})))
    (OUT / 'main-demo.webm.json').write_text(json.dumps(report, indent=2) + '\n')
    (OUT / 'main-demo.castle.json').write_text(json.dumps(dict(
        take=capture['take'], desktop_frames=parts[0][1], cuts=capture['cuts'],
        chapters=capture['chapters'], result=probe(film), **chapters), indent=2) + '\n')
    for suffix in ['srt', 'vtt']:
        for prefix in ['main-demo', 'main-demo.en']:
            shutil.copyfile(ROOT / f'demo-subtitles.{suffix}', OUT / f'{prefix}.{suffix}')
    print(f'Verified {frames} frames ({frames / 60:.2f}s): {film}', flush=True)


if __name__ == '__main__':
    main()
