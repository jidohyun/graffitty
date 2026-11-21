#!/usr/bin/env python3
"""Freeze Audiio music and refresh audio without recording or encoding video.

See MUSIC.md for analysis/bake dependencies and provenance.
"""
import argparse
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent
SOURCE = 'assets/music/Audiio_Ben-Laver_Sonder_Keeper_Instrumental.wav'
BED = 'assets/music/bed.flac'


def run(*args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)


def signature(root, duration):
    cues = json.loads((root / 'demo-narration-cues.json').read_text())['cues']
    return hashlib.sha256(json.dumps([round(duration, 6), cues], sort_keys=True).encode()).hexdigest()


def prepare(carve_script):
    source = (ROOT / 'index.html').read_text()
    duration = float(re.search(r'data-composition-id="main"[^>]*data-duration="([\d.]+)', source)[1])
    source_duration = float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
        'format=duration', '-of', 'default=nw=1:nk=1', str(ROOT / SOURCE)]))
    gain = f'volume=-10dB,afade=t=in:d=1.5,afade=t=out:st={duration-5}:d=5'
    source_edit = None
    audio_filter = ['-af', gain]
    if duration > source_duration:
        # Extend the existing instrumental for additional chapters.
        # Crossfade into a repeated earlier passage, then rejoin consecutive
        # source samples. Leave the music's pitch, pace, and ending intact.
        fade = 2.0
        if (ROOT / 'systemone-capture.json').exists():
            routing = json.loads((ROOT / 'systemone-capture.json').read_text())
            at = min(routing['start'], source_duration - 8)
            extension = duration - source_duration
        else:
            chapters = json.loads((ROOT / 'capture.json').read_text())['chapters']
            chapter = next(c for c in chapters if c['text'] == 'Chromium: visual explanations')
            at = chapter['start']
            extension = sum(c['duration'] for c in chapters if c['text'] in
                            ['Chromium: visual explanations', 'tabs: status at a glance', 'command line: fuzzy finder built in'])
        assert at > extension + fade and duration - extension <= source_duration
        source_edit = {'insert_at': at, 'insert_duration': extension, 'crossfade': fade,
                       'repeat_source_start': at-extension-fade, 'repeat_source_end': at}
        audio_filter = ['-filter_complex',
            f'[0:a]asplit=3[p][l][t];'
            f'[p]atrim=end={at},asetpts=PTS-STARTPTS[prefix];'
            f'[l]atrim=start={at-extension-fade}:end={at},asetpts=PTS-STARTPTS[loop];'
            f'[prefix][loop]acrossfade=d={fade}:c1=tri:c2=tri[join];'
            f'[t]atrim=start={at}:end={duration-extension},asetpts=PTS-STARTPTS[tail];'
            f'[join][tail]concat=n=2:v=0:a=1,{gain}[bed]', '-map', '[bed]']
    run('ffmpeg', '-v', 'error', '-y', '-i', ROOT / SOURCE, *audio_filter,
        '-t', duration, '-ar', '48000', '-c:a', 'flac', ROOT / 'assets/music/normalized.flac')
    normalized_duration = float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
        'format=duration', '-of', 'default=nw=1:nk=1', str(ROOT / 'assets/music/normalized.flac')]))
    if abs(normalized_duration - duration) > 1 / 48000:
        raise ValueError('The extended music must cover the complete film')
    voices = '\n'.join(re.findall(r'<audio id="voice-[^>]+></audio>', source))
    voices = re.sub(r' data-audio-group="[^"]*"', '', voices).replace('<audio ', '<audio data-audio-group="voiceover" ')
    analysis = ROOT / 'music-analysis.html'
    analysis.write_text(f'<html><body><div data-composition-id="music-analysis" data-width="1920" data-height="1080" data-duration="{duration}">{voices}'
        f'<audio id="music-bed" src="assets/music/normalized.flac" data-start="0" data-duration="{duration}" data-volume="1"></audio></div></body></html>')
    run('node', carve_script, '--comp', analysis, '--core', ROOT / 'music-tools', '--bed', 'music-bed', '--strength', '.65')
    class ProfileParser(HTMLParser):
        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if attrs.get('id') == 'music-bed':
                self.profile = {key: json.loads(attrs[key]) for key in ['data-fx-carve', 'data-fx-chain', 'data-automation']}
    parser = ProfileParser(); parser.feed(analysis.read_text())
    profile = parser.profile
    profile.update(duration=duration, source='assets/music/normalized.flac', output=BED,
                   cue_signature=signature(ROOT, duration), source_edit=source_edit)
    (ROOT / 'music-profile.json').write_text(json.dumps(profile, indent=2) + '\n')
    run('node', 'music-tools/bake.mjs')
    run('ffmpeg', '-v', 'error', '-y', '-f', 'f32le', '-ar', '48000', '-ac', '2',
        '-i', ROOT / 'assets/music/bed.f32', '-c:a', 'flac', '-sample_fmt', 's32', ROOT / BED)
    (ROOT / 'assets/music/bed.f32').unlink()
    analysis.unlink()
    apply(ROOT)


