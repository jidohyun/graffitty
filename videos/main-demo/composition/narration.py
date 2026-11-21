"""Align frozen Gemini narration to recorded workspace and chromium actions."""
import html
import json
from pathlib import Path
import re
import subprocess

VOICE_GAIN = 0.91201084  # -0.8 dB; retain headroom without changing delivery.


def store_flac(root: Path, voices: list):
    """Freeze generated PCM as FLAC and verify every decoded sample is identical.

    Return superseded files so the caller can remove them after saving metadata.
    """
    originals = []
    for voice in voices:
        source = root / voice["path"]
        if source.suffix == ".flac":
            continue
        target = source.with_suffix(".flac")
        temporary = target.with_suffix(".pending.flac")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(source),
                        "-map", "0:a:0", "-c:a", "flac", "-compression_level", "8",
                        str(temporary)], check=True)
        def pcm_hash(path):
            return subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(path),
                "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "hash", "-hash", "sha256", "-"])
        if pcm_hash(source) != pcm_hash(temporary):
            raise ValueError(f"FLAC changed decoded audio: {source}")
        temporary.replace(target)
        voice["path"] = str(target.relative_to(root))
        originals.append(source)
    return originals


def cues(root: Path, capture: dict, timeline_time):
    metadata = root / "demo-audio.json"
    if not metadata.exists():
        return []
    audio = json.loads(metadata.read_text())
    voices = {voice["id"]: voice for voice in audio["voices"]}
    beats = {beat["action"]: beat["frame"] / 60 for beat in capture["beats"]}
    native = capture.get("native_window")
    if not native:
        raise ValueError("Chromium narration requires the native-window scene")
    typing = {event['text']: event['key_frames'][0] / 60 for event in capture['typing_events'] if event['key_frames']}
    starts = {
        "intro": timeline_time(beats["One terminal in Main View"]) + .25,
        "workspace-space": timeline_time(beats["Workspace: zoom out"]) + .25,
        "workspace-status": timeline_time(beats["Workspace: pane status"]) + .25,
        "workspace-stash": timeline_time(beats["Workspace: stash old pane"]) + .25,
        "workspace-main": timeline_time(beats["Workspace: fit Main View"]) + .25,
        "workspace-pane": timeline_time(beats["Workspace: inspect stashed pane"]) + .25,
        "filetree-cwd": timeline_time(beats["Chapter: filetree"]),
        "filetree-rename": timeline_time(beats["Chapter: filetree: edit filenames like a vim buffer"]),
        # Lead in with the master's silence so "Opening" lands on the pointer move.
        "filetree-open": timeline_time(beats["Point to plan.txt"]) - voices["filetree-open"]["words"][0]["start"],
        "filetree-send-path": timeline_time(beats["Chapter: filetree: send paths to the terminal"]),
        "chromium-markdown": timeline_time(beats["Chapter: Chromium: markdown preview"]) + .25,
        "chromium-diagram": timeline_time(beats["Diagram: ask Claude for an explanation"]) + .25,
        "chromium-automation": timeline_time(beats["Automation: type test prompts"]),
        # Speak on the toolbar click, without a leading hold on the window.
        "chromium-native": timeline_time(beats.get("Native chromium control clicked", native["start_frame"] / 60)),
        "chromium-ownership": timeline_time(beats["Zoom out with both agents working"]) + .25,
        "tabs-summary": timeline_time(beats["Chapter: tabs: status at a glance"]) + .25,
        "command-line": timeline_time(beats["Chapter: command line: fuzzy finder built in"]) + .25,
    }
    limits = {
        "intro": timeline_time(beats["Workspace: zoom out"]),
        "workspace-space": timeline_time(beats["Workspace: pane status"]),
        "workspace-status": timeline_time(beats["Workspace: stash old pane"]),
        "workspace-stash": timeline_time(beats["Workspace: fit Main View"]),
        "workspace-main": timeline_time(beats["Workspace: inspect stashed pane"]),
        "workspace-pane": timeline_time(beats["Select the Filetree session"]),
        "filetree-cwd": timeline_time(beats["Chapter: filetree: edit filenames like a vim buffer"]),
        "filetree-rename": starts["filetree-open"],
        "filetree-open": timeline_time(beats["Chapter: filetree: send paths to the terminal"]),
        "filetree-send-path": timeline_time(beats["Chapter: Chromium: markdown preview"]),
        "chromium-markdown": timeline_time(beats["Chapter: Chromium: visual explanations"]),
        "chromium-diagram": timeline_time(beats["Chapter: Chromium: automation"]),
        # Faster recorded typing reveals both tests before this line ends.
        "chromium-automation": timeline_time(native["start_frame"] / 60),
        "tabs-summary": timeline_time(beats["Chapter: command line: fuzzy finder built in"]),
        "command-line": timeline_time(beats["Finished"]),
        # Continue directly into closing; finish over the embedded panes.
        "chromium-native": starts["chromium-ownership"],
        "chromium-ownership": timeline_time(beats["Fit to Main View while the agents continue"]),
    }
    result = []
    for id, start in starts.items():
        voice = voices[id]
        end = start + voice["duration_s"]
        if end > limits[id] + 1 / 60:
            raise ValueError(f"{id} outlasts its visual: {end:.3f} > {limits[id]:.3f}; record with narration holds")
        if id == "chromium-native" and abs(start - timeline_time(native["start_frame"] / 60)) > .25:
            raise ValueError("Native narration must coincide with the native window reveal")
        if not (root / voice["path"]).is_file():
            raise FileNotFoundError(voice["path"])
        result.append({"id": id, "path": voice["path"], "start": start,
                       "duration": voice["duration_s"], "end": end, "volume": VOICE_GAIN})
    return result


