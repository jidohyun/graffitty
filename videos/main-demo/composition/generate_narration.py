#!/usr/bin/env python3
"""Generate the demo voiceover using GEMINI_API_KEY from the environment."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
from narration import store_flac

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--line", action="append", help="Generate this line ID; repeat for multiple lines, preserving other clips")
args = parser.parse_args()
root = Path(__file__).resolve().parent
request = json.loads((root / "demo-narration.json").read_text())
selected = [line for line in request["lines"] if not args.line or line["id"] in args.line]
if not selected:
    raise SystemExit("Unknown narration line")
api_key = os.environ.get("GEMINI_API_KEY", "").strip()
if not api_key:
    raise SystemExit("Set GEMINI_API_KEY in the environment before generating narration")
# Give the synthesizer the familiar spelling while retaining the product's
# exact name in the editable script. This avoids 'Gravity' at sentence
# endings.
#
# JEV is a spoken name, not an initialism; lowercase spelling plus phonetic
# direction prevents the synthesizer from reading its three letters aloud.
request["lines"] = []
for line in selected:
    spoken = {**line, "text": re.sub(r"\bJEV\b", "Jev", line["text"].replace("Graffitty", "graffiti"))}
    if re.search(r"\bJEV\b", line["text"]):
        spoken["style"] = line.get("style", request["style"]) + (
            " Pronounce Jev as a single syllable, /dʒɛv/, rhyming with rev."
            " Begin with the J sound in jet and end with the voiced V sound in very."
            " Say the name naturally as one word, never as separate letter names."
        )
    request["lines"].append(spoken)
cache = root / ".media/demo-narration"
cache.mkdir(parents=True, exist_ok=True)
request_path, result_path = cache / "request.json", cache / "result.json"
request_path.write_text(json.dumps(request, indent=2) + "\n")
env = {**os.environ, "GEMINI_API_KEY": api_key, "HYPERFRAMES_TTS_CONCURRENCY": "2"}
engine = Path.home() / ".agents/skills/media-use/audio/scripts/audio.mjs"
subprocess.run(["node", str(engine), "--request", str(request_path), "--hyperframes", str(root),
                "--out", str(result_path), "--only", "tts"], env=env, check=True)
result = json.loads(result_path.read_text())
if {voice["id"] for voice in result["voices"]} != {line["id"] for line in selected}:
    raise SystemExit("Gemini did not generate every requested line; inspect the audio engine's report")
originals = store_flac(root, result["voices"])
metadata = root / "demo-audio.json"
if args.line and metadata.exists():
    previous = json.loads(metadata.read_text())
    voices = {voice["id"]: voice for voice in previous["voices"]}
    voices.update({voice["id"]: voice for voice in result["voices"]})
    script_ids = {line["id"] for line in json.loads((root / "demo-narration.json").read_text())["lines"]}
    result["voices"] = [voice for id, voice in voices.items() if id in script_ids]
result.update(tts_model=request["tts_model"], source_request="demo-narration.json",
              storage_codec="flac",
              pronunciation={"Graffitty": "graffiti", "JEV": "Jev (/dʒɛv/), one syllable, rhymes with rev"},
              total_duration_s=round(sum(voice["duration_s"] for voice in result["voices"]), 3))
metadata.write_text(json.dumps(result, indent=2) + "\n")
for original in originals:
    original.unlink()