def apply(root):
    """Keep the frozen bed in the timeline when chapter/presentation code rebuilds it."""
    if not (root / 'music-profile.json').exists():
        return
    path = root / 'index.html'
    source = path.read_text()
    duration = float(re.search(r'data-composition-id="main"[^>]*data-duration="([\d.]+)', source)[1])
    profile = json.loads((root / 'music-profile.json').read_text())
    source = re.sub(r'\s*<!-- demo-music:start -->.*?<!-- demo-music:end -->', '', source, flags=re.S)
    block = (f'\n    <!-- demo-music:start -->\n'
             f'    <audio id="music-bed" src="{BED}" data-start="0" data-duration="{min(duration,profile["duration"]):.6f}" '
             f'data-track-index="6" data-volume="1"></audio>\n    <!-- demo-music:end -->')
    source = source.replace('    <!-- demo-narration:end -->', '    <!-- demo-narration:end -->' + block)
    path.write_text(source)


def validate(root):
    profile = json.loads((root / 'music-profile.json').read_text())
    if signature(root, profile['duration']) != profile['cue_signature']:
        raise ValueError('Narration changed: run python3 music.py --prepare to rebuild the music carve')
    if not (root / BED).is_file():
        raise FileNotFoundError('Missing music bed; restore DVC assets or run music.py --prepare')
    return profile


def refresh():
    from narration import audio_inputs
    profile = validate(ROOT)
    duration = profile['duration']
    cues = json.loads((ROOT / 'demo-narration-cues.json').read_text())['cues']
    artifacts = ROOT.parents[1] / 'artifacts/main-demo'
    inputs, filters = audio_inputs(ROOT, cues, duration)
    for ext, codec, bitrate in [('webm', 'libopus', '128k')]:
        source = artifacts / f'main-demo.{ext}'
        output = artifacts / f'.main-demo.pending.{ext}'
        run('ffmpeg', '-v', 'error', '-y', '-i', source, *inputs,
            '-filter_complex', filters, '-map', '0:v:0', '-map', '[voice]',
            '-c:v', 'copy', '-c:a', codec, '-b:a', bitrate, '-ac', '2', '-ar', '48000',
            *(['-movflags', '+faststart'] if ext == 'mp4' else []), output)
        # Validate the full audio stream and unchanged compressed video payload.
        run('ffmpeg', '-v', 'error', '-xerror', '-fflags', '+noparse+nofillin',
            '-i', output, '-vn', '-f', 'null', '-')
        def video_hash(path):
            return subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path), '-map', '0:v:0',
                '-c:v', 'copy', '-f', 'hash', '-hash', 'sha256', '-'])
        if video_hash(source) != video_hash(output):
            raise ValueError('Audio refresh changed video packets')
        output.replace(source)
    report_path = artifacts / 'main-demo.webm.json'
    report = json.loads(report_path.read_text())
    report.update(output_bytes=(artifacts / 'main-demo.webm').stat().st_size)
    report['audio'] = dict(codec='opus', target_bitrate=128000, channels=2, vbr=True,
                          source='FLAC narration masters and carved Audiio stereo bed')
    report['video']['music_refresh'] = 'stream copy; compressed video SHA256 unchanged'
    report_path.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare', action='store_true')
    parser.add_argument('--refresh', action='store_true')
    parser.add_argument('--carve-script', type=Path, default=Path.home()/'.agents/skills/hyperframes-audio/scripts/carve.mjs')
    args = parser.parse_args()
    if args.prepare: prepare(args.carve_script)
    if args.refresh: refresh()