def compose(root: Path, capture: dict, timeline_time):
    placed = cues(root, capture, timeline_time)
    lines = ['    <!-- demo-narration:start -->']
    for cue in placed:
        lines.append(f'    <audio id="voice-{cue["id"]}" src="{html.escape(cue["path"])}" '
                     f'data-start="{cue["start"]:.6f}" data-duration="{cue["duration"]:.6f}" '
                     f'data-media-start="0" data-track-index="5" data-audio-group="voiceover" data-volume="{cue["volume"]}"></audio>')
    lines.append('    <!-- demo-narration:end -->')
    request = json.loads((root / "demo-narration.json").read_text())
    (root / "demo-narration-cues.json").write_text(json.dumps({
        "provider": request["provider"], "model": request["tts_model"],
        "voice": request["voice"], "cues": placed}, indent=2) + "\n")
    return "\n".join(lines)


def place_chapter(root: Path, chapter: str):
    """Add measured narration to reused chapter footage using its action cues."""
    plan = json.loads((root / "chapter-narration.json").read_text())[chapter]
    meta = json.loads((root / f"{chapter}-capture.json").read_text())
    voices = {v["id"]: v for v in json.loads((root / "demo-audio.json").read_text())["voices"]}
    if chapter == "android":
        take = root.parents[2] / meta["take"]
        beats = {b["action"]: b["seconds"] for b in json.loads((take / "beats.json").read_text())}
        # The finished phone clip has an unfold and a trimmed opening. Align
        # source beats to its measured wiring chapter, not the raw recording.
        shift = meta["chapters"][1]["start"] - meta["start"] - beats["Android: connect Turn completed to Receive"]
        beats = {name: at + shift for name, at in beats.items()}
    else:
        beats = {b["action"]: b["frame"] / 60 for b in meta["beats"]}
    new_cues = []
    for entry in plan:
        voice = voices[entry["id"]]
        anchor = beats[entry["beat"]] if "beat" in entry else 0
        start = meta["start"] + anchor + entry["offset"]
        end = start + voice["duration_s"]
        if start < meta["start"] or end > meta["start"] + meta["duration"] + 1 / 60:
            raise ValueError(f"{entry['id']} outlasts its chapter")
        if new_cues and start < new_cues[-1]["end"]:
            raise ValueError(f"{entry['id']} overlaps {new_cues[-1]['id']}; adjust chapter-narration.json")
        if not (root / voice["path"]).is_file() or not voice.get("words"):
            raise ValueError(f"{entry['id']} needs frozen audio and word timestamps")
        new_cues.append({"id": entry["id"], "path": voice["path"], "start": start,
                         "duration": voice["duration_s"], "end": end, "volume": VOICE_GAIN})
    path = root / "demo-narration-cues.json"
    placed = json.loads(path.read_text())
    placed["cues"] = sorted([c for c in placed["cues"] if not c["id"].startswith(chapter + "-")]
                            + new_cues, key=lambda c: c["start"])
    source = (root / "index.html").read_text()
    audio = ['    <!-- demo-narration:start -->']
    for cue in placed["cues"]:
        audio.append(f'    <audio id="voice-{cue["id"]}" src="{html.escape(cue["path"])}" '
                     f'data-start="{cue["start"]:.6f}" data-duration="{cue["duration"]:.6f}" '
                     f'data-media-start="0" data-track-index="5" data-audio-group="voiceover" data-volume="{cue["volume"]}"></audio>')
    audio.append('    <!-- demo-narration:end -->')
    source, count = re.subn(r'    <!-- demo-narration:start -->.*?<!-- demo-narration:end -->',
                            "\n".join(audio), source, flags=re.S)
    if count != 1:
        raise ValueError("Expected one narration block in the composition")
    path.write_text(json.dumps(placed, indent=2) + "\n")
    (root / "index.html").write_text(source)
    print(f"Placed {len(new_cues)} {chapter} narration clips")


