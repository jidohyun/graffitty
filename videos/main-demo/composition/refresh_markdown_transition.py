#!/usr/bin/env python3
"""Replace Markdown through its Diagram departure with one original-speed take."""
import argparse
import hashlib
import json
from pathlib import Path
import re

from edit_decisions import edited_frame
from refresh_filetree_transition import render
from refresh_nodes import packets
from render_navigation import codec, run

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]


def departure_evidence(transition):
    frames = transition['camera_frames']
    pending = [index for index, frame in enumerate(frames) if frame['pending_capture']]
    assert pending and pending[0] > 0, 'Record the frames before and during topology binding'
    first = pending[0]
    reference = frames[first - 1]['rotation']
    held = frames[first:pending[-1] + 2]
    assert held[-1]['flight'], 'Include the first flight frame'
    error = max(abs(a - b) for frame in held for a, b in zip(frame['rotation'], reference))
    assert error < 1e-7, f'Departure camera jumped during topology binding: {error}'
    optical_keys = ['focus_depth', 'blur_radius', 'depth_range', 'defocus_weight']
    optics = {key: frames[first - 1][key] for key in optical_keys}
    optical_error = max(abs(frame[key] - optics[key]) for frame in held for key in optical_keys)
    assert optical_error < 1e-7, f'Departure optics changed during topology binding: {optical_error}'
    return {'before_frame': frames[first - 1]['frame'], 'held_frames': held,
            'rotation': reference, 'max_rotation_error': error,
            'optics': optics, 'max_optical_error': optical_error}


def prepare(take):
    capture = json.loads((ROOT / 'capture.json').read_text())
    fresh = json.loads((take / 'capture.json').read_text())
    assert not fresh['failures'] and fresh['fps'] == 60
    old_transition = next(t for t in capture['session_navigation']['transitions'] if t['name'] == 'Diagram')
    transition = next(t for t in fresh['session_navigation']['transitions'] if t['name'] == 'Diagram')
    assert transition['isolated_departure_frames'] > 20, 'Record the flying glyphs in their own blur pass'
    old_markdown = next(t for t in capture['session_navigation']['transitions'] if t['name'] == 'Markdown')
    markdown = next(t for t in fresh['session_navigation']['transitions'] if t['name'] == 'Markdown')
    evidence = departure_evidence(transition)
    # Include the live browser demonstration, so its URL, page state and chrome
    # are the same capture as the departure. A departure-only insert changes
    # those pixels before the user even clicks the session.
    start = edited_frame(old_markdown['end_frame'], capture['cuts'])
    end = edited_frame(old_transition['end_frame'], capture['cuts'])
    first, last = markdown['end_frame'], transition['end_frame']
    length, recorded = end - start, last - first
    # The asynchronous arrival can settle a frame later. Cover that frame of
    # the following stationary hold rather than cutting or speeding the flight.
    assert abs(length - recorded) <= 2, 'Keep the complete flight at its recorded speed'
    if recorded > length:
        end += recorded - length
        length = recorded
    assert 0 <= length - recorded <= 2, 'Keep the complete flight at its recorded speed'
    source = ROOT / 'assets/markdown-transition.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-ss', first / 60, '-i', take / 'footage.mp4',
         '-vf', f'trim=end_frame={recorded},setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration={length / 60}',
         '-frames:v', length, '-an', *codec('webm'), '-pix_fmt', 'yuv420p', source])
    assert packets(source) == length
    with (take / 'footage.mp4').open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    meta = {'take': str(take.relative_to(REPO)), 'source': 'assets/markdown-transition.webm',
            'source_sha256': digest, 'source_start_frame': first, 'source_end_frame': last,
            'start_frame': start, 'end_frame': end, 'start': start / 60, 'duration': length / 60,
            'recorded_frames': recorded, 'landed_hold_frames': length - recorded, 'playback_rate': 1.0,
            'click_frame': start + transition['click_frame'] - first,
            'isolated_departure_frames': transition['isolated_departure_frames'],
            'departure_camera': evidence, 'failures': fresh['failures']}
    (ROOT / 'markdown-transition.json').write_text(json.dumps(meta, indent=2) + '\n')
    html = (ROOT / 'index.html').read_text()
    html = re.sub(r'\n\s*<!-- markdown-transition:start -->.*?<!-- markdown-transition:end -->', '', html, flags=re.S)
    marker = '<!-- recorded-footage:end -->'
    html = html.replace(marker, marker + f'''
      <!-- markdown-transition:start -->
      <video id="markdown-session-transition" class="clip footage" src="assets/markdown-transition.webm" muted playsinline data-start="{start / 60:.6f}" data-duration="{length / 60:.6f}" data-media-start="0" data-track-index="1" style="z-index:1;pointer-events:none"></video>
      <!-- markdown-transition:end -->''')
    (ROOT / 'index.html').write_text(html)
    print(json.dumps(meta, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--take', type=Path)
    parser.add_argument('--render', action='store_true')
    args = parser.parse_args()
    if args.take:
        prepare(args.take.resolve())
    if args.render:
        render('markdown-transition.json', ROOT / '.hyperframes/markdown-transition')
