#!/usr/bin/env python3
"""Render a replaced filetree chapter and copy the accepted surrounding film."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from edit_decisions import edited_frame
from narration import audio_inputs
from presentation import render_inputs
import render_navigation as splice
from render_systemone import frame_hash

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
OUT = REPO / "videos/artifacts/main-demo"


def bounds(meta):
    start = next(b["frame"] for b in meta["beats"] if b["action"] == "Select the Filetree session")
    end = next(e["key_frames"][0] for e in meta["typing_events"] if e["text"] == "nvim guide.md")
    return start, end


def video_packets(path):
    return json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_packets", "-show_data_hash", "sha256", "-show_entries", "packet=flags,data_hash",
        "-of", "json", str(path)]))["packets"]


def retain_around_file_open(work, baseline):
    """Finish a rendered file-open replacement with the accepted surrounding VP9 packets."""
    source, film = baseline / "original.webm", OUT / "main-demo.webm"
    old = json.loads((baseline / "capture.json").read_text())
    current = json.loads((ROOT / "capture.json").read_text())
    prefix, replacement, suffix = current["reused_recordings"]
    assert prefix["source"] == suffix["source"] == old["take"]
    assert prefix["start_frame"] == 0 and suffix["end_frame"] == old["frames"]
    def beat(meta, name):
        return next(b["frame"] for b in meta["beats"] if b["action"] == name)
    def word_end(folder):
        cues = json.loads((folder / "demo-narration-cues.json").read_text())["cues"]
        return next(v["end"] for v in cues if v["id"] == "filetree-open") * 60
    begin = beat(current, "Filetree rename camera settled")
    assert replacement["timeline_start_frame"] == begin == beat(old, "Filetree rename camera settled")
    assert suffix["start_frame"] == beat(old, "Image viewer ready")
    old_packets, new_packets = video_packets(source), video_packets(film)
    difference = len(old_packets) - len(new_packets)
    old_png, new_png = [edited_frame(beat(m, "Image viewer ready"), m["cuts"]) for m in (old, current)]
    assert old_png - new_png == difference, "Only file opening can change length"
    # Start on a shared keyframe before the drag. Return on an original keyframe
    # after both file-open captions finish so the new words keep their timing.
    first = max(i for i in range(begin + 1) if "K" in old_packets[i]["flags"] and "K" in new_packets[i]["flags"])
    resume = max(old_png, word_end(baseline), word_end(ROOT) + difference)
    last = next(i for i, packet in enumerate(old_packets) if i >= resume and "K" in packet["flags"])
    assert last <= edited_frame(beat(old, "Chapter: filetree: send paths to the terminal"), old["cuts"])
    end = last - difference
    parts = []
    for label, src, lo, hi in [("opening", source, 0, first), ("file-open", film, first, end),
                               ("following", source, last, len(old_packets))]:
        if lo == hi:
            continue
        target = work / f"{label}.webm"
        splice.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-ss", max(0, (lo - .5) / 60),
                    "-map", "0:v:0", "-frames:v", hi - lo, "-an", "-c:v", "copy",
                    "-avoid_negative_ts", "make_zero", target])
        parts.append((target, hi - lo))
    joined, pending = work / "file-open-joined.webm", work / "file-open-final.webm"
    splice.join(parts, joined)
    splice.run(["ffmpeg", "-v", "error", "-y", "-i", joined, "-i", film, "-map", "0:v:0", "-map", "1:a:0",
                "-c", "copy", "-bsf:v", "setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)", pending])
    assert video_packets(pending) == old_packets[:first] + new_packets[first:end] + old_packets[last:]
    assert int(splice.probe(pending, count=True)["nb_read_frames"]) == len(new_packets)
    pending.replace(film)
    report_path = OUT / "main-demo.webm.json"
    report = json.loads(report_path.read_text())
    report["video"]["assembly"] = "File opening from the new render; original surrounding VP9 packets retained"
    report["verification"]["file_open_render_frames"] = [first, end]
    report["verification"]["original_video_packets"] = first + len(old_packets) - last
    report["output_bytes"] = film.stat().st_size
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified {len(new_packets)} video packets; new render supplies [{first}, {end})", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True, help="Baseline from refresh_desktop.py --freeze")
    parser.add_argument("--reuse-chapter", action="store_true", help="Resume assembly using this revision's completed chapter render")
    parser.add_argument("--retain-around-file-open", type=Path, metavar="BASELINE",
                        help="Keep the new file opening and audio mix from render_demo.py, with the original film on both sides")
    args = parser.parse_args()
    work = args.work.resolve()
    if args.retain_around_file_open:
        work.mkdir(parents=True, exist_ok=True)
        return retain_around_file_open(work, args.retain_around_file_open.resolve())
    splice.WORK = work
    old = json.loads((work / "capture.json").read_text())
    current = json.loads((ROOT / "capture.json").read_text())
    old_routing = json.loads((work / "systemone-capture.json").read_text())
    routing = json.loads((ROOT / "systemone-capture.json").read_text())
    assert not current["failures"]
    raw_start, raw_end = bounds(current)
    start, end = [edited_frame(n, current["cuts"]) for n in (raw_start, raw_end)]
    old_start, old_end = [edited_frame(n, old["cuts"]) for n in bounds(old)]
    total = round((routing["start"] + routing["duration"]) * 60)
    old_total = round((old_routing["start"] + old_routing["duration"]) * 60)
    assert start == old_start and total - end == old_total - old_end
    cuts = [c for c in current["cuts"] if raw_start <= c["start_frame"] < c["end_frame"] <= raw_end]
    assert end - start == raw_end - raw_start - sum(c["end_frame"] - c["start_frame"] for c in cuts)
    # Evaluate overlays on the original timeline before trimming. Both splice
    # boundaries can be inside a chapter title, whose fade must stay continuous.
    selection = "*".join(f"not(between(n,{c['start_frame']},{c['end_frame']-1}))" for c in current["cuts"] if c["start_frame"] < raw_end) or "1"
    inputs, overlays, last = render_inputs(ROOT, 4, 0, end / 60, allow_tail_overlap=True)
    plate = ROOT.parent / "assets/fixtures/castle-composite"
    graph = ";".join([
        f"[0:v]select='{selection}',setpts=N/(60*TB),scale=1344:840:flags=lanczos,format=rgba[s]",
        "[s][2:v]alphamerge[w]", "[1:v][w]overlay=288:112:shortest=1[b]",
        "[b][3:v]overlay=299:132[film]", overlays,
        f"[{last}]trim=start_frame={start},setpts=N/(60*TB)[filetree]",
    ])
    chapter = work / "filetree.webm"
    render = ["ffmpeg", "-v", "error", "-y",
        "-i", REPO / current["take"] / "footage.mp4",
        "-loop", "1", "-framerate", "60", "-i", plate / "plate.png",
        "-loop", "1", "-framerate", "60", "-i", plate / "mask.png", "-i", plate / "traffic.png",
        *inputs, "-filter_complex", graph, "-map", "[filetree]", "-frames:v", end - start,
        "-an", *splice.codec("webm"), "-pix_fmt", "yuv420p",
        "-progress", work / "filetree.progress", chapter]
    if not args.reuse_chapter:
        splice.run(render)
    chapter_info = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-count_packets", "-show_entries", "stream=nb_read_packets", "-of", "json", str(chapter)]))
    assert int(chapter_info["streams"][0]["nb_read_packets"]) == end - start
    source = work / "original.webm"
    info = splice.probe(source)
    packets = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_packets", "-show_entries", "packet=pts_time,flags", "-of", "json", str(source)]))["packets"]
    origin = float(info.get("start_time", 0))
    keys = [round((float(p["pts_time"]) - origin) * 60) for p in packets if "K" in p["flags"]]
    prefix = splice.extract(source, 0, old_start, "webm", keys, "accepted-opening")
    suffix = splice.extract(source, old_end, old_total, "webm", keys, "accepted-later-scenes")
    joined = work / "joined.webm"
    splice.join([prefix, (chapter, end - start), suffix], joined)
    cues = json.loads((ROOT / "demo-narration-cues.json").read_text())["cues"]
    audio, mix = audio_inputs(ROOT, cues, total / 60)
    pending = work / "final.webm"
    splice.run(["ffmpeg", "-v", "error", "-y", "-i", joined, *audio, "-filter_complex", mix,
        "-map", "0:v:0", "-map", "[voice]", "-c:v", "copy",
        # Re-encoded GOP edges can retain a one-frame timestamp gap after
        # accurate seeking. Put copied packets on the 60 fps frame grid so
        # the final duration trim cannot drop the film's last frame.
        "-bsf:v", "setts=pts=N/(60*TB):dts=N/(60*TB):duration=1/(60*TB)", "-c:a", "libopus",
        # The audio graph already trims to the exact duration. An output -t
        # would discard packets using their timestamps before the filter.
        "-b:a", "128k", "-ac", "2", "-ar", "48000", pending])
    assert int(splice.probe(pending, count=True)["nb_read_frames"]) == total
    splice.run(["ffmpeg", "-v", "error", "-xerror", "-fflags", "+noparse+nofillin",
                "-i", pending, "-vn", "-f", "null", "-"])
    samples = [(t, t) for t in [7, 12, 16, 24]]
    samples += [(old_end / 60 + t, end / 60 + t) for t in [10, 45, 90, 150, 220, 300]]
    for before, after in samples:
        assert frame_hash(source, before) == frame_hash(pending, after), (before, after)
    pending.replace(OUT / "main-demo.webm")
    proof = {"frames": total, "filetree_range": [start, end], "previous_filetree_range": [old_start, old_end],
             "unchanged_frame_samples": samples, "audio_decode": "passed"}
    (work / "verification.json").write_text(json.dumps(proof, indent=2) + "\n")
    report = json.loads((OUT / "main-demo.webm.json").read_text())
    report.pop("continuous_desktop", None)
    report.update(frames=total, source_take=current["take"], output_bytes=(OUT / "main-demo.webm").stat().st_size,
                  filetree_refresh=proof, systemone_start_frame=round(routing["start"] * 60))
    report["video"]["assembly"] = "Updated filetree; accepted opening, Chromium, Android, Parallel and SystemOne copied"
    (OUT / "main-demo.webm.json").write_text(json.dumps(report, indent=2) + "\n")
    castle = json.loads((OUT / "main-demo.castle.json").read_text())
    castle.update(take=current["take"], desktop_frames=round(current["timeline_duration"] * 60),
                  cuts=current["cuts"], chapters=current["chapters"], result=splice.probe(OUT / "main-demo.webm"),
                  systemone=routing)
    (OUT / "main-demo.castle.json").write_text(json.dumps(castle, indent=2) + "\n")
    for extension in ["srt", "vtt"]:
        shutil.copyfile(ROOT / f"demo-subtitles.{extension}", OUT / f"main-demo.{extension}")
    print(f"Verified {total} frames; surrounding footage preserved at {len(samples)} sample points", flush=True)


if __name__ == "__main__":
    main()
