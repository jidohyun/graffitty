#!/usr/bin/env python3
"""Render a HyperFrames project into the shared video artifact directory."""
import argparse
import json
from pathlib import Path
import re
import subprocess

from video_artifacts import artifact_path, export_path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--project", type=Path, default=Path.cwd())
parser.add_argument("--output", "-o", type=Path)
parser.add_argument("--filename", help="Export filename within the project's artifact directory")
parser.add_argument("--dry-run", action="store_true", help="Print the command without rendering")
args, forwarded = parser.parse_known_args()
project = args.project.resolve()
package = json.loads((project / "package.json").read_text())
pin = re.search(r"hyperframes@([0-9.]+)", package["scripts"]["check"])
if pin is None:
    parser.error("The project's check script must pin its HyperFrames version")
project_name = package.get("name", project.parent.name if project.name == "composition" else project.name)
requested_format = None
for i, option in enumerate(forwarded):
    if option.startswith("--format="):
        requested_format = option.split("=", 1)[1]
    elif option == "--format" and i + 1 < len(forwarded):
        requested_format = forwarded[i + 1]
extension = "." + (requested_format or "webm")
filename = project_name + extension
for i, option in enumerate(forwarded):
    if option.startswith("--composition="):
        filename = Path(option.split("=", 1)[1]).stem + extension
    elif option == "--composition" and i + 1 < len(forwarded):
        filename = Path(forwarded[i + 1]).stem + extension
if args.filename:
    if args.output or Path(args.filename).name != args.filename:
        parser.error("--filename needs a basename and cannot be combined with --output")
    filename = args.filename
try:
    output = export_path(args.output or artifact_path(project_name, filename))
except ValueError as error:
    parser.error(str(error))
if requested_format is None:
    forwarded += ["--format", output.suffix.removeprefix(".") or "webm"]
command = ["bunx", "hyperframes@" + pin.group(1), "render", *forwarded, "--output", str(output)]
if args.dry_run:
    print(json.dumps({"cwd": str(project), "command": command, "output": str(output)}, indent=2))
else:
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(command, cwd=project, check=True)
