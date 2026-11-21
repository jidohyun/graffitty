#!/usr/bin/env python3
"""Join an unchanged opening to a fresh Chromium take without retiming frames."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from edit_decisions import session_navigation_span

REPO = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    parser.add_argument('replacement', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    base, fresh, out = [p.resolve() for p in (args.base, args.replacement, args.output)]
    old, new = [json.loads((p/'capture.json').read_text()) for p in (base, fresh)]
    assert all(not m['failures'] and m['fps'] == 60 and 'editorial_retime' not in m for m in [old,new])
    boundary = 'Chapter: Chromium: automation'
    before, after = [next(b['frame'] for b in m['beats'] if b['action'] == boundary) for m in [old,new]]
    spans = [(base, old, 0, before), (fresh, new, after, new['frames'])]
    out.mkdir(parents=True, exist_ok=True)
    result = copy.deepcopy(new)
    result['session_navigation'] = {'prepared': result['session_navigation']['prepared'], 'transitions': []}
    for key in ['beats', 'typing_events', 'shortcut_events', 'settling']:
        result[key] = []
    for key in ['filetree_toggle', 'visual_explanation', 'transition_pointer']:
        result[key] = copy.deepcopy(old[key])
    result['source_spans'] = []
    cursor, clips = 0, []
    for source, meta, start, end in spans:
        with (source/'footage.mp4').open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        spec = dict(source=str(source.relative_to(REPO)), sha256=digest,
                    start_frame=start, end_frame=end, output_frames=end-start,
                    timeline_start_frame=cursor, playback_rate=1.0)
        key = hashlib.sha256(json.dumps(spec,sort_keys=True).encode()).hexdigest()[:20]
        clip = out/f'{key}.mp4'
        if not clip.exists():
            pending = clip.with_suffix('.pending.mp4')
            subprocess.run(['ffmpeg','-v','error','-y','-ss',str(start/60),'-i',str(source/'footage.mp4'),
                '-frames:v',str(end-start),'-an','-c:v','libx264','-crf','12','-preset','fast',
                '-pix_fmt','yuv420p','-fps_mode','passthrough','-video_track_timescale','15360',str(pending)],check=True)
            pending.replace(clip)
        count = int(subprocess.check_output(['ffprobe','-v','error','-count_packets','-select_streams','v:0',
            '-show_entries','stream=nb_read_packets','-of','default=nw=1:nk=1',str(clip)]))
        assert count == end-start, 'Every original frame must be retained exactly once'
        offset = cursor-start
        navigation = session_navigation_span(meta, start, end, offset)
        assert {k: v['id'] for k, v in navigation['prepared'].items()} == {k: v['id'] for k, v in result['session_navigation']['prepared'].items()}
        result['session_navigation']['transitions'].extend(navigation['transitions'])
        for event in meta['beats']:
            if start <= event['frame'] < end or (source==fresh and event['frame']==end):
                result['beats'].append({**event,'frame':event['frame']+offset,'seconds':(event['frame']+offset)/60})
        for event in meta['typing_events']:
            if event['key_frames'] and start <= min(event['key_frames']) <= max(event['key_frames']) < end:
                result['typing_events'].append({**event,'key_frames':[f+offset for f in event['key_frames']]})
        for event in meta.get('shortcut_events',[]):
            if start <= event['frame'] < end:
                result['shortcut_events'].append({**event,'frame':event['frame']+offset})
        for event in meta['settling']:
            if start <= event['start_frame'] <= event['end_frame'] <= end:
                result['settling'].append({**event,'start_frame':event['start_frame']+offset,'end_frame':event['end_frame']+offset})
        result['source_spans'].append(spec)
        clips.append(clip)
        cursor += end-start
    offset = before-after
    for key in ['start_frame','end_frame']:
        result['native_window'][key] += offset
    recording = result.get('tabs_summary',{}).get('search',{}).get('recording')
    if recording:
        for key in ['raw_start_frame','raw_end_frame']: recording[key] += offset
    result['frames'] = cursor
    listing = out/'concat.txt'
    listing.write_text(''.join(f"file '{p.name}'\n" for p in clips))
    subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(listing),
                    '-c','copy','-movflags','+faststart',str(out/'footage.mp4')],check=True)
    for filename in ['native-window.mp4','native-window-shape.png']:
        shutil.copy2(fresh/filename,out/filename)
    (out/'capture.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'Assembled {cursor} original-speed frames; no footage retiming')


if __name__ == '__main__': main()
