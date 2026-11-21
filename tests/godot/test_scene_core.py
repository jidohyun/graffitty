"""Verify the portable scene core against its tests and frozen Godot behavior."""
from pathlib import Path
import os
import subprocess
import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tools",)]
from check_godot import failed

ROOT = Path(__file__).resolve().parents[2]

def main() -> None:
    subprocess.run(["cargo", "test", "--locked", "-p", "graffitty-scene-core"], cwd=ROOT, check=True)
    env = os.environ.copy()
    # Verification must never overwrite its independent behavioral reference.
    env.pop("GRAFFITTY_SCENE_REFERENCE", None)
    result = subprocess.run(
        [env.get("GODOT", "godot"), "--headless", "--path", str(ROOT / "frontends/godot/project"),
         "--script", "res://tests/scene_core_conformance.gd"],
        cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120,
    )
    print(result.stdout, end="")
    if failed(result.returncode, result.stdout) or "SCENE_CORE_CONFORMANCE PASS" not in result.stdout:
        raise SystemExit("Scene core conformance failed")

if __name__ == "__main__":
    main()