def audio_inputs(root: Path, placed: list, duration: float, offset: float = 0):
    """Inputs and sample-accurate mix shared by the MP4 and WebM exports."""
    command = []
    filters = []
    for i, cue in enumerate(placed, 1):
        command += ["-i", str(root / cue["path"])]
        delay = round(cue["start"] * 48000)
        filters.append(f"[{i}:a]aresample=48000,volume={cue['volume']},adelay={delay}S:all=1[a{i}]")
    inputs = "".join(f"[a{i}]" for i in range(1, len(placed) + 1))
    count = len(placed)
    if (root / "music-profile.json").exists():
        from music import BED, validate
        profile = validate(root)
        if offset + duration > profile["duration"] + 1 / 60:
            raise ValueError("Music bed is shorter than the film; regenerate with music.py --prepare")
        count += 1
        command += ["-ss", str(offset), "-i", str(root / BED)]
        filters.append(f"[{count}:a]atrim=duration={duration:.9f},asetpts=PTS-STARTPTS[music]")
        inputs += "[music]"
    filters.append(f"{inputs}amix=inputs={count}:normalize=0,apad,atrim=duration={duration:.9f}[voice]")
    return command, ";".join(filters)


def mux(root: Path, video: Path, placed: list, duration: float):
    """Use the identical frozen clips and frame cues as the HyperFrames timeline."""
    if not placed:
        return
    temporary = video.with_suffix(".narrated.mp4")
    inputs, filters = audio_inputs(root, placed, duration)
    command = ["ffmpeg", "-v", "error", "-y", "-i", str(video), *inputs]
    command += ["-filter_complex", filters, "-map", "0:v:0", "-map", "[voice]",
                "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
                "-movflags", "+faststart", str(temporary)]
    subprocess.run(command, check=True)
    temporary.replace(video)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Place narration on reused Android and Parallel footage")
    parser.add_argument("--chapter", action="append", choices=["android", "parallel"])
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    for chapter in args.chapter or ["android", "parallel"]:
        place_chapter(root, chapter)
    from presentation import apply
    apply(root)
