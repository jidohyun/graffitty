#!/usr/bin/env python3
"""Encode only the new closing chapter; copy every accepted VP9 frame."""
import json
from pathlib import Path
import shutil

from narration import audio_inputs
from refresh_nodes import OUT, ROOT, WORK, packets, prepare, render_chapter
from render_navigation import join, probe, run
from render_systemone import frame_hash


def main():
    prepare()
    film = OUT / 'main-demo.webm'
    meta = json.loads((ROOT / 'protocol-capture.json').read_text())
    prefix_frames = round(meta['start'] * 60)
    total = prefix_frames + round(meta['duration'] * 60)
    assert packets(film) >= prefix_frames
    times = [t for t in [7, 69.25, 72.35, 90, 150, 230, 310, 360, meta['start'] - 1]
             if t < meta['start']]
    before = [frame_hash(film, at) for at in times]
    prefix = WORK / 'accepted-before-protocol.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', film, '-map', '0:v:0',
         '-frames:v', prefix_frames, '-an', '-c:v', 'copy', prefix])
    assert packets(prefix) == prefix_frames
    chapter = render_chapter('protocol')
    joined = WORK / 'with-protocol.webm'
    join([(prefix, prefix_frames), chapter], joined)
    cues = json.loads((ROOT / 'demo-narration-cues.json').read_text())['cues']
    inputs, mix = audio_inputs(ROOT, cues, total / 60)
    pending = WORK / 'protocol-final.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', joined, *inputs, '-filter_complex', mix,
         '-map', '0:v:0', '-map', '[voice]', '-c:v', 'copy',
         '-bsf:v', 'setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)',
         '-c:a', 'libopus', '-b:a', '128k', '-ac', '2', '-ar', '48000', pending])
    assert int(probe(pending, count=True)['nb_read_frames']) == total
    run(['ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin', '-i', pending,
         '-vn', '-f', 'null', '-'])
    assert [frame_hash(pending, at) for at in times] == before, 'Accepted footage changed'
    pending.replace(film)
    path = OUT / 'main-demo.webm.json'
    report = json.loads(path.read_text())
    report.update(frames=total, output_bytes=film.stat().st_size, protocol_start_frame=prefix_frames,
        protocol=meta, video=dict(codec='vp9', crf=28, cpu_used=3,
        assembly='Accepted film copied; only the Graph Protocol closing chapter encoded'),
        verification=dict(unchanged_preceding_samples=times, full_video_frames=total, full_audio_decode='passed'))
    path.write_text(json.dumps(report, indent=2) + '\n')
    path = OUT / 'main-demo.castle.json'
    report = json.loads(path.read_text())
    report.update(result=probe(film), protocol=meta)
    path.write_text(json.dumps(report, indent=2) + '\n')
    for ext in ['srt', 'vtt']:
        shutil.copyfile(ROOT / f'demo-subtitles.{ext}', OUT / f'main-demo.{ext}')
    print(f'Verified {total} frames, {total / 60:.2f}s: {film}', flush=True)


if __name__ == '__main__':
    main()
