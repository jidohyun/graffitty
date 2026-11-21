#!/usr/bin/env python3
"""Replace the Android manager opening, preserving timing and accepted audio."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from render_navigation import codec, join, run
from refresh_nodes import packets
from render_systemone import frame_hash
from verify_delivery import verify_timestamps

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parents[1] / 'artifacts/main-demo'


def packet_data(path, stream):
    return json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', stream, '-show_packets',
        '-show_data_hash', 'sha256', '-show_entries', 'packet=flags,data_hash',
        '-of', 'json', str(path),
    ]))['packets']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=ROOT / '.hyperframes/server-card-refresh',
                        help='Frozen baseline containing android-capture.json')
    args = parser.parse_args()
    work = args.work.resolve()
    old = json.loads((work / 'android-capture.json').read_text())
    current = json.loads((ROOT / 'android-capture.json').read_text())
    assert round(old['start'] * 60) == round(current['start'] * 60)
    assert round(old['duration'] * 60) == round(current['duration'] * 60)
    assert old['manager']['frames'] == current['manager']['frames'], 'Keep later scenes in place'
    scene = ROOT / current['manager']['source']
    count = current['manager']['frames']
    assert packets(scene) == count
    start = round(current['start'] * 60)
    target = OUT / 'main-demo.webm'
    target_stat = target.stat()
    original = work / 'original.webm'
    if not original.exists():
        shutil.copy2(target, original)
    original_packets = packet_data(original, 'v:0')
    total = len(original_packets)
    keys = [i for i, packet in enumerate(original_packets) if 'K' in packet['flags']]
    keys.append(total)
    begin = max(k for k in keys if k <= start)
    end = next(k for k in keys if k >= start + count)
    offset = (start - begin) / 60
    finish = offset + count / 60
    # Keep the accepted title and subtitle bands. Outside the manager slot,
    # retain the old app pixels through the next existing keyframe as well.
    #
    # The phone wrapper starts at y=56, but titles paint over it through
    # y=112. Crop the empty top 56 px of its source instead of covering those
    # titles.
    graph = (f'[0:v]crop=1920:844:0:56,setsar=1,setpts=PTS-STARTPTS+{offset}/TB[phone];'
             '[1:v]setpts=PTS-STARTPTS[base];'
             f"[base][phone]overlay=0:112:enable='gte(t,{offset})*lt(t,{finish})':"
             'eof_action=pass[film]')
    replacement = work / 'manager.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', scene, '-ss', begin / 60, '-i', original,
         '-filter_complex', graph, '-map', '[film]', '-frames:v', end - begin, '-an',
         *codec('webm'), '-pix_fmt', 'yuv420p', replacement])
    assert packets(replacement) == end - begin
    prefix, suffix = work / 'prefix.webm', work / 'suffix.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', original, '-map', '0:v:0',
         '-frames:v', begin, '-an', '-c:v', 'copy', prefix])
    run(['ffmpeg', '-v', 'error', '-y', '-i', original, '-ss', end / 60 - .5 / 60,
         '-map', '0:v:0', '-frames:v', total - end, '-an', '-c:v', 'copy',
         '-avoid_negative_ts', 'make_zero', suffix])
    assert packets(prefix) == begin and packets(suffix) == total - end
    joined = work / 'joined.webm'
    join([(prefix, begin), (replacement, end - begin), (suffix, total - end)], joined)
    pending = work / 'final.webm'
    run(['ffmpeg', '-v', 'error', '-y', '-i', joined, '-i', original,
         '-map', '0:v:0', '-map', '1:a:0', '-c', 'copy', '-bsf:v',
         'setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)', pending])
    verify_timestamps(pending, total)
    final_packets = packet_data(pending, 'v:0')
    assert final_packets[:begin] == original_packets[:begin], 'Preceding footage changed'
    assert final_packets[end:] == original_packets[end:], 'Later footage changed'
    assert packet_data(pending, 'a:0') == packet_data(original, 'a:0'), 'Audio changed'
    samples = [10, 70, 150, begin / 60 - 1, end / 60 + 1, 230, 300]
    for at in samples:
        assert frame_hash(original, at) == frame_hash(pending, at), at
    run(['ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin',
         '-i', pending, '-vn', '-f', 'null', '-'])
    latest = target.stat()
    assert (latest.st_mtime_ns, latest.st_size, latest.st_ino) == (
        target_stat.st_mtime_ns, target_stat.st_size, target_stat.st_ino
    ), 'Delivery changed during rendering; do not overwrite it'
    pending.replace(target)
    proof = {'frames': total, 'duration': total / 60, 'manager_frames': [start, start + count],
             'reencoded_frames': [begin, end], 'copied_video_packets': begin + total - end,
             'unchanged_frame_samples': samples, 'audio': 'all packets preserved',
             'full_audio_decode': 'passed'}
    report_path = OUT / 'main-demo.webm.json'
    report = json.loads(report_path.read_text())
    report.update(output_bytes=target.stat().st_size, android_manager=proof)
    report['video']['assembly'] = 'New Android server cards; surrounding scenes and audio stream copied'
    report_path.write_text(json.dumps(report, indent=2) + '\n')
    (work / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof, indent=2), flush=True)


if __name__ == '__main__':
    main()
