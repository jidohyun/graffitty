#!/usr/bin/env python3
"""Export the assembled demo as VP9 WebM with 128 kbps stereo Opus from FLAC masters."""
import argparse
import json
from pathlib import Path
import subprocess

from narration import audio_inputs


def probe(path, count=False):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", *(["-count_frames"] if count else []),
        "-show_streams", "-show_format", "-of", "json", str(path)]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--chapter", choices=["full", "desktop", "chromium", "systemone"], default="full")
    parser.add_argument("--crf", type=int, default=28)
    parser.add_argument("--cpu-used", type=int, default=3)
    parser.add_argument("--append-systemone", action="store_true", help="Reuse the existing WebM prefix and the separately exported SystemOne chapter")
    args = parser.parse_args()
    if not 0 <= args.crf <= 63 or not 0 <= args.cpu_used <= 5:
        parser.error("Expected CRF 0–63 and cpu-used 0–5")
    if args.append_systemone and args.chapter != 'full':
        parser.error('--append-systemone is for the full film')
    root = Path(__file__).resolve().parent
    artifacts = root.parents[1] / "artifacts/main-demo"
    names = {"full": "main-demo", "desktop": "castle-desktop", "chromium": "chromium-demo", "systemone": "systemone-demo"}
    source = artifacts / (names[args.chapter] + ".mp4")
    output = source.with_suffix(".webm")
    temporary = source.with_suffix(".next.webm")
    capture = json.loads((root / "capture.json").read_text())
    offset = 0
    expected_duration = capture["timeline_duration"]
    if args.chapter == "full":
        expected_duration += sum(json.loads((root / name).read_text())["duration"]
                                 for name in ["android-capture.json", "parallel-capture.json"])
        if (root / 'systemone-capture.json').exists():
            expected_duration += json.loads((root / 'systemone-capture.json').read_text())['duration']
    elif args.chapter == "systemone":
        routing = json.loads((root / 'systemone-capture.json').read_text())
        offset, expected_duration = routing['start'], routing['duration']
    elif args.chapter == "chromium":
        offset = next(chapter["start"] for chapter in capture["chapters"]
                      if chapter["text"] == "Chromium: markdown preview")
        expected_duration -= offset
    stream = next(s for s in probe(source)["streams"] if s["codec_type"] == "video")
    frames = int(stream["nb_frames"])
    duration = frames / 60
    if (stream["width"], stream["height"], stream["r_frame_rate"]) != (1920, 1080, "60/1"):
        raise ValueError("Expected the assembled 1080p60 MP4")
    if abs(duration - expected_duration) > 1 / 120:
        raise ValueError("Assembled MP4 duration does not match the current composition")
    placed = []
    for cue in json.loads((root / "demo-narration-cues.json").read_text())["cues"]:
        if cue["end"] <= offset or cue["start"] >= offset + duration:
            continue
        if cue["start"] < offset or cue["end"] > offset + duration:
            raise ValueError("Chapter cuts through a narration clip")
        if Path(cue["path"]).suffix != ".flac":
            raise ValueError("WebM narration must come from the lossless FLAC masters")
        placed.append({**cue, "start": cue["start"] - offset, "end": cue["end"] - offset})
    if not placed:
        raise ValueError("No narration cues found")
    inputs, filters = audio_inputs(root, placed, duration, offset)
    video_source = source
    video_codec = ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", str(args.crf),
                   "-deadline", "good", "-cpu-used", str(args.cpu_used), "-row-mt", "1",
                   "-tile-columns", "2", "-threads", "8", "-g", "240", "-pix_fmt", "yuv420p"]
    append_start = None
    if args.append_systemone:
        routing = json.loads((root/'systemone-capture.json').read_text())
        append_start = round(routing['start']*60)
        previous = json.loads(output.with_suffix('.webm.json').read_text())
        assert previous['frames'] == append_start or previous.get('systemone_start_frame') == append_start, 'Existing WebM prefix has different chapter timing'
        chapter = artifacts/'systemone-demo.webm'
        chapter_report = json.loads(chapter.with_suffix('.webm.json').read_text())
        assert chapter_report['frames'] == frames-append_start
        cache = root/'.hyperframes/systemone-render'
        cache.mkdir(parents=True,exist_ok=True)
        prefix = cache/'prefix.webm'
        subprocess.run(['ffmpeg','-v','error','-y','-i',str(output),'-map','0:v:0',
                        '-frames:v',str(append_start),'-an','-c:v','copy',str(prefix)],check=True)
        playlist = cache/'concat-webm.txt'
        playlist.write_text(f"file '{prefix}'\nduration {routing['start']:.9f}\nfile '{chapter}'\n")
        video_source = cache/'assembled.webm'
        subprocess.run(['ffmpeg','-v','error','-y','-f','concat','-safe','0','-i',str(playlist),
                        '-map','0:v:0','-an','-c:v','copy',str(video_source)],check=True)
        video_codec = ['-c:v','copy']
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(video_source),
               *inputs, "-filter_complex", filters, "-map", "0:v:0", "-map", "[voice]",
               "-frames:v", str(frames), *video_codec,
               "-c:a", "libopus", "-b:a", "128k", "-ac", "2",
               "-ar", "48000", "-vbr", "on", "-application", "audio", "-t", str(duration),
               "-progress", str(output.with_suffix(".progress.txt")), "-stats_period", "5",
               str(temporary)]
    subprocess.run(command, check=True)
    result = probe(temporary, count=True)
    video = next(s for s in result["streams"] if s["codec_type"] == "video")
    audio = next(s for s in result["streams"] if s["codec_type"] == "audio")
    if (video["codec_name"], int(video["nb_read_frames"])) != ("vp9", frames):
        raise ValueError("WebM video codec or frame count changed")
    if (audio["codec_name"], audio["channels"], audio["sample_rate"]) != ("opus", 2, "48000"):
        raise ValueError("Expected stereo Opus audio at 48 kHz")
    temporary.replace(output)
    report = {"source": source.name, "output": output.name, "frames": frames,
              "source_bytes": source.stat().st_size, "output_bytes": output.stat().st_size,
              "video": {"codec": "vp9", "crf": args.crf, "cpu_used": args.cpu_used},
              "audio": {"codec": "opus", "target_bitrate": 128000, "channels": 2,
                        "vbr": True, "source": "FLAC narration masters and carved Audiio stereo bed"}}
    if append_start is not None:
        report['systemone_start_frame'] = append_start
        report['video']['assembly'] = 'Stream copy of previous film and standalone SystemOne chapter'
    output.with_suffix(".webm.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
