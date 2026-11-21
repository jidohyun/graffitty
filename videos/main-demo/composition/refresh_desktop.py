#!/usr/bin/env python3
"""Refresh desktop footage, allowing reused Chromium; retain finished later scenes."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from edit_decisions import edited_frame
from narration import audio_inputs
from presentation import render_inputs
import render_navigation as splice
from render_systemone import frame_hash

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
OUT = REPO / 'videos/artifacts/main-demo'
WORK = ROOT / '.hyperframes/continuous-desktop'


def main():
    global WORK
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--freeze', action='store_true', help='Save the current exports before preparing the new take')
    parser.add_argument('--native-scene', type=Path)
    parser.add_argument('--android-scene', type=Path, help='Replace Android with its manager opening; retain the accepted Parallel and SystemOne scenes')
    parser.add_argument('--work', type=Path, default=WORK, help='Frozen baseline and scratch directory for this revision')
    parser.add_argument('--keep-opening', action='store_true', help='Copy the accepted tab-1 video up to its last keyframe')
    args = parser.parse_args()
    WORK = args.work.resolve()
    WORK.mkdir(exist_ok=True, parents=True)
    splice.WORK = WORK
    if args.freeze:
        for name in ['capture.json', 'systemone-capture.json']:
            target = WORK / name
            if target.exists():
                raise ValueError('A baseline already exists; do not overwrite accepted footage')
            shutil.copy2(ROOT / name, target)
        for suffix in ['webm']:
            shutil.copy2(OUT / f'main-demo.{suffix}', WORK / f'original.{suffix}')
        return
    assert args.native_scene and args.native_scene.is_file()
    meta = json.loads((ROOT / 'capture.json').read_text())
    old = json.loads((WORK / 'capture.json').read_text())
    old_routing = json.loads((WORK / 'systemone-capture.json').read_text())
    routing = json.loads((ROOT / 'systemone-capture.json').read_text())
    assert not meta['failures'], 'Use verified desktop footage'
    beats = {beat['action']: beat['frame'] for beat in meta['beats']}
    transition_start, transition_end = beats['Diagram: local HTML ready'], beats['Automation: launch Codex']
    spans = [span for span in meta.get('reused_recordings', [])
             if span['timeline_start_frame'] < transition_end
             and span['timeline_start_frame'] + span['end_frame'] - span['start_frame'] > transition_start]
    if spans:
        assert len({span['source'] for span in spans}) == 1, 'Reuse the corrected Chromium sequence intact'
        assert all(a['end_frame'] == b['start_frame'] for a, b in zip(spans, spans[1:]))
    desktop_frames = round(meta['timeline_duration'] * 60)
    total = round((routing['start'] + routing['duration']) * 60)
    old_total = round((old_routing['start'] + old_routing['duration']) * 60)
    old_start = round(old['timeline_duration'] * 60)
    later_start = desktop_frames
    inserted = []
    if args.android_scene:
        from refresh_nodes import packets
        mobile = json.loads((ROOT / 'android-capture.json').read_text())
        old_mobile = json.loads((WORK / 'android-capture.json').read_text())
        mobile_frames = round(mobile['duration'] * 60)
        old_start += round(old_mobile['duration'] * 60)
        later_start += mobile_frames
        inserted.append((args.android_scene.resolve(), mobile_frames))
    assert total - later_start == old_total - old_start
    keep_frames = 0
    if args.keep_opening:
        boundary = next(b['frame'] for b in old['beats'] if b['action'] == 'Select the Filetree session')
        assert beats['Select the Filetree session'] == boundary
        info = splice.probe(WORK / 'original.webm')
        raw = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
            '-show_packets', '-show_entries', 'packet=pts_time,flags', '-of', 'json', str(WORK / 'original.webm')]))['packets']
        keys = [round((float(p['pts_time']) - float(info.get('start_time', 0))) * 60)
                for p in raw if 'K' in p['flags']]
        keep_frames = max(k for k in keys if k <= boundary)
    native = meta['native_window']
    from refresh_nodes import packets
    assert packets(args.native_scene) == native['end_frame'] - native['start_frame']
    start = edited_frame(native['start_frame'], meta['cuts']) / 60
    end = edited_frame(native['end_frame'], meta['cuts']) / 60
    selection = '*'.join(f"not(between(n,{c['start_frame']},{c['end_frame']-1}))" for c in meta['cuts'])
    plate = ROOT.parent / 'assets/fixtures/castle-composite'
    inputs, titles, last = render_inputs(ROOT, 5, 0, desktop_frames / 60)
    graph = ';'.join([
        f"[0:v]select='{selection}',setpts=N/(60*TB),scale=1344:840:flags=lanczos,format=rgba[s]",
        '[s][2:v]alphamerge[w]', '[1:v][w]overlay=288:112:shortest=1[b]',
        '[b][3:v]overlay=299:132[c]', f'[4:v]setpts=PTS-STARTPTS+{start}/TB[native]',
        f"[c][native]overlay=0:0:enable='gte(t,{start})*lt(t,{end})':eof_action=pass[film]", titles])
    desktop = WORK / 'desktop.webm'
    splice.run(['ffmpeg', '-v', 'error', '-y', '-i', REPO / meta['take'] / 'footage.mp4',
        '-loop', '1', '-framerate', '60', '-i', plate / 'plate.png',
        '-loop', '1', '-framerate', '60', '-i', plate / 'mask.png', '-i', plate / 'traffic.png',
        '-i', args.native_scene, *inputs, '-filter_complex', graph, '-map', f'[{last}]',
        '-frames:v', desktop_frames, '-an', *splice.codec('webm'), '-pix_fmt', 'yuv420p',
        *(['-force_key_frames', str(keep_frames / 60)] if keep_frames else []),
        '-progress', WORK / 'desktop.progress', desktop])
    packet_info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-count_packets', '-show_entries', 'stream=nb_read_packets', '-of', 'json', str(desktop)]))
    assert int(packet_info['streams'][0]['nb_read_packets']) == desktop_frames
    desktop_parts = [(desktop, desktop_frames)]
    if keep_frames:
        prefix, rest = WORK / 'accepted-opening.webm', WORK / 'updated-desktop-rest.webm'
        splice.run(['ffmpeg', '-v', 'error', '-y', '-i', WORK / 'original.webm',
            '-map', '0:v:0', '-frames:v', keep_frames, '-an', '-c:v', 'copy', prefix])
        splice.run(['ffmpeg', '-v', 'error', '-y', '-i', desktop, '-ss', keep_frames / 60 - .5 / 60,
            '-map', '0:v:0', '-frames:v', desktop_frames - keep_frames, '-an', '-c:v', 'copy',
            '-avoid_negative_ts', 'make_zero', rest])
        assert packets(prefix) == keep_frames and packets(rest) == desktop_frames - keep_frames
        desktop_parts = [(prefix, keep_frames), (rest, desktop_frames - keep_frames)]
    print(f'Rendered desktop directly to WebM: {desktop_frames} frames', flush=True)
    # The independent Android chapter may render alongside the desktop. Check
    # its completed, atomically replaced output just before assembling it.
    if args.android_scene:
        assert packets(args.android_scene) == mobile_frames
    placed = json.loads((ROOT / 'demo-narration-cues.json').read_text())['cues']
    proof = {}
    for suffix in ['webm']:
        source = WORK / f'original.{suffix}'
        info = splice.probe(source)
        packets = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
            '-show_packets', '-show_entries', 'packet=pts_time,flags', '-of', 'json', str(source)]))['packets']
        origin = float(info.get('start_time', 0))
        keyframes = [round((float(p['pts_time'])-origin)*60) for p in packets if 'K' in p['flags']]
        suffix_clip = splice.extract(source, old_start, old_total, suffix, keyframes, 'retained-later-scenes')
        joined = WORK / f'joined.{suffix}'
        splice.join([*desktop_parts, *inserted, suffix_clip], joined)
        audio, mix = audio_inputs(ROOT, placed, total / 60)
        pending = WORK / f'final.{suffix}'
        splice.run(['ffmpeg', '-v', 'error', '-y', '-i', joined, *audio, '-filter_complex', mix,
            '-map', '0:v:0', '-map', '[voice]', '-c:v', 'copy', '-c:a', 'libopus',
            '-b:a', '128k', '-ac', '2', '-ar', '48000', '-t', total / 60, pending])
        assert int(splice.probe(pending, count=True)['nb_read_frames']) == total
        framing = ['-fflags', '+noparse+nofillin'] if suffix == 'webm' else []
        splice.run(['ffmpeg', '-v', 'error', '-xerror', *framing, '-i', pending, '-vn', '-f', 'null', '-'])
        samples = []
        for offset in ([10, 70, 130] if inserted else [10, 90, 150, 200]):
            before, after = old_start / 60 + offset, later_start / 60 + offset
            assert before < old_total / 60 and after < total / 60
            assert frame_hash(source, before) == frame_hash(pending, after), (suffix, offset)
            samples.append([before, after])
        if keep_frames:
            for at in [7, 12, 16, 25]:
                assert at < keep_frames / 60
                assert frame_hash(source, at) == frame_hash(pending, at), ('opening', at)
        pending.replace(OUT / f'main-demo.{suffix}')
        proof[suffix] = {'frames': total, 'unchanged_later_scene_samples': samples,
                        'copied_opening_frames': keep_frames, 'audio_decode': 'passed'}
        print(f'{suffix}: verified {total} frames and retained later scenes', flush=True)
    report = {'frames': total, 'source_take': meta['take'],
        'output_bytes': (OUT / 'main-demo.webm').stat().st_size,
        'video': {'codec': 'vp9', 'crf': 28, 'cpu_used': 3,
                  'assembly': 'Updated desktop and Android opening; accepted Parallel and SystemOne footage retained' if inserted else 'Updated desktop plus unchanged Android, Parallel and SystemOne footage'},
        'systemone_start_frame': round(routing['start'] * 60), 'continuous_desktop': proof}
    (OUT / 'main-demo.webm.json').write_text(json.dumps(report, indent=2)+'\n')
    (OUT / 'main-demo.castle.json').write_text(json.dumps({'take': meta['take'],
        'desktop_frames': desktop_frames, 'cuts': meta['cuts'], 'chapters': meta['chapters'],
        'result': splice.probe(OUT / 'main-demo.webm'), 'systemone': routing}, indent=2)+'\n')
    for ext in ['srt', 'vtt']:
        shutil.copyfile(ROOT / f'demo-subtitles.{ext}', OUT / f'main-demo.{ext}')
    (WORK / 'verification.json').write_text(json.dumps(proof, indent=2)+'\n')


if __name__ == '__main__':
    main()
