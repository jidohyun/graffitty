#!/usr/bin/env python3
"""Test real Android capture/drain and Opus in an isolated app, without provider calls.

Run after tools/build_android.py. Only sample counts/codec sizes are saved;
microphone audio stays in memory. The user's production client is untouched.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "frontends/godot/project"
PACKAGE = "com.graffitty.dictation_test"


def main():
    root = Path(tempfile.mkdtemp(prefix="graffitty-android-dictation-"))
    project = root / "project"
    project.mkdir()
    print(f"Evidence: {root}", flush=True)
    # A minimal project exercises the exact native library built for production.
    addons = project / "addons/graffitty"
    (addons / "bin").mkdir(parents=True)
    shutil.copy2(SOURCE / "addons/graffitty/graffitty.gdextension", addons)
    shutil.copy2(SOURCE / "addons/graffitty/bin/libgraffitty.android.arm64.so", addons / "bin")
    # The host editor needs its own library to resolve GDExtension classes when exporting.
    for library in (SOURCE / "addons/graffitty/bin").glob("libgraffitty.*"):
        if library.suffix in {".dylib", ".dll"} or library.name.endswith("linux.x86_64.so"):
            shutil.copy2(library, addons / "bin")
    (project / "tests").mkdir()
    shutil.copy2(SOURCE / "tests/android_dictation_smoke.gd", project / "tests")
    (project / "tests/main.tscn").write_text('''[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://tests/android_dictation_smoke.gd" id="1"]
[node name="Test" type="Node"]
script = ExtResource("1")
''')
    (project / "project.godot").write_text('''config_version=5
[application]
config/name="Dictation test"
run/main_scene="res://tests/main.tscn"
[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
textures/vram_compression/import_etc2_astc=true
''')
    # Register the Android extension without attempting to load it on the host.
    (project / ".godot").mkdir()
    (project / ".godot/extension_list.cfg").write_text("res://addons/graffitty/graffitty.gdextension\n")
    presets = (SOURCE / "export_presets.cfg").read_text()
    presets = presets.replace("com.graffitty.client", PACKAGE).replace("tests/*,", "")
    # The disposable app uses default icons and has no production asset dependencies.
    presets = "\n".join(line for line in presets.splitlines() if not line.startswith("launcher_icons/"))
    (project / "export_presets.cfg").write_text(presets)
    apk = root / "dictation-test.apk"
    with (root / "export.log").open("w") as log:
        subprocess.run(["godot", "--headless", "--path", str(project), "--export-debug", "Android", str(apk)],
                       check=True, stdout=log, stderr=subprocess.STDOUT)
    adb = ["adb"]
    if os.environ.get("ANDROID_SERIAL"):
        adb += ["-s", os.environ["ANDROID_SERIAL"]]
    subprocess.run(adb + ["wait-for-device"], check=True, timeout=30)
    subprocess.run(adb + ["install", "--no-incremental", "-r", str(apk)], check=True)
    try:
        subprocess.run(adb + ["shell", "pm", "grant", PACKAGE, "android.permission.RECORD_AUDIO"], check=True)
        subprocess.run(adb + ["shell", "am", "start", "-W", "--user", "0", "-n",
                              PACKAGE + "/com.godot.game.GodotAppLauncher"], check=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            result = subprocess.run(adb + ["shell", "run-as", PACKAGE, "cat", "files/dictation-test-result.json"],
                                    text=True, capture_output=True)
            if result.returncode == 0:
                report = json.loads(result.stdout)
                (root / "result.json").write_text(json.dumps(report, indent=2) + "\n")
                print(json.dumps(report, indent=2), flush=True)
                assert report["passed"], report["failures"]
                return
            time.sleep(0.25)
        raise RuntimeError("Android dictation test timed out")
    finally:
        subprocess.run(adb + ["uninstall", PACKAGE], check=True)


if __name__ == "__main__":
    main()
