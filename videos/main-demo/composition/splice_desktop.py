#!/usr/bin/env python3
"""Replace opening/filetree chapters while reusing verified later footage.

Each exact-frame span is encoded once and cached by source content + bounds.
The assembled video uses stream-copy concatenation. Keep output under assets
so DVC preserves these expensive, reusable intermediate videos.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from edit_decisions import session_navigation_span


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('base', type=Path)
    p.add_argument('replacement', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--chromium-start-frame', type=int, help='Optional verified cut after the old filetree-to-Markdown transition')
    p.add_argument('--replace-opening', action='store_true', help='Use the replacement opening as well as its filetree and Markdown session transition')
    p.add_argument('--replace-filetree', action='store_true', help='Keep the Workspace session and replace filetree through the Markdown session transition, joining at the cached first keystroke')
    p.add_argument('--replace-file-open', action='store_true', help='Replace the divider drag and Neovim reveal; resume the accepted take at its loaded PNG')
    p.add_argument('--replace-after-opening', action='store_true', help='Keep the Workspace session and replace the remaining desktop with a capture started at filetree')
    p.add_argument('--opening-only', action='store_true', help='Replace only the Workspace opening; retain the Filetree session transition and everything after it')
    a = p.parse_args()
    base, replacement, output = (v.resolve() for v in (a.base, a.replacement, a.output))
    output.mkdir(parents=True, exist_ok=True)
    metas = [json.loads((v/'capture.json').read_text()) for v in (base, replacement)]
    assert all(not m['failures'] and m['fps'] == 60 for m in metas)
    def frame(m, action):
        return next(b['frame'] for b in m['beats'] if b['action'] == action)
    first = 'Select the Filetree session'
    last = 'Chapter: Chromium: markdown preview'
    b, r = metas
    # The editable composition can contain a verified replacement of a short
    # popup in the retained source. Carry its evidence with that source span.
    repo = Path(__file__).resolve().parents[3]
    prepared_path = Path(__file__).with_name('capture.json')
    prepared = json.loads(prepared_path.read_text())
    if prepared.get('take') == str(base.relative_to(repo)) and prepared['frames'] == b['frames']:
        b['tabs_summary'] = copy.deepcopy(prepared['tabs_summary'])
    assert sum([a.opening_only, a.replace_opening, a.replace_filetree, a.replace_after_opening, a.replace_file_open]) <= 1, 'Choose one replacement mode'
    first_key = next(event['key_frames'][0] for event in b['typing_events'] if event['text'] == 'nvim guide.md')
    tail_start = a.chromium_start_frame
    if tail_start is None:
        tail_start = first_key if a.replace_opening or a.replace_filetree else frame(b, last)
    assert frame(b, last) <= tail_start < frame(b, 'Chapter: Chromium: automation')
    spans = [] if a.opening_only else [(base, b, 0, frame(b, first)),
             (replacement, r, frame(r, first), r['frames']),
             (base, b, tail_start, b['frames'])]
    if a.replace_opening or a.replace_filetree:
        assert frame(r, 'Select the Markdown session') < frame(r, 'Markdown session clicked') < r['frames']
        assert frame(r, 'Markdown session ready for typing') <= r['frames']
        assert tail_start == first_key, 'Join the session transition at the cached first keystroke'
        spans = ([(replacement, r, 0, r['frames'])] if a.replace_opening else
                 [(base, b, 0, frame(b, first)), (replacement, r, frame(r, first), r['frames'])])
        spans.append((base, b, tail_start, b['frames']))
    if a.opening_only:
        assert not any(event['action'] == first for event in r['beats']), 'Use a take recorded with --opening-only'
        assert any(event['action'] == 'Workspace: pane status' for event in r['beats'])
        tail_start = frame(b, first)
        spans = [(replacement, r, 0, r['frames']), (base, b, tail_start, b['frames'])]
    if a.replace_after_opening:
        assert frame(r, first) == 0, 'Use --capture-from-filetree'
        spans = [(base, b, 0, frame(b, first)), (replacement, r, 0, r['frames'])]
    if a.replace_file_open:
        begin, finish = 'Filetree rename camera settled', 'Image viewer ready'
        spans = [(base, b, 0, frame(b, begin)),
                 (replacement, r, frame(r, begin), frame(r, finish)),
                 (base, b, frame(b, finish), b['frames'])]
        assert all(0 <= start < end <= meta['frames'] for _, meta, start, end in spans)
    result = copy.deepcopy(r if a.replace_after_opening else b)
    if r.get('filetree_toggle') and not a.opening_only and not a.replace_file_open:
        result['filetree_toggle'] = copy.deepcopy(r['filetree_toggle'])
    result['session_navigation'] = {'prepared': result['session_navigation']['prepared'], 'transitions': []}
    for key in ['beats', 'typing_events', 'shortcut_events', 'settling', 'split_pointer_moves']:
        result[key] = []
    provenance = []
    clips = []
    cursor = 0
    native_source = base
    for span_index, (source, meta, start, end) in enumerate(spans):
        spec = {'sha256': digest(source/'footage.mp4'), 'start_frame': start,
                'end_frame': end, 'encoder': 'libx264-crf12-fast-yuv420p-v1'}
        key = hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()[:20]
        clip = output/f'span-{key}.mp4'
        if not clip.exists():
            temporary = clip.with_suffix('.pending.mp4')
            subprocess.run(['ffmpeg','-v','error','-y','-ss',str(start/60),
                '-i',str(source/'footage.mp4'),'-frames:v',str(end-start),'-an',
                '-c:v','libx264','-crf','12','-preset','fast','-pix_fmt','yuv420p',
                '-video_track_timescale','15360','-movflags','+faststart',str(temporary)],check=True)
            temporary.replace(clip)
        clips.append(clip)
        offset = cursor-start
        navigation = session_navigation_span(meta, start, end, offset)
        assert {k: v['id'] for k, v in navigation['prepared'].items()} == {k: v['id'] for k, v in result['session_navigation']['prepared'].items()}
        result['session_navigation']['transitions'].extend(navigation['transitions'])
        if source == base and start == tail_start and tail_start > frame(b, last) and not any(event['action'] == last for event in result['beats']):
            result['beats'].append({'action':last, 'frame':cursor, 'seconds':cursor/60})
        for event in meta['beats']:
            boundary = ((a.replace_opening or a.replace_filetree) and source == replacement and event['frame'] == end
                        and event['action'] == 'Markdown session ready for typing')
            # Completion markers describe the instant after the last image.
            # Preserve them when retaining the final span, even though image
            # frames themselves use an exclusive end bound.
            boundary = boundary or (span_index == len(spans) - 1 and event['frame'] == end)
            if (start <= event['frame'] < end or boundary) and event['action'] != 'Finished':
                changed = {**event, 'frame': event['frame']+offset}
                changed['seconds'] = changed['frame']/60
                result['beats'].append(changed)
        for event in meta.get('shortcut_events', []):
            if start <= event['frame'] < end:
                shortcut = {**event, 'frame': event['frame'] + offset}
                if 'prefix_frame' in event:
                    assert start <= event['prefix_frame'] <= event['frame'], 'Do not split a shortcut chord'
                    shortcut['prefix_frame'] += offset
                result['shortcut_events'].append(shortcut)
        for event in meta['typing_events']:
            if event['key_frames'] and start <= min(event['key_frames']) and max(event['key_frames']) < end:
                result['typing_events'].append({**event, 'key_frames':[f+offset for f in event['key_frames']]})
        for event in meta['settling']:
            if start <= event['start_frame'] < event['end_frame'] <= end:
                result['settling'].append({**event,'start_frame':event['start_frame']+offset,'end_frame':event['end_frame']+offset})
        for move in meta.get('split_pointer_moves', []):
            if start <= move['start_frame'] < move['end_frame'] <= end:
                result['split_pointer_moves'].append({**move, 'start_frame': move['start_frame'] + offset,
                                                      'end_frame': move['end_frame'] + offset})
        if meta.get('native_window') and start <= meta['native_window']['start_frame'] < end:
            native_source = source
            result['native_window'] = copy.deepcopy(meta['native_window'])
            for field in ['start_frame','end_frame']:
                result['native_window'][field] = meta['native_window'][field]+offset
            intro = result['native_window'].get('click_intro')
            if intro:
                intro['source_frames'] = [f + offset for f in intro['source_frames']]
        provenance.append({**spec, 'source':str(source.relative_to(Path(__file__).resolve().parents[3])), 'timeline_start_frame':cursor, 'typing_schedule_sha256':meta['typing_schedule_sha256'], 'cache':clip.name})
        cursor += end-start
    result['frames'] = cursor
    search = result.get('tabs_summary', {}).get('search', {})
    if search.get('recording'):
        recording = search['recording']
        retained = next((s for s in provenance if s['source'] == str(base.relative_to(repo))
                        and s['start_frame'] <= recording['raw_start_frame']
                        and recording['raw_end_frame'] <= s['end_frame']), None)
        if retained:
            offset = retained['timeline_start_frame'] - retained['start_frame']
            for field in ['raw_start_frame', 'raw_end_frame']:
                recording[field] += offset
        else:
            search.pop('recording')
    result['beats'].append({'action':'Finished','frame':cursor,'seconds':cursor/60})
    result['reused_recordings'] = provenance
    listing = output/'concat.txt'
    listing.write_text(''.join(f"file '{clip.name}'\n" for clip in clips))
    subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(listing),'-c','copy','-movflags','+faststart',str(output/'footage.mp4')],check=True)
    for filename in ['native-window.mp4','native-window-shape.png']:
        shutil.copy2(native_source/filename, output/filename)
    (output/'capture.json').write_text(json.dumps(result,indent=2)+'\n')
    print(f'Assembled {cursor} frames; reused Chromium and {len(clips)} cached spans')

if __name__ == '__main__':
    main()
