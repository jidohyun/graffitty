#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2"]
# ///
"""Run Android-only cases and retain evidence. Unautomated procedures stay BLOCKED.
Uses disposable packages, never the installed Graffitty client's data.
"""
from __future__ import annotations

import argparse
import atexit
import hashlib
from contextlib import contextmanager, ExitStack
from urllib.parse import urlparse
import json
import os
import re
import shlex
import xml.etree.ElementTree as ET
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tempfile
import tomllib
import traceback

sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from e2e_background import background_failures, clear_background, prepare_background
from e2e_server import PrivateServer

ROOT = Path(__file__).resolve().parents[2]
GODOT_ROOT = ROOT / "frontends/godot/project"
SUITE = ROOT / "tests/llm-e2e/suites/shared/android-runtime"
PACKAGE = "com.graffitty.runtime_test"
APK_CACHE: Path | None = None


class DeviceApkCache:
    """Upload each complete APK once; every case still installs a fresh package."""
    def __init__(self, adb):
        self.adb = adb
        self.uploaded = set()
        self.paths = set()
        atexit.register(self.close)

    def __call__(self, adb, apk):
        with apk.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        remote = f"/data/local/tmp/graffitty-e2e-{os.getpid()}-{digest}.apk"
        self.paths.add(remote)
        if digest in self.uploaded:
            try:
                run(adb + ["shell", "test", "-r", remote], capture_output=True, timeout=30)
            except subprocess.CalledProcessError:
                self.uploaded.discard(digest)
        if digest not in self.uploaded:
            run(adb + ["push", "-z", "zstd", str(apk), remote], capture_output=True, timeout=INSTALL_TIMEOUT)
            self.uploaded.add(digest)
        # PackageManager receives the complete local file, never an incremental
        # stream. smoke() uninstalls before and after every case as usual.
        installed = run(adb + ["shell", "pm", "install", "--user", "0", remote], capture_output=True, text=True, timeout=INSTALL_TIMEOUT)
        assert installed.stdout.strip() == "Success", installed.stdout + installed.stderr

    def close(self):
        for remote in self.paths:
            subprocess.run(self.adb + ["shell", "rm", "-f", remote], capture_output=True, timeout=30)
        self.paths.clear()


def run(command, timeout=120, **kwargs):
    return subprocess.run(command, check=True, timeout=timeout, **kwargs)


# A ~130 MB APK over a remote ADB link (for example Tailscale) can take minutes.
INSTALL_TIMEOUT = 900


def capture_screen(adb, destination):
    data = run(adb + ["exec-out", "screencap", "-p"], capture_output=True).stdout
    # Foldables can prepend a multiple-display warning to the PNG on stdout.
    start = data.find(b"\x89PNG\r\n\x1a\n")
    assert start >= 0, "Android screenshot did not return a PNG"
    destination.write_bytes(data[start:])


def link_apk(source, target):
    # Artifacts are immutable. Replace the directory entry before a new export,
    # so rerunning a case cannot overwrite another case's linked evidence.
    target.unlink(missing_ok=True)
    try:
        os.link(source, target)
    except OSError:
        shutil.copy2(source, target)


def export_smoke(output):
    global APK_CACHE
    cached = output.parent / "runtime-test.apk"
    if APK_CACHE == cached and cached.exists():
        link_apk(cached, output / "runtime-test.apk")
        return
    # Scenario scripts are loaded by name at runtime, so checking only the
    # entry script misses their errors until after the expensive APK transfer.
    scripts = [GODOT_ROOT / "tests/android_runtime_smoke.gd",
               *sorted((GODOT_ROOT / "tests/client_scenarios").glob("*.gd"))]
    with (output / "parse.log").open("w") as parse_log:
        for script in scripts:
            parsed = run(["godot", "--headless", "--path", str(GODOT_ROOT), "--script",
                          str(script), "--check-only"], capture_output=True, text=True)
            diagnostic = parsed.stdout + parsed.stderr
            parse_log.write(str(script.relative_to(GODOT_ROOT)) + "\n" + diagnostic)
            parse_log.flush()
            assert "SCRIPT ERROR" not in diagnostic and "ERROR:" not in diagnostic, diagnostic
    stage = ROOT / "build/android/project"
    project, preset = stage / "project.godot", stage / "export_presets.cfg"
    previous_project, previous_preset = project.read_text(), preset.read_text()
    (stage / "tests").mkdir(exist_ok=True)
    for name in ["android_runtime_smoke.gd", "android_runtime_smoke.tscn", "diagnostic_guard.gd"]:
        shutil.copy2(GODOT_ROOT / "tests" / name, stage / "tests" / name)
    replay = Path("tests/llm-e2e/replay")
    (stage / replay).mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / replay / "background.gd", stage / replay / "background.gd")
    # Instrument the current application scripts, not a hand-picked subset of
    # whichever sources happened to be staged by an earlier production build.
    shutil.copytree(GODOT_ROOT / "scenes", stage / "scenes", dirs_exist_ok=True)
    shutil.copytree(GODOT_ROOT / "tests/client_scenarios", stage / "tests/client_scenarios", dirs_exist_ok=True)
    # APK fixtures carry the shared guard as a build resource. Host source
    # scripts refer directly to the repository suite outside the project.
    for script in (stage / "tests/client_scenarios").glob("*.gd"):
        text = script.read_text()
        text = text.replace('"../../../../../tests/llm-e2e/replay/background.gd"',
                            '"res://tests/llm-e2e/replay/background.gd"')
        text = text.replace('"../../../../../../tests/llm-e2e/replay/background.gd"',
                            '"res://tests/llm-e2e/replay/background.gd"')
        script.write_text(text)
    try:
        needle = 'run/main_scene.android="res://scenes/remote_manager.tscn"'
        assert needle in previous_project, "Android entry scene missing from staging project"
        project.write_text(previous_project.replace(needle, 'run/main_scene.android="res://tests/android_runtime_smoke.tscn"'))
        preset.write_text(previous_preset.replace("com.graffitty.client", PACKAGE).replace("tests/*,", ""))
        (output / "runtime-test.apk").unlink(missing_ok=True)
        # Godot names intermediate APKs with second-resolution timestamps.
        # Another export must not overwrite the ZIP while apksigner reads it.
        with tempfile.TemporaryDirectory(prefix="graffitty-apk-") as temporary, (output / "export.log").open("w") as log:
            env = {**os.environ, "TMPDIR": temporary, "TMP": temporary, "TEMP": temporary}
            run(["godot", "--headless", "--path", str(stage), "--export-debug", "Android", str(output / "runtime-test.apk")], stdout=log, stderr=subprocess.STDOUT, env=env)
        link_apk(output / "runtime-test.apk", cached)
        APK_CACHE = cached
    finally:
        project.write_text(previous_project)
        preset.write_text(previous_preset)


class NativeInputUnavailable(RuntimeError):
    """The installed IME does not expose the configured acceptance layout."""


