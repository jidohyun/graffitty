#!/usr/bin/env python3
"""Exercise Android Keystore persistence on an attached phone without changing its client data.
Run after mise run android:build. Uses an isolated test application and removes it afterward.
"""
from pathlib import Path
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
GODOT_ROOT = ROOT / "frontends/godot/project"
STAGE = ROOT / "build/android/project"
PACKAGE = "com.graffitty.auth_test"


def main():
    sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    adb = [str(sdk / "platform-tools/adb")]
    if os.environ.get("ANDROID_SERIAL"):
        adb += ["-s", os.environ["ANDROID_SERIAL"]]
    project = STAGE / "project.godot"
    preset = STAGE / "export_presets.cfg"
    previous_project, previous_preset = project.read_text(), preset.read_text()
    (STAGE / "tests").mkdir(exist_ok=True)
    for name in ["credential_store_smoke.gd", "credential_store_smoke.tscn"]:
        shutil.copy2(GODOT_ROOT / "tests" / name, STAGE / "tests" / name)
    shutil.copy2(GODOT_ROOT / "scenes/remote/CredentialStore.gd", STAGE / "scenes/remote/CredentialStore.gd")
    apk = ROOT / "build/android/credential-test.apk"
    try:
        project.write_text(previous_project.replace('run/main_scene.android="res://scenes/remote_manager.tscn"', 'run/main_scene.android="res://tests/credential_store_smoke.tscn"'))
        preset.write_text(previous_preset.replace("com.graffitty.client", PACKAGE).replace("tests/*,", ""))
        subprocess.run(["godot", "--headless", "--path", str(STAGE), "--export-debug", "Android", str(apk)], check=True)
    finally:
        project.write_text(previous_project)
        preset.write_text(previous_preset)
    # Only this tool's disposable test application is reset, never the user's client.
    subprocess.run(adb + ["uninstall", PACKAGE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(adb + ["install", "--no-incremental", str(apk)], check=True)
    try:
        for expected in ["PASS saved in OS credential store; restart for retrieval", "PASS retrieved after restart and deleted"]:
            subprocess.run(adb + ["shell", "am", "start", "-W", "--user", "0", "-n", PACKAGE + "/com.godot.game.GodotAppLauncher"], check=True)
            deadline = time.monotonic() + 30
            result = ""
            while time.monotonic() < deadline:
                result = subprocess.run(adb + ["shell", "run-as", PACKAGE, "cat", "files/credential-test-result"], text=True, capture_output=True).stdout.strip()
                if result == expected or result.startswith("FAIL"):
                    break
                time.sleep(.25)
            assert result == expected, result or "Credential test timed out"
            print(result, flush=True)
            time.sleep(1)
    finally:
        subprocess.run(adb + ["uninstall", PACKAGE], check=True)


if __name__ == "__main__":
    main()
