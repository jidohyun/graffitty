"""Build the named macOS capture app and encode its frame-synchronized images."""
from contextlib import contextmanager
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[4]
APP = ROOT / ".cache/native-window-demo/Graffitty Demo Capture.app"


def build():
    executable = APP / "Contents/MacOS/native-window-capture"
    source = Path(__file__).with_name("native_window.swift")
    if not executable.exists() or source.stat().st_mtime > executable.stat().st_mtime:
        executable.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(executable)], check=True)
        (APP / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.graffitty.demo-capture",
            "CFBundleName": "Graffitty Demo Capture",
            "CFBundleDisplayName": "Graffitty Demo Capture",
            "CFBundleExecutable": executable.name,
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
        }))
        # A stable designated identity keeps consent attached to this local
        # capture app when its executable is rebuilt during development.
        subprocess.run(["codesign", "--force", "--sign", "-",
                        "--identifier", "com.graffitty.demo-capture",
                        "--requirements", '=designated => identifier "com.graffitty.demo-capture"', str(APP)], check=True,
                       stdout=subprocess.DEVNULL)
    return APP


@contextmanager
def capture_app(output):
    """Launch through LaunchServices so macOS attributes consent to this app."""
    directory = output / "native-window"
    directory.mkdir()
    process = subprocess.Popen(["open", "-n", "-W", str(build()), "--args", str(directory)])
    try:
        deadline = time.monotonic() + 15
        while not (directory / "ready.json").exists():
            response = directory / "response.json"
            if response.exists():
                raise RuntimeError(json.loads(response.read_text()).get("error", "Native capture failed"))
            if process.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError("Graffitty Demo Capture did not start; enable its Screen Recording access")
            time.sleep(.05)
        yield directory
    finally:
        (directory / "stop").touch()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)


def encode(output):
    directory = output / "native-window"
    metadata = json.loads((directory / "capture.json").read_text())
    frames = metadata["end_frame"] - metadata["start_frame"]
    paths = sorted(directory.glob("[0-9]*.png"))
    expected = [f"{frame:06d}.png" for frame in range(metadata["start_frame"], metadata["end_frame"])]
    if [p.name for p in paths] != expected:
        raise RuntimeError("Native capture is missing or duplicating Movie Maker frames")
    shutil.copyfile(paths[0], output / "native-window-shape.png")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-framerate", "60",
                    "-start_number", str(metadata["start_frame"]), "-i", str(directory / "%06d.png"),
                    "-frames:v", str(frames), "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                    "-an", "-c:v", "libx264", "-crf", "15", "-preset", "fast", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(output / "native-window.mp4")], check=True)
    return metadata


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request-access", action="store_true")
    args = parser.parse_args()
    app = build()
    print(app)
    if args.request_access:
        subprocess.run(["open", "-n", str(app), "--args", "--request-access"], check=True)
