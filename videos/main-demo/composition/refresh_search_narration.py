#!/usr/bin/env python3
"""Replace narration/captions and optionally the search popup, copying other GOPs."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from narration import audio_inputs
from presentation import render_inputs
import render_navigation as splice
from render_systemone import frame_hash

ROOT = Path(__file__).resolve().parent
WORK = ROOT / '.hyperframes/typo-menu-edit'
OUT = ROOT.parents[1] / 'artifacts/main-demo'


def read(path):
    return json.loads(path.read_text())


def main():
    global WORK
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=WORK, help='Frozen original.webm and narration cues')
    parser.add_argument('--voice', action='append', help='Narration ID; repeat for adjacent clips')
    parser.add_argument('--no-search', action='store_true', help='Only update the selected narration and captions')
    args = parser.parse_args()
    voice_ids = set(args.voice or ['chromium-diagram'])
    voice_label = next(iter(voice_ids)) if len(voice_ids) == 1 else 'narration'
    WORK = args.work.resolve()
    source = WORK / 'original.webm'
    info = splice.probe(source)
    packets = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_packets', '-show_entries', 'packet=pts_time,flags', '-of', 'json', str(source)]))['packets']
    origin = float(info.get('start_time', 0))
    keys = [round((float(p['pts_time']) - origin) * 60) for p in packets if 'K' in p['flags']]
    total = len(packets)
    cues = read(ROOT / 'demo-narration-cues.json')['cues']
    old = [c for c in read(WORK / 'demo-narration-cues.json')['cues'] if c['id'] in voice_ids]
    new = [c for c in cues if c['id'] in voice_ids]
    assert {c['id'] for c in old} == {c['id'] for c in new} == voice_ids
    capture = read(ROOT / 'capture.json')
    menu = capture['tabs_summary']['search']['recording']
    start = min(c['start'] for c in old + new)
    end = max(c['end'] for c in old + new)
    # Clear and redraw adjacent changed captions together. Require any speech
    # between them to be selected too, so its accepted captions cannot vanish.
    assert all(c['id'] in voice_ids or c['end'] <= start or c['start'] >= end for c in cues)
    spans = [(voice_label, start, end)]
    if not args.no_search:
        spans.append(('search', menu['start'], menu['start'] + menu['duration']))
    spans.sort(key=lambda span: span[1])
    replacements = []
    for label, start, end in spans:
        # Copy whole accepted GOPs everywhere outside these small edits.
        a = max(k for k in keys if k <= round(start * 60))
        b = min(k for k in keys if k >= round(end * 60))
        target = WORK / f'{label}.webm'
        if label == voice_label:
            # Only the subtitle strip changes; keep the accepted application,
            # title, mouse movement and chromium footage from the original film.
            plate = ROOT.parent / 'assets/fixtures/castle-composite/plate.png'
            inputs, filters, last = render_inputs(ROOT, 2, a / 60, (b-a) / 60,
                                                  voice_ids=voice_ids)
            extra = ['-i', plate, *inputs]
            graph = ('[0:v]setpts=PTS-STARTPTS[base];'
                     '[1:v]crop=1536:60:192:978[clear];'
                     f"[base][clear]overlay=192:978:enable='gte(t,{start-a/60})*lt(t,{end-a/60})'[film];"
                     + filters)
        else:
            extra = ['-c:v', 'libvpx-vp9', '-i', ROOT / menu['asset']]
            last = 'updated'
            graph = ('[0:v]setpts=PTS-STARTPTS[base];'
                     f'[1:v]scale=1344:840:flags=lanczos,format=rgba,setpts=PTS-STARTPTS+{start-a/60}/TB[menu];'
                     f"[base][menu]overlay=288:112:eof_action=pass:enable='gte(t,{start-a/60})*lt(t,{end-a/60})'[updated]")
        splice.run(['ffmpeg', '-v', 'error', '-y', '-ss', a / 60, '-i', source,
                    *extra, '-filter_complex', graph, '-map', f'[{last}]', '-frames:v', b-a,
                    '-an', *splice.codec('webm'), '-pix_fmt', 'yuv420p',
                    '-progress', WORK / f'{label}.progress', target])
        replacements.append((a, b, target))
        print(f'Updated {label}: frames {a}–{b}', flush=True)
    parts = []
    cursor = 0
    for a, b, replacement in replacements + [(total, total, None)]:
        if cursor < a:
            target = WORK / f'accepted-{cursor}-{a}.webm'
            splice.run(['ffmpeg', '-v', 'error', '-y', '-i', source, '-ss', max(0, cursor / 60 - .5/60),
                        '-map', '0:v:0', '-frames:v', a-cursor, '-an', '-c:v', 'copy',
                        '-avoid_negative_ts', 'make_zero', target])
            parts.append((target, a-cursor))
        if replacement: parts.append((replacement, b-a))
        cursor = b
    joined = WORK / 'joined.webm'
    splice.join(parts, joined)
    audio, mix = audio_inputs(ROOT, cues, total / 60)
    pending = WORK / 'final.webm'
    splice.run(['ffmpeg', '-v', 'error', '-y', '-i', joined, *audio, '-filter_complex', mix,
                '-map', '0:v:0', '-map', '[voice]', '-c:v', 'copy',
                '-bsf:v', 'setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)',
                '-c:a', 'libopus', '-b:a', '128k', '-ac', '2', '-ar', '48000', pending])
    assert int(splice.probe(pending, count=True)['nb_read_frames']) == total
    splice.run(['ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin',
                '-i', pending, '-vn', '-f', 'null', '-'])
    samples = [at for at in [7, 16, 33, 60, 85, 96.5, 105, 111.2, 120, 140, 165, 179, 190, 230, 310, 400]
               if not any(a <= round(at * 60) < b for a, b, _ in replacements)]
    for at in samples:
        assert frame_hash(source, at) == frame_hash(pending, at), at
    proof = {'frames': total, 'changed_ranges': [[a, b] for a, b, _ in replacements],
             'unchanged_frame_samples': samples, 'audio_decode': 'passed',
             'search_recording': menu, 'narration': new[0] if len(new) == 1 else new}
    (WORK / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
    pending.replace(OUT / 'main-demo.webm')
    report = read(OUT / 'main-demo.webm.json')
    report.update(frames=total, output_bytes=(OUT / 'main-demo.webm').stat().st_size)
    report['narration_refresh' if args.no_search else 'search_narration_refresh'] = proof
    report['video']['assembly'] = f'Updated {", ".join(c["id"] for c in new)} captions' + (
        '; other GOPs copied' if args.no_search else ' and typo-search popup; other GOPs copied')
    (OUT / 'main-demo.webm.json').write_text(json.dumps(report, indent=2) + '\n')
    for suffix in ['srt', 'vtt']:
        shutil.copyfile(ROOT / f'demo-subtitles.{suffix}', OUT / f'main-demo.{suffix}')
    print(f'Verified {total} frames; unchanged footage at {len(samples)} sample points', flush=True)


if __name__ == '__main__':
    main()
