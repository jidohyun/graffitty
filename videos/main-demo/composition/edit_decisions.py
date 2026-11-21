"""Persistent editorial cuts, anchored to replay events instead of take timings."""
import json

def session_navigation_span(capture, start, end, offset=0):
    """Carry complete, unretimed sidebar transitions into a retained span."""
    navigation = capture['session_navigation']
    transitions = []
    for transition in navigation['transitions']:
        first, last = transition['start_frame'], transition['end_frame']
        if first >= end or last <= start:
            continue
        assert start <= first < last <= end, 'Do not cut through a session transition'
        retained = {**transition, **{
            key: transition[key] + offset
            for key in ['start_frame', 'click_frame', 'end_frame']
        }}
        if 'camera_frames' in transition:
            retained['camera_frames'] = [{**sample, 'frame': sample['frame'] + offset}
                                         for sample in transition['camera_frames']]
        transitions.append(retained)
    return {'prepared': navigation['prepared'], 'transitions': transitions}

def require_original_speed(capture):
    """Require every retained span to play at its recorded speed."""
    assert 'editorial_retime' not in capture, 'Baked footage retiming is forbidden; re-record faster inputs'
    assert capture.get('playback_rate', 1.0) == 1.0, 'Demo footage must play at original 1x speed'
    for segment in capture.get('segments', []):
        assert segment['playback_rate'] == 1.0
        assert abs(segment['source_end'] - segment['source_start'] - segment['duration']) < 1/120
    for span in capture.get('source_spans', []):
        assert span['playback_rate'] == 1.0
        assert span['output_frames'] == span['end_frame'] - span['start_frame'], 'Retain every source frame once'

def viewer_exit_cut(capture):
    beats = {beat['action']: int(beat['frame']) for beat in capture['beats']}
    start = beats['Quit Neovim with :q']
    end = beats['Image viewer ready']
    assert 0 < start < end < int(capture['frames']), 'Invalid viewer-exit cut'
    return {'start_frame': start, 'end_frame': end,
            'source_start': start / 60, 'source_end': end / 60,
            'reason': 'Skip Neovim exit; cut directly to Chromium PNG'}


def timeline_cuts(capture, take):
    cuts = [viewer_exit_cut(capture)]
    decisions = take / 'edit-decisions.json'
    if decisions.exists():
        beats = {b['action']: b['frame'] for b in capture['beats']}
        for cut in json.loads(decisions.read_text())['cuts']:
            start = beats[cut['start_beat']] + cut.get('start_offset_frames', 0)
            end = beats[cut['end_beat']]
            cuts.append({**cut, 'start_frame': start, 'end_frame': end,
                         'source_start': start / 60, 'source_end': end / 60})
    cuts.sort(key=lambda cut: cut['start_frame'])
    previous_end = 0
    for cut in cuts:
        assert previous_end <= cut['start_frame'] < cut['end_frame'] <= capture['frames'], 'Invalid or overlapping cuts'
        for transition in capture['session_navigation']['transitions']:
            assert cut['end_frame'] <= transition['start_frame'] or cut['start_frame'] >= transition['end_frame'], 'Do not cut through a session transition'
        previous_end = cut['end_frame']
    return cuts


def edited_frame(frame, cuts):
    return frame - sum(min(max(frame - cut['start_frame'], 0), cut['end_frame'] - cut['start_frame'])
                       for cut in cuts)