def gboard_english(adb, device):
    """Select Gboard's English fixture layout independently of the previous case."""
    ime = run(adb + ["shell", "settings", "get", "secure", "default_input_method"], capture_output=True, text=True).stdout.strip()
    if not ime.startswith("com.google.android.inputmethod.latin/"):
        return
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if device(packageName="com.google.android.inputmethod.latin", descriptionMatches="[aA]").exists:
            return
        if device(description="히읗").exists:
            switch = device(descriptionMatches="Next language|다음 언어")
            if switch.exists:
                switch.click()
        time.sleep(.2)
    raise AssertionError("Gboard English key grid did not appear")


def tap_ime_key(adb, device, output, label):
    """Wait for the actual IME key grid, ignoring matching prediction chips."""
    ime = run(adb + ["shell", "settings", "get", "secure", "default_input_method"], capture_output=True, text=True).stdout.strip().split("/")[0]
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        xml = device.dump_hierarchy()
        matches = []
        for node in ET.fromstring(xml).iter("node"):
            if node.get("package") != ime:
                continue
            values = [node.get("content-desc", "").lower(), node.get("text", "").lower()]
            if ime in {"com.touchtype.swiftkey", "app.polyglot.swiftkey"} and len(label) == 1:
                values = [value.removeprefix("capital ") for value in values]
            if any(value == label.lower() or value.startswith(label.lower() + ",") for value in values):
                bounds = list(map(int, re.findall(r"\d+", node.get("bounds", ""))))
                if len(bounds) == 4:
                    matches.append(bounds)
        if matches:
            # Both SwiftKey and Gboard place suggestions above the letter grid.
            b = max(matches, key=lambda bounds: bounds[1])
            run(adb + ["shell", "input", "tap", str((b[0] + b[2]) // 2), str((b[1] + b[3]) // 2)], capture_output=True)
            (output / "ui.xml").write_text(xml)
            return
        time.sleep(.2)
    (output / "missing-ime-key.xml").write_text(xml)
    raise AssertionError("Installed IME key missing: " + label)


def native_shortcuts(adb, output, device, state_until, tap_target, command):
    """Exercise the installed IME and Android input bridge, without Godot key injection."""
    ime = run(adb + ["shell", "settings", "get", "secure", "default_input_method"], capture_output=True, text=True).stdout.strip()
    assert ime.startswith("com.google.android.inputmethod.latin/"), "This native shortcut case requires Gboard in English"
    assertions = []

    def key(label):
        # Use the installed keyboard's accessibility labels and geometry;
        # tablet Gboard does not publish the phone layout's key_pos IDs.
        tap_ime_key(adb, device, output, label)
        time.sleep(.15)

    def accessory(symbol, expected):
        tap_target("Ctrl")
        state_until(lambda s: s["ctrl_armed"])
        key(symbol)
        state_until(lambda s: s["font_size"] == expected and not s["ctrl_armed"] and s["terminal_focus"])
        assertions.append("Accessory Ctrl + Gboard " + symbol + " changes the focused terminal font")

    def chord(*codes):
        run(adb + ["shell", "input", "keycombination", "-t", "150", *map(str, codes)], capture_output=True)

    tap_target("KeyboardButton")
    initial = state_until(lambda s: s["keyboard_height"] > 0 and s["keybar_visible"] and s["terminal_focus"])
    gboard_english(adb, device)
    base = initial["font_size"]
    assert base > 0, "Focused terminal font size is missing"
    key("Symbol keyboard")
    # Tablet Gboard exposes Equals on the first symbol page; the phone
    # layout places it behind More symbols. Inspect the installed layout.
    more_symbols = not device(packageName="com.google.android.inputmethod.latin", description="Equals").exists
    if more_symbols:
        key("More symbols")
    accessory("Equals", base + 2)
    capture_screen(adb, output / "native-ctrl-equals.png")
    if more_symbols:
        key("Symbols")
    accessory("Plus", base + 4)
    accessory("Dash", base + 2)
    accessory("0", base)
    key("Letter keyboard")
    for letter in "hello":
        key(letter)
    # Switching an IME's symbol page can finish pending composition. It must
    # not consume the app's armed Ctrl before the intended equals character.
    tap_target("Ctrl")
    state_until(lambda s: s["ctrl_armed"])
    key("Symbol keyboard")
    if more_symbols:
        key("More symbols")
    key("Equals")
    state_until(lambda s: s["font_size"] == base + 2 and not s["ctrl_armed"])
    assertions.append("Ctrl survives the IME symbol-page change after typing a word")
    key("Letter keyboard")
    # Android key codes: Ctrl-left, Shift-left, equals, plus, minus, zero.
    for codes, expected in [((113, 70), base + 4), ((113, 59, 70), base + 6),
                            ((113, 81), base + 8), ((113, 69), base + 6), ((113, 7), base)]:
        chord(*codes)
        state_until(lambda s: s["font_size"] == expected and s["terminal_focus"])
    assertions.append("Native Android Ctrl+=, Ctrl+Shift+=, Ctrl++, Ctrl+-, and Ctrl+0 change/reset font size")

    # Fixture setup may use send_text; all three measured inputs below come
    # through actual Android keyboard events. Reading raw PTY bytes distinguishes
    # a working modifier from a button that only looks pressed.
    code = """import os, select, sys, termios, time, tty
fd = 0
old = termios.tcgetattr(fd)
data = b''
count, tag = int(sys.argv[1]), sys.argv[2]
try:
    tty.setraw(fd)
    print(tag + '_READER_READY', flush=True)
    deadline = time.monotonic() + 60
    while len(data) < count and time.monotonic() < deadline:
        if select.select([fd], [], [], .25)[0]:
            data += os.read(fd, count - len(data))
finally:
    termios.tcsetattr(fd, termios.TCSANOW, old)
print('\\r\\n' + tag + '_BYTES=' + data.hex(), flush=True)
"""
    command("text", text="\x15python3 -c " + shlex.quote(code) + " 3 NATIVE_CTRL\r")
    # The ready marker can also appear in the echoed command. Match a complete
    # output line so native input cannot race ahead of tty.setraw().
    state_until(lambda s: any(line.strip() == "NATIVE_CTRL_READER_READY" for line in s.get("text", "").splitlines()))
    tap_target("Ctrl")
    state_until(lambda s: s["ctrl_armed"])
    key("u")
    state_until(lambda s: not s["ctrl_armed"])
    key("u")
    chord(113, 49)
    final = state_until(lambda s: "NATIVE_CTRL_BYTES=157515" in s.get("text", ""))
    assert any(e["pressed"] and e["unicode"] == 61 and not e["ctrl"] for e in final["input_events"]), "Missing IME equals event before accessory modifier processing"
    assert any(e["pressed"] and e["code"] == 61 and e["ctrl"] for e in final["input_events"]), "Missing Android Ctrl+= event"
    assertions.append("Accessory Ctrl+U, plain u, and native Android Ctrl+U reach the server PTY as 15 75 15")
    assertions.append("Trace records both IME characters and native Ctrl-modified Android keys")
    capture_screen(adb, output / "native-ctrl-bytes.png")

    # Ctrl+Shift letters use CSI-u so terminal apps can distinguish Shift;
    # Ctrl+Alt+Shift+U is ESC [ 117 ; 8 u, rather than plain Ctrl+U.
    modified_u = b"\x1b[117;8u"
    expected = b"\x1b\t" + modified_u + b"u" + modified_u * 2 + b"u"
    command("text", text="python3 -c " + shlex.quote(code) + f" {len(expected)} NATIVE_MODIFIERS\r")
    state_until(lambda s: any(line.strip() == "NATIVE_MODIFIERS_READER_READY" for line in s.get("text", "").splitlines()))
    for label, name in [("Esc", "escape"), ("tab", "tab")]:
        tap_target(label)
        state_until(lambda s: not s["keybar_pressed"][name])
    capture_screen(adb, output / "momentary-keys.png")
    modifiers = [("Ctrl", "ctrl"), ("Alt", "alt"), ("shift", "shift")]
    for label, name in modifiers:
        tap_target(label)
        state_until(lambda s: s["keybar_modifiers"].get(name) and not s["keybar_locked"].get(name))
    capture_screen(adb, output / "one-shot-modifiers.png")
    key("u")
    state_until(lambda s: not s["keybar_modifiers"] and not any(s["keybar_pressed"].values()))
    key("u")
    for label, name in modifiers:
        tap_target(label)
        state_until(lambda s: s["keybar_modifiers"].get(name) and not s["keybar_locked"].get(name))
        tap_target(label)
        state_until(lambda s: s["keybar_locked"].get(name) and s["keybar_pressed"][name])
    capture_screen(adb, output / "locked-modifiers.png")
    for unused in range(2):
        key("u")
        state_until(lambda s: all(s["keybar_locked"].get(name) and s["keybar_pressed"][name] for _, name in modifiers))
    for label, name in modifiers:
        tap_target(label)
        state_until(lambda s: not s["keybar_modifiers"].get(name) and not s["keybar_pressed"][name])
    key("u")
    state_until(lambda s: "NATIVE_MODIFIERS_BYTES=" + expected.hex() in s.get("text", "").replace("\n", ""))
    assertions.append("Esc and Tab each send one byte, without latching")
    assertions.append("One-shot Ctrl/Alt/Shift combine on the next input, then clear together")
    assertions.append("Second taps lock all three modifiers across repeated native IME inputs; third taps release them")
    assertions.append("PTY receives exactly Escape, Tab, Ctrl+Alt+Shift+U, u, two locked Ctrl+Alt+Shift+U inputs, then plain u")
    capture_screen(adb, output / "released-modifiers.png")
    (output / "assertions.json").write_text(json.dumps(assertions, indent=2))


def smoke(adb, output, native_input=False, config=None, native_remote=False, lifecycle=False, ime_resume=False, shortcuts=False, record=True, stop_chromium=None, install_apk=None):
    export_smoke(output)
    # These package names belong exclusively to this runner.
    subprocess.run(adb + ["uninstall", PACKAGE], capture_output=True, timeout=30)
    if install_apk is None:
        run(adb + ["install", "--no-incremental", str(output / "runtime-test.apk")], capture_output=True, timeout=INSTALL_TIMEOUT)
    else:
        install_apk(adb, output / "runtime-test.apk")
    def write_private(name, value):
        run(adb + ["shell", "run-as", PACKAGE, "sh", "-c", f"'cat > files/{name}.tmp && mv files/{name}.tmp files/{name}'"], input=json.dumps(value), text=True, capture_output=True)

    if config:
        run(adb + ["shell", "run-as", PACKAGE, "mkdir", "-p", "files"], capture_output=True)
        write_private("runtime-config.json", config)
    (output / "capture.json").write_text(json.dumps({"screen_recording": record}, indent=2))
    states = []
    pids = []
    recorder = None
    recording_pid = ""
    remote_movie = f"/sdcard/graffitty-e2e-{os.getpid()}.mp4"
    activity = PACKAGE + "/com.godot.game.GodotAppLauncher"

    def launch():
        # A wireless APK transfer can outlast the screen timeout. Start the
        # interaction test on the visible display, not behind an idle keyguard.
        run(adb + ["shell", "input", "keyevent", "KEYCODE_WAKEUP"], capture_output=True)
        run(adb + ["shell", "wm", "dismiss-keyguard"], capture_output=True)
        run(adb + ["shell", "am", "start", "-W", "--user", "0", "-n", activity], capture_output=True)
        pid = run(adb + ["shell", "pidof", PACKAGE], capture_output=True, text=True).stdout.strip()
        if pid not in pids:
            pids.append(pid)

    def state_until(predicate):
        deadline = time.monotonic() + (120 if config and config.get("scenario") else 45)
        while time.monotonic() < deadline:
            result = subprocess.run(adb + ["shell", "run-as", PACKAGE, "cat", "files/runtime-state.json"], capture_output=True, text=True, timeout=10)
            try:
                state = json.loads(result.stdout)
            except ValueError:
                time.sleep(.25)
                continue
            (output / "last-state.json").write_text(json.dumps(state, indent=2))
            if state.get("errors") or state.get("failures"):
                raise AssertionError(state)
            if state.get("ready") and predicate(state):
                states.append(state)
                (output / "states.json").write_text(json.dumps(states, indent=2))
                return state
            time.sleep(.25)
        raise AssertionError("Android runtime state timed out")

    try:
        if record:
            recorder = subprocess.Popen(adb + ["shell", f"screenrecord --time-limit 180 {remote_movie} >/dev/null 2>&1 & echo $!; wait $!"], stdout=subprocess.PIPE, text=True)
            recording_pid = recorder.stdout.readline().strip()
            assert recording_pid.isdigit(), "Android screen recording did not start"
        launch()
        first = state_until(lambda s: s.get("launches", 1) == 1)
        capture_screen(adb, output / "entry.png")
        if config and config.get("case") == "messages-copy":
            import uiautomator2 as u2
            device = u2.connect(adb[adb.index("-s") + 1])
            selection = state_until(lambda s: "Native message selection ready" in s.get("checks", []))["published"]["native_selection"]
            label = device(className="android.widget.TextView", textStartsWith="Error: Clipboard")
            assert label.wait(timeout=10), "Native selectable diagnostic missing"
            # The selectable TextView fills the panel. Its centre can be blank
            # on a tablet; long-press the first printed word instead.
            bounds = label.info["bounds"]
            device.long_click(bounds["left"] + min(40, (bounds["right"] - bounds["left"]) // 4),
                              bounds["top"] + min(20, (bounds["bottom"] - bounds["top"]) // 4))
            assert device(text=selection["select_all"]).wait(timeout=5), "Native selection toolbar missing"
            device(text=selection["select_all"]).click()
            assert device(text=selection["copy"]).wait(timeout=5), "Native Copy missing"
            (output / "native-selection.xml").write_text(device.dump_hierarchy())
            device.screenshot(str(output / "native-selection.png"))
            device(text=selection["copy"]).click()
            state_until(lambda s: "Android contextual Copy preserves complete Unicode message" in s.get("checks", []))
            state_until(lambda s: "Log viewer text is native selectable" in s.get("checks", []))
            (output / "native-log.xml").write_text(device.dump_hierarchy())
            device.screenshot(str(output / "native-log.png"))
            run(adb + ["shell", "run-as", PACKAGE, "touch", "files/native-log-captured"], capture_output=True)
        if native_input:
            import uiautomator2 as u2
            device = u2.connect(adb[adb.index("-s") + 1])

            # Godot reports content coordinates; Android's SurfaceView bounds
            # supply the system-bar offset in physical screen coordinates.
            # Another app's floating video is also a SurfaceView.
            bounds = state_until(lambda s: len(s.get("surface_bounds", [])) == 4)["surface_bounds"]
            centers = []
            def field_settled(state):
                centers.append(state.get("field_center"))
                return len(centers) >= 3 and centers[-1] is not None and centers[-3:] == [centers[-1]] * 3
            current = state_until(field_settled)
            x, y = current["field_center"]
            run(adb + ["shell", "input", "tap", str(round(x + bounds[0])), str(round(y + bounds[1]))], capture_output=True)
            keyboard_heights = []

            def keyboard_settled(state):
                keyboard_heights.append(state["keyboard_height"])
                return len(keyboard_heights) >= 3 and keyboard_heights[-1] > 0 and len(set(keyboard_heights[-3:])) == 1

            state_until(keyboard_settled)
            gboard_english(adb, device)
            if not device(descriptionMatches="(?i)(capital )?a(?:,.*)?").exists:
                (output / "ime-precondition.xml").write_text(device.dump_hierarchy())
                raise NativeInputUnavailable("Native input requires an English IME layout exposing accessible a/b/c keys; the installed layout does not. Keyboard preferences were retained.")
            expected_text = ""
            for letter in "abc":
                tap_ime_key(adb, device, output, letter)
                expected_text += letter
                state_until(lambda s: s["field_text"].lower() == expected_text)
            capture_screen(adb, output / "ime.png")
            run(adb + ["shell", "input", "keyevent", "KEYCODE_BACK"], capture_output=True)
            state_until(lambda s: s["keyboard_height"] == 0 and s["dialog_visible"])
        if config and config.get("case") == "chromium-resume":
            for cycle in (1, 2):
                state_until(lambda s: s.get("published", {}).get("chromium_background") == cycle)
                run(adb + ["shell", "input", "keyevent", "KEYCODE_HOME"], capture_output=True)
                time.sleep(11)
                launch()
                write_private(f"chromium-resumed-{cycle}.json", {"cycle": cycle})
        if config and config.get("case") == "chromium-crash-recovery":
            # The device cannot stop a server-computer process: stop the
            # Chromium host or its page renderers as requested, after
            # confirming the host belongs to this test's server.
            handled = 0
            while True:
                current = state_until(lambda s: s.get("complete") or s.get("published", {}).get("chromium_kill", {}).get("id", 0) > handled)
                request = current.get("published", {}).get("chromium_kill", {})
                if request.get("id", 0) <= handled:
                    break
                handled = request["id"]
                host = int(request["host"])
                if stop_chromium is not None:
                    # Remote runners validate process ownership on the server
                    # computer. Its PID must never address a local process.
                    stop_chromium(host, request["process"])
                    continue
                command = run(["ps", "-o", "command=", "-p", str(host)], capture_output=True, text=True).stdout
                assert "Chromium GPU Host" in command and "/Contents/MacOS/probe" in command, command
                if request["process"] == "host":
                    os.kill(host, 9)
                    continue
                listing = run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
                for line in listing.splitlines():
                    pid, parent, rest = (line.split(None, 2) + ["", "", ""])[:3]
                    if parent == str(host) and "--type=renderer" in rest.split() and "--extension-process" not in rest:
                        os.kill(int(pid), 9)
        if config and config.get("scenario"):
            state_until(lambda s: s.get("complete"))
        elif native_remote:
            import uiautomator2 as u2
            device = u2.connect(adb[adb.index("-s") + 1])
            first = state_until(lambda s: s.get("connected") and s.get("tabs") == (1 if shortcuts else 2))
            command_id = 0

            def command(action, **values):
                nonlocal command_id
                command_id += 1
                write_private("runtime-command.json", {"id": command_id, "action": action, **values})
                return state_until(lambda s: s.get("command_id") == command_id)

            def tap_target(label):
                samples = []
                last_tick = None

                def settled_target(state):
                    nonlocal last_tick
                    if label not in state.get("targets", {}) or state.get("ticks") == last_tick:
                        return False
                    last_tick = state.get("ticks")
                    samples.append(state["targets"][label])
                    return len(samples) >= 3 and samples[-3:] == [samples[-1]] * 3

                state = state_until(settled_target)
                b = state_until(lambda s: len(s.get("surface_bounds", [])) == 4)["surface_bounds"]
                x, y = state["targets"][label]
                assert 0 <= x < b[2] - b[0] and 0 <= y < b[3] - b[1], f"{label} is outside Android content bounds: {x, y} in {b}"
                run(adb + ["shell", "input", "tap", str(round(x + b[0])), str(round(y + b[1]))], capture_output=True)

            # Connecting now keeps the server list visible until the user enters
            # the workspace. Exercise that action before targeting pane controls.
            if state_until(lambda s: s.get("connected")).get("chooser"):
                tap_target("WorkspaceStart")
                state_until(lambda s: not s.get("chooser"))
            command("text", text="printf 'NATIVE_ANDROID_READY\\n'\r")
            state_until(lambda s: "NATIVE_ANDROID_READY" in s.get("text", ""))
            if shortcuts:
                native_shortcuts(adb, output, device, state_until, tap_target, command)
            elif ime_resume:
                def ime_key(*labels):
                    deadline = time.monotonic() + 8
                    while time.monotonic() < deadline:
                        for label in labels:
                            key = device(description=label)
                            if key.exists:
                                key.click()
                                time.sleep(.15)
                                return
                        time.sleep(.1)
                    (output / "missing-ime-key.xml").write_text(device.dump_hierarchy())
                    raise AssertionError("Gboard key missing: " + str(labels))

                command("text", text="printf '<%s>\\n' '")
                tap_target("KeyboardButton")
                state_until(lambda s: s["keyboard_height"] > 0 and s["ime_opened"])
                if not device(description="히읗").exists:
                    ime_key("Next language", "다음 언어")
                assert device(description="히읗").exists, "Configure Gboard Korean 두벌식 and English for this VM case"
                for key in ["히읗", "아", "니은", "기역", "으", "리을", "삭제", "리을", "스페이스"]:
                    ime_key(key)
                state_until(lambda s: "한글" in s.get("text", ""))
                tap_target("KeyboardButton")
                state_until(lambda s: s["keyboard_height"] == 0 and not s["keybar_visible"]
                            and abs(s["workspace_bottom"] - s["viewport_bottom"]) < 1)
                tap_target("KeyboardButton")
                state_until(lambda s: s["keyboard_height"] > 0 and s["keybar_visible"])
                # Launch the IME's own settings, the transition that
                # previously left subsequent composing keystrokes as separate
                # jamo. Exercise the real IME activity/lifecycle.
                #
                # Gboard's animated feature menu can move the gear between
                # accessibility lookup and click; that toolbar is not
                # Graffitty's input surface.
                ime_package = "com.google.android.inputmethod.latin"
                ime_activity = "com.google.android.apps.inputmethod.latin.preference.SettingsActivity"
                run(adb + ["shell", "am", "start", "-W", "-n", ime_package + "/" + ime_activity], capture_output=True)
                assert device.wait_activity(ime_activity, timeout=10), "IME settings activity did not open"
                assert device.app_current()["package"] == ime_package, "IME settings is not the foreground app"
                launch()
                state_until(lambda s: s["keyboard_height"] == 0 and not s["keybar_visible"]
                            and abs(s["workspace_bottom"] - s["viewport_bottom"]) < 1
                            and s["pauses"] > first["pauses"] and s["resumes"] > first["resumes"])
                # Gboard settings rotates to portrait; let Android finish its
                # landscape surface transition before targeting fixed chrome.
                time.sleep(1.0)
                tap_target("KeyboardButton")
                state_until(lambda s: s["keyboard_height"] > 0 and s["ime_opened"])
                for key in ["히읗", "아", "니은", "기역", "으", "리을", "스페이스"]:
                    ime_key(key)
                state_until(lambda s: "한글 한글" in s.get("text", ""))
                ime_key("다음 언어", "Next language")
                run(adb + ["shell", "input", "keyevent", "KEYCODE_BACK"], capture_output=True)
                state_until(lambda s: s["keyboard_height"] == 0)
                command("text", text="'\r")
                state_until(lambda s: "<한글 한글 >" in s.get("text", ""))
                (output / "assertions.json").write_text(json.dumps([
                    "Native Gboard composes Korean syllables and edits a final consonant",
                    "Keyboard-button dismissal restores the full workspace and hides accessory controls",
                    "Opening IME settings pauses the app and dismisses its keyboard",
                    "Returning from settings restores the full workspace height without a stale keyboard gap",
                    "Reopened keyboard composes Korean after settings return without separate jamo",
                    "Composed text commits through the live server shell as <한글 한글 >",
                    "English keyboard restored after the fixture",
                ], indent=2))
            elif lifecycle:
                command("text", text="sleep 3; printf '%s_%s\\n' BG OUTPUT\r")
                command("hold_pointer")
                state_until(lambda s: s["buttons"] != 0 and s["fingers"] == 1)
                run(adb + ["shell", "input", "keyevent", "KEYCODE_HOME"], capture_output=True)
                # Stay suspended beyond the transport heartbeat deadline.
                time.sleep(11)
                launch()
                state_until(lambda s: s.get("connected") and s["pauses"] > first["pauses"] and s["resumes"] > first["resumes"] and "BG_OUTPUT" in s.get("text", "") and s["buttons"] == 0 and s["fingers"] == 0)
                run(adb + ["shell", "am", "force-stop", PACKAGE], capture_output=True)
                launch()
                if state_until(lambda s: s["launches"] == 2 and s.get("connected")).get("chooser"):
                    tap_target("WorkspaceStart")
                state_until(lambda s: s["launches"] == 2 and "BG_OUTPUT" in s.get("text", ""))
                run(adb + ["shell", "am", "force-stop", PACKAGE], capture_output=True)
                run(adb + ["install", "--no-incremental", "-r", str(output / "runtime-test.apk")], capture_output=True, timeout=INSTALL_TIMEOUT)
                launch()
                if state_until(lambda s: s["launches"] == 3 and s.get("connected")).get("chooser"):
                    tap_target("WorkspaceStart")
                state_until(lambda s: s["launches"] == 3 and "BG_OUTPUT" in s.get("text", "") and s["buttons"] == 0 and s["fingers"] == 0)
            else:
                command("messages")
                state_until(lambda s: s.get("messages"))
                tap_target("Dismiss")
                state_until(lambda s: not s.get("messages"))
                tap_target("MenuExpand")
                tap_target("Sessions")
                tap_target("Sessions::Servers…")
                state_until(lambda s: s.get("chooser"))
                tap_target("WorkspaceStart")
                state_until(lambda s: not s.get("chooser"))
                state_until(lambda s: s.get("buttons") == 0 and s.get("fingers") == 0)
                before_keyboard = command("text", text="printf '<%s>\\n' '")
                tap_target("KeyboardButton")
                heights = []

                def settled_keyboard(state):
                    heights.append(state["keyboard_height"])
                    return len(heights) >= 3 and heights[-1] > 0 and len(set(heights[-3:])) == 1

                state_until(settled_keyboard)
                gboard_english(adb, device)
                for key in ["c", "a", "t", "Delete", "r", "Space"]:
                    tap_ime_key(adb, device, output, key)
                    time.sleep(.1)
                run(adb + ["shell", "input", "keyevent", "KEYCODE_BACK"], capture_output=True)
                state_until(lambda s: s["keyboard_height"] == 0 and s.get("connected") and s["grid"] == before_keyboard["grid"])
                command("text", text="'\r")
                state_until(lambda s: "<car >" in s.get("text", "").lower())
        else:
            previous = first
            for cycle in range(3):
                run(adb + ["shell", "input", "keyevent", "KEYCODE_HOME"], capture_output=True)
                time.sleep(1)
                launch()
                previous = state_until(lambda s: s["pauses"] > previous["pauses"] and s["resumes"] > previous["resumes"])
            run(adb + ["shell", "am", "force-stop", PACKAGE], capture_output=True)
            launch()
            state_until(lambda s: s["launches"] == 2)
            run(adb + ["shell", "am", "force-stop", PACKAGE], capture_output=True)
            run(adb + ["install", "--no-incremental", "-r", str(output / "runtime-test.apk")], capture_output=True, timeout=INSTALL_TIMEOUT)
            launch()
            state_until(lambda s: s["launches"] == 3)
    finally:
        if ime_resume and "device" in locals():
            # Keep the shared VM's other native input cases on English even if
            # this regression fails halfway through its Korean composition.
            if device(description="히읗").exists and device(description="다음 언어").exists:
                device(description="다음 언어").click()
        if recorder is not None:
            if recording_pid.isdigit():
                subprocess.run(adb + ["shell", "kill", "-2", recording_pid], capture_output=True, timeout=10)
            try:
                recorder.wait(timeout=15)
            except subprocess.TimeoutExpired:
                recorder.kill()
                recorder.wait()
            subprocess.run(adb + ["pull", remote_movie, str(output / "replay.mp4")], capture_output=True, timeout=30)
            subprocess.run(adb + ["shell", "rm", "-f", remote_movie], capture_output=True, timeout=10)
        capture_screen(adb, output / "final.png")
        if config and config.get("case") in {"terminal-throughput", "agent-title-stream"}:
            measurement = subprocess.run(adb + ["shell", "run-as", PACKAGE, "cat", "files/throughput-result.json"], capture_output=True, text=True, timeout=10)
            if measurement.returncode == 0:
                # Preserve incomplete evidence without hiding the scenario's
                # original failure or skipping log collection and uninstall.
                (output / "throughput-result.json").write_text(measurement.stdout)
        with (output / "logcat.txt").open("w") as log:
            for pid in pids:
                subprocess.run(adb + ["logcat", "-d", "--pid=" + pid], stdout=log, stderr=subprocess.STDOUT, timeout=20)
        run(adb + ["uninstall", PACKAGE], capture_output=True)
    if record: assert (output / "replay.mp4").exists() and (output / "replay.mp4").stat().st_size > 1024, "Android replay recording missing"
    engine_errors = [line for line in (output / "logcat.txt").read_text().splitlines()
                     if (("godot" in line or "GraffittySurface" in line) and ("ERROR:" in line or "SCRIPT ERROR:" in line or "WARNING:" in line))
                     or any(marker in line for marker in ("FATAL EXCEPTION", "Fatal signal", "Abort message:"))]
    assert not engine_errors, "Android runtime errors: " + "\n".join(engine_errors)
    if config and config.get("case") == "chromium-scroll-stability":
        codec_errors = [line for line in (output / "logcat.txt").read_text().splitlines()
                        if "GraffittyVideo" in line or "queueBuffer failed:" in line
                        or "attachBuffer failed:" in line or "rendring output error" in line]
        assert not codec_errors, "Chromium hardware video errors: " + "\n".join(codec_errors[:10])
    if record and shutil.which("ffprobe"):
        run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name,duration", str(output / "replay.mp4")], capture_output=True)


@contextmanager
def remote_fixture(adb, output):
    fixture = output / "server"
    fixture.mkdir()
    log = (fixture / "server.log").open("w")
    env = os.environ.copy()
    clear_background(env)
    for kind in ("CONFIG", "STATE"):
        env[f"XDG_{kind}_HOME"] = str(fixture / kind.lower())
    with PrivateServer(env, fixture, "/bin/sh"):
        process = subprocess.Popen(["godot", "--headless", "--path", str(GODOT_ROOT), "--script",
                                    "tests/android_vm_server.gd", "--", "--shell=/bin/sh", "--fixture=" + str(fixture)],
                                   cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        port = None
        try:
            deadline = time.monotonic() + 35
            descriptor = fixture / "connection.json"
            while not descriptor.exists() and time.monotonic() < deadline:
                assert process.poll() is None, "Server fixture exited; see server.log"
                time.sleep(.2)
            assert descriptor.exists(), "Server fixture did not start"
            settings = json.loads(descriptor.read_text())
            port = urlparse(settings["url"]).port
            if adb: run(adb + ["reverse", f"tcp:{port}", f"tcp:{port}"], capture_output=True)
            yield settings
        finally:
            (fixture / "stop").touch()
            try:
                process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)
            if port and adb: subprocess.run(adb + ["reverse", "--remove", f"tcp:{port}"], capture_output=True, timeout=10)
            log.close()
        assert process.returncode == 0, "Server fixture failed; see server.log"
        assert not json.loads((fixture / "server-result.json").read_text())["failures"], "Server focus or PTY continuity failed"


def local_fixture_connection(settings):
    """The owner-side observer uses the local capability, never remote auth."""
    endpoint = urlparse(settings["url"])
    loopback = "[::1]" if ":" in endpoint.hostname else "127.0.0.1"
    return {**settings, "url": f"ws://{loopback}:{endpoint.port}"}


@contextmanager
def headless_fixture(adb, output, owner_extra=None):
    # Same authoritative standalone backend as headless_remote_client_e2e.
    from headless_remote_e2e import BINARY, Client
    import base64
    fixture = output / "server"
    fixture.mkdir()
    # Holder sockets live beside this descriptor. Evidence directories exceed
    # macOS's Unix-socket path limit; keep the live owner in a short directory.
    owner_runtime = tempfile.TemporaryDirectory(prefix="gft-mobile-", dir="/tmp" if os.name != "nt" else None)
    descriptor = Path(owner_runtime.name) / "connection.json"
    log = (fixture / "server.log").open("w")
    owner_env = {**os.environ, "SHELL": "/bin/sh"}
    owner_env.update(owner_extra or {})
    clear_background(owner_env)
    # Performance acceptance uses the authenticated production transport;
    # forwarding it through wireless ADB adds a second TCP queue and no UDP.
    direct_host = os.environ.get("GRAFFITTY_ANDROID_SERVER_HOST", "") if adb else ""
    listen_host = ("::" if ":" in direct_host else "0.0.0.0") if direct_host else "127.0.0.1"
    listen = f"[{listen_host}]:0" if ":" in listen_host else f"{listen_host}:0"
    process = subprocess.Popen([str(BINARY), "server", "--listen", listen, "--connection", str(descriptor),
                                "--auth-file", str(fixture / "auth.json")],
                               env=owner_env, stdout=log, stderr=log)
    port = None
    observer = None
    image_file = None
    try:
        deadline = time.monotonic() + 20
        while not descriptor.exists() and time.monotonic() < deadline:
            assert process.poll() is None, "Headless fixture exited"
            time.sleep(.1)
        settings = json.loads(descriptor.read_text())
        if direct_host:
            authority = f"[{direct_host}]" if ":" in direct_host else direct_host
            settings["url"] = f"ws://{authority}:{urlparse(settings['url']).port}"
        observer = Client(local_fixture_connection(settings))
        pane = observer.topology["panes"][0]["id"]
        original_pid = observer.topology["panes"][0]["pid"]
        fd, image_path = tempfile.mkstemp(prefix="tty-graphics-protocol-", suffix=".png")
        os.close(fd)
        image_file = Path(image_path)
        image_file.write_bytes(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="))
        encoded = base64.b64encode(str(image_file).encode()).decode()
        observer.text(pane, f"printf '\\033[2J\\033[H\\033_Ga=T,t=t,f=100,i=9001,p=1,c=4,r=2,q=2;{encoded}\\033\\\\'; printf 'IMAGE_SEEDED\\n'\r")
        observer.has_output(pane, "IMAGE_SEEDED")
        observer.until(lambda: not image_file.exists())
        port = urlparse(settings["url"]).port
        if adb and not direct_host: run(adb + ["reverse", f"tcp:{port}", f"tcp:{port}"], capture_output=True)
        (output / "route.json").write_text(json.dumps({"transport": "direct" if direct_host else "adb-reverse" if adb else "local", "url": settings["url"]}, indent=2))
        yield settings
        assert process.poll() is None, "Headless server died during APK test"
        os.kill(original_pid, 0)
        (fixture / "server-result.json").write_text(json.dumps({"failures": [], "preserved_pty_pid": original_pid}))
    finally:
        if observer: observer.ws.close()
        if image_file: image_file.unlink(missing_ok=True)
        if port and adb and not direct_host: subprocess.run(adb + ["reverse", "--remove", f"tcp:{port}"], capture_output=True, timeout=10)
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        log.close()
        owner_runtime.cleanup()


@contextmanager
def keyboard_fixture(adb, output):
    # IME recovery needs a live shell and two tabs, with no graph dependency.
    with headless_fixture(adb, output) as settings:
        from headless_remote_e2e import Client
        setup = Client(local_fixture_connection(settings))
        try:
            setup.action("create", kind="tab")
            setup.until(lambda: len(setup.topology["tabs"]) == 2)
        finally:
            setup.ws.close()
        yield settings


@contextmanager
def multiserver_fixture(adb, output):
    # The manager owns one connection per server address. Named sessions on
    # that server are selected through its session menu, not duplicate peers.
    with ExitStack() as stack:
        connections = []
        for name in ["A", "B", "C"]:
            directory = output / ("computer-" + name.lower())
            directory.mkdir()
            connection = stack.enter_context(headless_fixture(adb, directory))
            connections.append(dict(connection, name=name))
        yield {"connections": connections}


@contextmanager
def filetree_fixture(adb, output):
    # Run the real bundled filetree on the Mac (dist/filetree), with disposable state.
    home = output / "filetree-home"
    home.mkdir()
    env = {f"XDG_{kind}_HOME": str(home / kind.lower()) for kind in ("CONFIG", "DATA", "STATE", "CACHE")}
    selected = home / "viewer 한글.txt"
    selected.write_text("REMOTE_FILETREE_VIEWER 한글\n")
    with headless_fixture(adb, output, env) as connection:
        yield dict(connection, filetree_fixture=str(selected))


SHARED_SCENARIOS = {"android-touch-ui": "android_ui", "android-remote-state": "remote_client", "android-gestures": "android_gestures", "android-images": "android_images", "android-multiserver": "multiserver"}
WORKSPACE_CASES = {"android-" + name: name for name in ['gestures', 'row-continuity', 'fractional-scroll', 'pan-clipping', 'client-controls', 'direct-touch', 'pane-controls', 'close-nearest', 'fit-restore', 'tiling-layout', 'per-tab-tiling', 'tab-reorder', 'pane-tab-transfer', 'pane-resize', 'prefix-shortcuts', 'messages-copy', 'selection-copy', 'bracketed-paste', 'mouse-reporting', 'scrollback-search', 'tab-titles', 'working-directory', 'graph-editing', 'view-per-tab', 'chromium-backend', 'chromium-hardware-backend', 'chromium-multi-stream', 'chromium-navigation', 'chromium-clipboard', 'chromium-find', 'chromium-scroll-stability', 'chromium-touch', 'chromium-url', 'chromium-crash-recovery', 'chromium-resume', 'connections-scroll', 'auth-recovery', 'usability-regressions', 'visual-preferences']}
SHARED_SCENARIOS.update({name: "workspace" for name in WORKSPACE_CASES})
WORKSPACE_CASES["android-list-docking"] = "list-docking"
SHARED_SCENARIOS["android-list-docking"] = "workspace"
WORKSPACE_CASES["android-sidebar-pinch"] = "sidebar-pinch"
SHARED_SCENARIOS["android-sidebar-pinch"] = "workspace"
WORKSPACE_CASES["android-touch-menus"] = "touch-menus"
SHARED_SCENARIOS["android-touch-menus"] = "workspace"
WORKSPACE_CASES["android-dock-camera"] = "dock-camera"
SHARED_SCENARIOS["android-dock-camera"] = "workspace"
WORKSPACE_CASES["android-agent-attention"] = "agent-attention"
SHARED_SCENARIOS["android-agent-attention"] = "workspace"
WORKSPACE_CASES["android-main-area-keyboard"] = "main-area-keyboard"
WORKSPACE_CASES["android-text-size"] = "text-size"
SHARED_SCENARIOS["android-text-size"] = "workspace"
SHARED_SCENARIOS["android-main-area-keyboard"] = "main_area_keyboard"
for feature in ["scene-retention", "remote-notifications", "typing-effects", "terminal-throughput", "agent-title-stream"]:
    WORKSPACE_CASES["android-" + feature] = feature
    SHARED_SCENARIOS["android-" + feature] = "remote_features"
WORKSPACE_CASES["android-filetree-layout"] = "filetree-layout"
SHARED_SCENARIOS["android-filetree-layout"] = "filetree_layout"
WORKSPACE_CASES["android-retained-transitions"] = "retained-transitions"
SHARED_SCENARIOS["android-retained-transitions"] = "retained_transitions"
NATIVE_REMOTE = {"android-apk-runtime", "android-lifecycle", "android-ime-resume", "android-native-shortcuts"}


def simulate(output, config, movie=None, headful=False):
    config_path = output / "config.json"
    result_path = output / "runtime-state.json"
    config_path.write_text(json.dumps(config))
    env = os.environ.copy()
    # The scenario isolates these itself, but diagnostics may open the log
    # first; never write into the developer's own app log.
    env["XDG_STATE_HOME"] = str(output / "state")
    env["XDG_CONFIG_HOME"] = str(output / "config")
    headful = headful or env.get("GRAFFITTY_E2E_HEADFUL") == "1"
    evidence = output / "background"
    if headful:
        clear_background(env)
        env["GRAFFITTY_E2E_HEADFUL"] = "1"
    engine_args = [] if headful else prepare_background(env, evidence)
    with (output / "client.log").open("w") as log:
        command = [os.environ.get("GODOT") or "godot", *engine_args, "--path", str(GODOT_ROOT)]
        if movie: command += ["--write-movie", str(movie), "--fixed-fps", "30", "--quit-after", "7200"]
        command += ["--script", "tests/client_scenario_desktop.gd", "--", "--scenario=" + str(config_path), "--result=" + str(result_path)]
        process = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=240 if movie else 120)
    engine_errors = [line for line in (output / "client.log").read_text(errors="replace").splitlines() if "SCRIPT ERROR" in line or "[diagnostic guard] FAIL" in line or line.lstrip().startswith(("ERROR:", "WARNING:"))]
    errors = engine_errors[:5] + ([] if headful else background_failures(evidence))
    assert not errors, "; ".join(errors)
    assert result_path.exists(), "Scenario did not finish; see client.log"
    result = json.loads(result_path.read_text())
    assert not result["failures"], "; ".join(result["failures"])
    assert process.returncode == 0, "Godot failed; see client.log"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("names", nargs="*")
    parser.add_argument("--automated", action="store_true", help="Run all automated APK cases, excluding manual/physical-device procedures")
    parser.add_argument("--movie", type=Path, help="Record a selected shared Mac scenario")
    parser.add_argument("--simulated", action="store_true", help="Run shared touch scenarios in native Mac Godot without an Android VM")
    parser.add_argument("--headful", action="store_true", help="Show native windows for --simulated tests and recordings")
    parser.add_argument("--no-record", action="store_true", help="Measure Android without screen-recording GPU/encoder overhead; retain screenshots and logs")
    parser.add_argument("--serial", default=os.environ.get("ANDROID_SERIAL"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.movie and (not args.simulated or len(args.names) != 1): parser.error("--movie requires --simulated and one case")
    if args.no_record and args.simulated: parser.error("--no-record applies to Android APK runs")
    if args.headful and not args.simulated: parser.error("--headful requires --simulated")
    cases = [tomllib.loads(path.read_text()) for path in sorted(SUITE.glob("*.toml"))]
    unknown = set(args.names) - {case["name"] for case in cases}
    if unknown: parser.error("Unknown cases: " + ", ".join(sorted(unknown)))
    simulated_cases = set(WORKSPACE_CASES) | {"android-multiserver", "android-remote-state", "android-touch-ui"}
    if args.simulated and set(args.names) - simulated_cases:
        parser.error("Selected cases do not support --simulated")
    cases = [case for case in cases if (not args.names or case["name"] in args.names) and (not args.simulated or case["name"] in simulated_cases)]
    if args.automated:
        executable = {"android-entry-smoke", "android-native-input", "android-keystore"} | SHARED_SCENARIOS.keys() | NATIVE_REMOTE
        cases = [case for case in cases if case["name"] in executable]
    output = (args.output or ROOT / "build/android/e2e" / time.strftime("%Y%m%d-%H%M%S")).resolve()
    output.mkdir(parents=True, exist_ok=True)
    sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    adb = [str(sdk / "platform-tools/adb")]
    blocker = ""
    serial = args.serial
    metadata = {}
    try:
        devices = run(adb + ["devices"], capture_output=True, text=True).stdout
        available = [line.split()[0] for line in devices.splitlines()[1:] if len(line.split()) > 1 and line.split()[1] == "device"]
        if not serial and len(available) == 1: serial = available[0]
        if serial not in available:
            blocker = "No authorized Android device selected; attach a phone or boot an emulator and pass --serial."
        else:
            adb += ["-s", serial]
            metadata = {key: run(adb + ["shell", "getprop", key], capture_output=True, text=True).stdout.strip()
                        for key in ["ro.product.cpu.abilist", "ro.build.version.sdk", "ro.product.model", "ro.kernel.qemu"]}
            metadata["serial"] = serial
            metadata["input_method"] = run(adb + ["shell", "settings", "get", "secure", "default_input_method"], capture_output=True, text=True).stdout.strip()
            (output / "device.json").write_text(json.dumps(metadata, indent=2))
            if "arm64-v8a" not in metadata["ro.product.cpu.abilist"]:
                blocker = "Built client requires an ARM64 Android runtime."
    except (OSError, subprocess.SubprocessError) as error:
        blocker = str(error)
    if args.simulated:
        adb = None
        blocker = ""
    results = {}
    installer = DeviceApkCache(adb) if not args.simulated and not blocker else None
    for case in cases:
        name = case["name"]
        case_output = output / name
        case_output.mkdir(exist_ok=True)
        reason = blocker
        if args.simulated and name not in simulated_cases:
            reason = "Select shared workspace cases for this wrapper"
        if not reason and case.get("physical_device") and metadata.get("ro.kernel.qemu") == "1":
            reason = "Requires a physical Android device; an emulator cannot validate phone GPU/OEM/memory behavior."
        if not reason and name not in ({"android-entry-smoke", "android-native-input", "android-keystore"} | SHARED_SCENARIOS.keys() | NATIVE_REMOTE):
            reason = "Requires recorded LLM/manual execution of " + str(SUITE / case["instructions"])
        if not reason and not args.simulated and not (ROOT / "build/android/project/project.godot").exists():
            reason = "Build the current Android client first: mise run android:build"
        if not reason and name in {"android-apk-runtime", "android-ime-resume", "android-native-shortcuts"} and not metadata.get("input_method", "").startswith("com.google.android.inputmethod.latin/"):
            reason = "This case requires Gboard; selected device uses " + metadata.get("input_method", "unknown IME") + ". Native input cases still exercise the installed keyboard."
        if reason:
            result = {"status": "blocked", "reason": reason}
        else:
            try:
                if name in {"android-entry-smoke", "android-native-input"}:
                    smoke(adb, case_output, native_input=name == "android-native-input", record=not args.no_record, install_apk=installer)
                elif name in SHARED_SCENARIOS or name in NATIVE_REMOTE:
                    with ({"android-images": headless_fixture, "android-multiserver": multiserver_fixture, "android-native-shortcuts": headless_fixture, "android-ime-resume": keyboard_fixture, "android-filetree-layout": filetree_fixture}.get(name, headless_fixture if name in WORKSPACE_CASES else remote_fixture))(adb, case_output) as connection:
                        config = {"connection": connection}
                        if name in SHARED_SCENARIOS: config["scenario"] = SHARED_SCENARIOS[name]
                        if name in WORKSPACE_CASES: config["case"] = WORKSPACE_CASES[name]
                        if args.simulated: simulate(case_output, config, args.movie, args.headful)
                        else: smoke(adb, case_output, config=config, native_remote=name in NATIVE_REMOTE, lifecycle=name == "android-lifecycle", ime_resume=name == "android-ime-resume", shortcuts=name == "android-native-shortcuts", record=not args.no_record, install_apk=installer)
                else:
                    with (case_output / "keystore.log").open("w") as log:
                        subprocess.run([sys.executable, str(ROOT / "tests/android/test_android_credentials.py")], cwd=ROOT,
                                       env={**os.environ, "ANDROID_SERIAL": serial}, stdout=log, stderr=subprocess.STDOUT,
                                       check=True, timeout=240)
                result = {"status": "pass", "evidence": name}
            except NativeInputUnavailable as error:
                (case_output / "blocked.txt").write_text(str(error))
                result = {"status": "blocked", "reason": str(error), "evidence": name}
            except Exception as error:
                detail = ""
                if isinstance(error, subprocess.CalledProcessError):
                    for stream in (error.stdout, error.stderr):
                        if stream: detail += "\n" + (stream.decode(errors="replace") if isinstance(stream, bytes) else stream)
                (case_output / "failure.txt").write_text(traceback.format_exc() + detail)
                result = {"status": "fail", "reason": (str(error) or type(error).__name__) + detail}
        results[name] = result
        print(f"{name}: {result['status']} {result.get('reason', '')}", flush=True)
        (output / "results.json").write_text(json.dumps(results, indent=2))
    if installer is not None: installer.close()
    print("Evidence: " + str(output))
    return 1 if any(r["status"] == "fail" for r in results.values()) else (2 if any(r["status"] == "blocked" for r in results.values()) else 0)


if __name__ == "__main__":
    sys.exit(main())
