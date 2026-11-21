"""Run the terminal IME's native InputConnection regression on an Android device.

Uses a disposable instrumentation APK; no Graffitty or keyboard app data is changed.
Usage: python3 tests/android/test_android_ime.py --serial emulator-5554
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tools",)]
from mise_tasks import android_sdk

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = "com.graffitty.ime_test"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--keyboard-extension-apk", type=Path,
                        help="Also exercise the actual SwiftKey Polyglot connector from a debug extension APK")
    args = parser.parse_args()
    sdk = android_sdk()
    android = (
        max(
            (sdk / "platforms").glob("android-*"),
            key=lambda p: int(p.name.split("-")[1]),
        )
        / "android.jar"
    )
    build_tools = max(
        (sdk / "build-tools").iterdir(),
        key=lambda p: tuple(map(int, p.name.split("."))),
    )
    javac = shutil.which("javac")
    homebrew = Path("/opt/homebrew/opt/openjdk/bin/javac")
    if homebrew.exists():
        javac = str(homebrew)
    if not javac:
        raise RuntimeError("A JDK is required")
    java_bin = Path(javac).resolve().parent
    env = dict(os.environ, JAVA_HOME=str(java_bin.parent))
    adb = ["adb", "-s", args.serial]

    def run(*command, **kwargs):
        return subprocess.run(
            list(map(str, command)), check=True, env=env, timeout=120, **kwargs
        )

    with tempfile.TemporaryDirectory(prefix="graffitty-ime-test-") as scratch:
        work = Path(scratch)
        classes = work / "classes"
        classes.mkdir()
        sources = list((ROOT / "frontends/godot/android/tests").rglob("*.java"))
        sources.extend((ROOT / "frontends/godot/android/src").rglob("*.java"))
        run(javac, "--release", "8", "-cp", android, "-d", classes, *sources)
        run(
            build_tools / "d8",
            "--min-api",
            "28",
            "--lib",
            android,
            "--output",
            work,
            *classes.rglob("*.class"),
        )
        manifest = work / "AndroidManifest.xml"
        manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{PACKAGE}">
<uses-sdk android:minSdkVersion="28" android:targetSdkVersion="35"/>
<application android:theme="@android:style/Theme.Material.Light.NoActionBar">
<activity android:name=".TerminalImeTest$EditorActivity" android:exported="true"/>
<provider android:name=".ImageProvider" android:authorities="com.graffitty.ime_test.images" android:exported="false"/>
</application>
<instrumentation android:name=".TerminalImeTest" android:targetPackage="{PACKAGE}"/>
</manifest>''')
        unsigned = work / "unsigned.apk"
        apk = work / "test.apk"
        run(
            build_tools / "aapt",
            "package",
            "-f",
            "-M",
            manifest,
            "-I",
            android,
            "-F",
            unsigned,
        )
        with zipfile.ZipFile(
            unsigned, "a", compression=zipfile.ZIP_DEFLATED
        ) as archive:
            archive.write(work / "classes.dex", "classes.dex")
            if args.keyboard_extension_apk:
                with zipfile.ZipFile(args.keyboard_extension_apk) as keyboard:
                    dex = sorted(name for name in keyboard.namelist()
                                 if name.startswith("classes") and name.endswith(".dex"))
                    if not dex:
                        raise RuntimeError("Keyboard extension APK contains no DEX")
                    for index, name in enumerate(dex, 2):
                        archive.writestr(f"classes{index}.dex", keyboard.read(name))
        run(build_tools / "zipalign", "-f", "4", unsigned, apk)
        keystore = work / "test.jks"
        run(
            java_bin / "keytool",
            "-genkeypair",
            "-keystore",
            keystore,
            "-storepass",
            "android",
            "-keypass",
            "android",
            "-alias",
            "test",
            "-dname",
            "CN=Graffitty IME test",
            "-keyalg",
            "RSA",
            "-validity",
            "1",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        run(
            build_tools / "apksigner",
            "sign",
            "--ks",
            keystore,
            "--ks-pass",
            "pass:android",
            apk,
        )
        run(*adb, "install", "--no-incremental", "-r", apk)
        try:
            result = run(
                *adb,
                "shell",
                "am",
                "instrument",
                "-w",
                "-r",
                f"{PACKAGE}/.TerminalImeTest",
                capture_output=True,
                text=True,
            )
            print(result.stdout, end="")
            if (
                "PASS:" not in result.stdout
                or "INSTRUMENTATION_CODE: -1" not in result.stdout
            ):
                raise RuntimeError("Native IME regression failed")
            if args.keyboard_extension_apk and "actual SwiftKey connector" not in result.stdout:
                raise RuntimeError("SwiftKey connector was not exercised; supply its debug extension APK")
        finally:
            run(*adb, "uninstall", PACKAGE)


if __name__ == "__main__":
    main()
