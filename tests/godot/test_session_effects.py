#!/usr/bin/env python3
# /// script
# dependencies = ["Pillow>=12,<13"]
# ///
"""Real session effects and immediate resource stats on an owned private server.

Build the Godot extension first. GRAFFITTY_TEST_SERVER selects the fixture gft;
GODOT selects the renderer. No live user sessions are attached or restarted.
"""
import argparse
from contextlib import nullcontext
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from e2e_background import prepare_background, background_failures

ROOT = Path(__file__).resolve().parents[2]


def verify_landing(evidence):
    """Compare actual colored pixels, including every frame of the live handoff."""
    from PIL import Image

    def marks(path):
        with Image.open(path) as image:
            data = image.convert("RGB").tobytes()
        pixels = list(zip(data[0::3], data[1::3], data[2::3]))
        return [
            {i for i, (r, g, b) in enumerate(pixels) if b > 160 and
             ((r > 160 and g < 100) if magenta else (g > 160 and r < 100))}
            for magenta in (True, False)
        ]

    metrics = {}
    for reference in sorted(evidence.glob("*-live-5.png")):
        prefix = reference.name.removesuffix("live-5.png")
        expected = marks(reference)
        assert all(len(mark) > 100 for mark in expected), reference
        for label in ("destination", "landed", *(f"live-{i}" for i in range(6))):
            frame = evidence / (prefix + label + ".png")
            scores = [len(actual & target) / len(actual | target)
                      for actual, target in zip(marks(frame), expected)]
            metrics[frame.stem] = scores
    assert metrics, "No landing frames captured"
    (evidence / "pixel-comparison.json").write_text(json.dumps(metrics, indent=2) + "\n")
    for frame, scores in metrics.items():
        assert min(scores) >= .96, f"{frame}: landed/live marker overlap {scores}"
    print(f"PASS {len(metrics)} landing frames: marker overlap >= 96%")


def verify_graph_landing(evidence):
    """Check visible wire and badge ink across every frame of the handoff."""
    from PIL import Image, ImageFilter

    def masks(path):
        with Image.open(path) as image:
            image = image.convert("RGB")
        masks = [Image.new("L", image.size) for _ in range(2)]
        rgb = list(image.getdata())
        masks[0].putdata([255 if r > 150 and 60 < g < 170 and b < 130 and r > g * 1.2 else 0 for r, g, b in rgb])
        masks[1].putdata([255 if 60 < r < 160 and g > 160 and b < 170 and index // image.width > image.height * .35 else 0
                          for index, (r, g, b) in enumerate(rgb)])
        return masks

    def pixels(mask, tolerance=0):
        if tolerance:
            mask = mask.filter(ImageFilter.MaxFilter(tolerance * 2 + 1))
        return {index for index, value in enumerate(mask.getdata()) if value}

    metrics = {}
    for reference in sorted(evidence.glob("*-live-5.png")):
        prefix = reference.name.removesuffix("live-5.png")
        expected = masks(reference)
        assert all(len(pixels(mask)) > 150 for mask in expected), reference
        for label in ("landed", *(f"live-{i}" for i in range(6))):
            scores = []
            for actual, target in zip(masks(evidence / (prefix + label + ".png")), expected):
                a, b = pixels(actual), pixels(target)
                # Rasterization may move an antialiased edge by one pixel.
                precision = len(a & pixels(target, 1)) / max(1, len(a))
                recall = len(b & pixels(actual, 1)) / len(b)
                scores.append(min(precision, recall))
            metrics[prefix + label] = scores
    assert metrics, "No graph handoff frames captured"
    (evidence / "graph-pixel-comparison.json").write_text(json.dumps(metrics, indent=2) + "\n")
    for frame, scores in metrics.items():
        assert min(scores) >= .95, f"{frame}: badge/wire coverage {scores}"
    print(f"PASS {len(metrics)} graph handoff frames: badge/wire coverage >= 95%")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--case", choices=("effects", "landing", "graph-landing", "adaptive"), default="effects")
    args = parser.parse_args()
    if args.evidence:
        args.evidence.mkdir(parents=True, exist_ok=False)
    # macOS's default temporary path can exceed Unix socket path limits.
    folder = nullcontext(args.evidence) if args.evidence else tempfile.TemporaryDirectory(prefix="gfx-", dir="/tmp" if os.name != "nt" else None)
    with folder as temporary:
        directory = Path(temporary)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "GFT_", "CODEX_"))}
        env["GRAFFITTY_EFFECT_FIXTURE"] = "1"
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
        with PrivateServer(env, directory, "pwsh.exe" if os.name == "nt" else "/bin/sh") as owner:
            for name in ("alpha", "beta"):
                subprocess.run([str(owner.binary), "session", "new", "-d", "-s", name], env=env, check=True, timeout=20)
            script = {"landing": "session_landing_smoke.gd", "graph-landing": "session_graph_landing_smoke.gd", "effects": "session_effects_smoke.gd", "adaptive": "adaptive_projection_smoke.gd"}[args.case]
            evidence = directory / Path(script).stem
            evidence.mkdir()
            env["GRAFFITTY_TEST_EVIDENCE"] = str(evidence)
            graphics = []
            if sys.platform == "darwin":
                graphics = prepare_background(env, evidence / "guard")
            with (evidence / "godot.log").open("w") as log:
                result = subprocess.run([os.environ.get("GODOT", "godot"), *graphics,
                                         "--path", str(ROOT / "frontends/godot/project"),
                                         "--script", "tests/" + script], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=95)
            output = (evidence / "godot.log").read_text()
            print(output)
            assert result.returncode == 0 and "ERROR:" not in output, evidence
            if args.case == "landing":
                verify_landing(evidence)
            if args.case == "graph-landing":
                verify_graph_landing(evidence)
            if graphics:
                assert not background_failures(evidence / "guard"), background_failures(evidence / "guard")


if __name__ == "__main__":
    main()
