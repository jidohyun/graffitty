#!/usr/bin/env python3
"""Render the revised Chromium edit and copy the accepted surrounding chapters."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from narration import audio_inputs
from render_demo import ROOT, OUT, desktop
import render_navigation as splice
from refresh_nodes import packets
import refresh_nodes
from verify_delivery import verify_timestamps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--native-scene', required=True, type=Path)
    parser.add_argument('--refresh-android', action='store_true', help='Render the revised mobile chapter in the same export')
    args = parser.parse_args()
    work = args.baseline.resolve()
    old = json.loads((work/'capture.json').read_text())
    current = json.loads((ROOT/'capture.json').read_text())
    source = work/'original.webm'
    if not source.exists():
        shutil.copy2(OUT/'main-demo.webm', source)
    begin = round(next(c['start'] for c in current['chapters'] if c['text']=='Chromium: automation')*60)
    assert begin == round(next(c['start'] for c in old['chapters'] if c['text']=='Chromium: automation')*60)
    old_desktop = round(old['timeline_duration']*60)
    suffix_start = (round(json.loads((work/'systemone-capture.json').read_text())['start']*60)
                    if args.refresh_android else old_desktop)
    old_total = packets(source)
    raw = json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
        '-show_packets','-show_entries','packet=pts_time,flags','-of','json',str(source)]))['packets']
    origin = float(splice.probe(source).get('start_time', 0))
    keys = [round((float(p['pts_time'])-origin)*60) for p in raw if 'K' in p['flags']]
    splice.WORK = work
    before = splice.extract(source, 0, begin, 'webm', keys, 'accepted-opening')
    after = splice.extract(source, suffix_start, old_total, 'webm', keys, 'accepted-later-chapters')
    changed = desktop(work, args.native_scene.resolve(), begin)
    parts = [before, changed]
    if args.refresh_android:
        refresh_nodes.WORK = work/'mobile'
        refresh_nodes.prepare()
        parts.append(refresh_nodes.render_chapter('android'))
    parts.append(after)
    total = sum(n for _,n in parts)
    joined = work/'joined.webm'
    splice.join(parts, joined)
    cues = json.loads((ROOT/'demo-narration-cues.json').read_text())['cues']
    inputs, mix = audio_inputs(ROOT, cues, total/60)
    pending = work/'final.webm'
    splice.run(['ffmpeg','-v','error','-y','-i',joined,*inputs,'-filter_complex',mix,
        '-map','0:v:0','-map','[voice]','-c:v','copy','-c:a','libopus','-b:a','128k','-ar','48000','-ac','2',pending])
    assert packets(pending)==total
    verify_timestamps(pending,total)
    splice.run(['ffmpeg','-v','error','-xerror','-fflags','+noparse+nofillin','-i',pending,'-vn','-f','null','-'])
    film = OUT/'main-demo.webm'
    pending.replace(film)
    for ext in ['srt','vtt']: shutil.copy2(ROOT/f'demo-subtitles.{ext}', OUT/f'main-demo.{ext}')
    beats = {b['action']: b['frame'] for b in current['beats']}
    report = dict(frames=total, source_take=current['take'], output_bytes=film.stat().st_size,
        saved_seconds=(old_total-total)/60,
        playback_rate=1.0, source_spans=current['source_spans'],
        chromium_typing_to_visible_seconds=(beats['Both chromium tests visible']-beats['Automation: type test prompts'])/60,
        native_close_seconds=6.4, native_sentence_pause_seconds=.29,
        ownership_pause_seconds=next(c['start'] for c in cues if c['id']=='chromium-ownership')-next(c['end'] for c in cues if c['id']=='chromium-native'),
        android_refreshed=args.refresh_android,
        verification=dict(frames=total, timestamps='passed', audio_decode='passed'))
    (OUT/'main-demo.webm.json').write_text(json.dumps(report,indent=2)+'\n')
    (OUT/'main-demo.castle.json').write_text(json.dumps(dict(take=current['take'],
        desktop_frames=round(current['timeline_duration']*60), cuts=current['cuts'],
        chapters=current['chapters'], result=splice.probe(film)),indent=2)+'\n')
    (work/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__ == '__main__': main()
