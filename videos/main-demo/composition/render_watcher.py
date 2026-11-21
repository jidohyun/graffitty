#!/usr/bin/env python3
"""Render the watcher chapter and append it without re-encoding accepted video."""
import json
import shutil

from narration import audio_inputs
from refresh_nodes import OUT, ROOT, WORK, packets, prepare, render_chapter
from render_navigation import join, probe, run
from render_systemone import frame_hash


def main():
    prepare()
    meta = json.loads((ROOT / 'watcher-capture.json').read_text())
    protocol = json.loads((ROOT / 'protocol-capture.json').read_text())
    prefix_frames = round(protocol['start'] * 60)
    total = round((meta['start'] + meta['duration']) * 60)
    film = OUT / 'main-demo.webm'
    assert packets(film) >= prefix_frames
    samples = [t for t in [7, 90, 230, protocol['start'] - 1] if t < protocol['start']]
    before = [frame_hash(film, at) for at in samples]
    prefix = WORK / 'accepted-before-watcher.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', film, '-map', '0:v:0',
         '-frames:v', prefix_frames, '-an', '-c:v', 'copy', prefix])
    assert packets(prefix) == prefix_frames
    protocol_chapter = render_chapter('protocol')
    chapter = render_chapter('watcher')
    cues = json.loads((ROOT / 'demo-narration-cues.json').read_text())['cues']
    joined = WORK / 'with-watcher.webm'
    join([(prefix, prefix_frames), protocol_chapter, chapter], joined)
    inputs, mix = audio_inputs(ROOT, cues, total / 60)
    pending = WORK / 'watcher-final.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', joined, *inputs, '-filter_complex', mix,
         '-map', '0:v:0', '-map', '[voice]', '-c:v', 'copy',
         '-bsf:v', 'setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)',
         '-c:a', 'libopus', '-b:a', '128k', '-ac', '2', '-ar', '48000', pending])
    assert int(probe(pending, count=True)['nb_read_frames']) == total
    run(['ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin', '-i', pending,
         '-vn', '-f', 'null', '-'])
    assert [frame_hash(pending, at) for at in samples] == before, 'Accepted footage changed'
    pending.replace(film)
    report_path = OUT / 'main-demo.webm.json'
    report = json.loads(report_path.read_text())
    report.update(frames=total, output_bytes=film.stat().st_size, watcher=meta,
                  verification=dict(unchanged_preceding_samples=samples,
                                    full_video_frames=total, full_audio_decode='passed'))
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    for ext in ['srt', 'vtt']:
        shutil.copyfile(ROOT / f'demo-subtitles.{ext}', OUT / f'main-demo.{ext}')
    # Stale deliverables are not rollback inputs. Keep source takes and chapter
    # caches elsewhere, and publish only the canonical complete film.
    for name in ['watcher-demo.webm', 'systemone-demo.webm', 'systemone-demo.mp4',
                 'parallel-demo.mp4', 'browser-demo.mp4', 'main-demo.mp4']:
        (OUT / name).unlink(missing_ok=True)
    for stale in OUT.glob('main-demo.*.part*.webm'):
        stale.unlink()
    print(f'Verified {total} frames, {total / 60:.2f}s: {film}', flush=True)


if __name__ == '__main__':
    main()
