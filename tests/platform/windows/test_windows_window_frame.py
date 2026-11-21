"""Real Win32 hit tests and window actions against the Godot tab strip.

Run on an interactive Windows desktop, not an SSH service desktop:
    python tests/platform/windows/test_windows_window_frame.py --evidence C:/Temp/window-frame
Under `unittest discover` the evidence goes to a temporary folder unless
GRAFFITTY_TEST_EVIDENCE names one.
Uses GRAFFITTY_TEST_GODOT when Godot is not on PATH; Pillow saves desktop evidence.
"""

import argparse
import ctypes
import json
import math
import os
import subprocess
import sys
import tempfile
import time
import unittest
from ctypes import wintypes as w
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def wait(check, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for native window state")


@unittest.skipUnless(os.name == "nt", "Windows native window frame")
class WindowFrame(unittest.TestCase):
    def test_native_frame(self):
        user = ctypes.WinDLL("user32", use_last_error=True)
        dwm = ctypes.WinDLL("dwmapi")
        user.SendMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
        user.SendMessageW.restype = ctypes.c_ssize_t
        user.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
        user.GetClientRect.argtypes = [w.HWND, ctypes.POINTER(w.RECT)]
        user.GetWindowRect.argtypes = [w.HWND, ctypes.POINTER(w.RECT)]
        user.ClientToScreen.argtypes = [w.HWND, ctypes.POINTER(w.POINT)]
        user.IsZoomed.argtypes = [w.HWND]
        user.IsIconic.argtypes = [w.HWND]
        user.SetForegroundWindow.argtypes = [w.HWND]
        user.GetCursorPos.argtypes = [ctypes.POINTER(w.POINT)]
        user.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
        original_pointer = w.POINT()
        user.GetCursorPos(ctypes.byref(original_pointer))
        dwm.DwmGetWindowAttribute.argtypes = [w.HWND, w.DWORD, ctypes.c_void_p, w.DWORD]
        user.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
        # `unittest discover` passes no evidence folder; a temporary one keeps the captures for this run.
        evidence = Path(os.environ.get("GRAFFITTY_TEST_EVIDENCE") or tempfile.mkdtemp(prefix="gft-frame-"))
        evidence.mkdir(parents=True, exist_ok=True)
        for name in ("state.json", "command.json"):
            (evidence / name).unlink(missing_ok=True)
        env = {**os.environ, "GRAFFITTY_TEST_EVIDENCE": str(evidence)}
        log = (evidence / "godot.log").open("w", encoding="utf-8")
        process = subprocess.Popen(
            [
                os.environ.get("GRAFFITTY_TEST_GODOT", "godot"),
                "--rendering-method",
                "gl_compatibility",
                "--path",
                os.environ.get(
                    "GRAFFITTY_TEST_PROJECT", str(ROOT / "frontends/godot/project")
                ),
                "--script",
                "tests/windows_window_frame_smoke.gd",
            ],
            env=env,
            stdout=log,
            stderr=log,
        )
        sequence = 0

        def state():
            self.assertIsNone(
                process.poll(), (evidence / "godot.log").read_text(encoding="utf-8")
            )
            try:
                return json.loads((evidence / "state.json").read_text())
            except (FileNotFoundError, json.JSONDecodeError, PermissionError):
                return None

        def command(action, **values):
            nonlocal sequence
            sequence += 1
            temp = evidence / "command.tmp"
            temp.write_text(
                json.dumps({"sequence": sequence, "action": action, **values})
            )
            temp.replace(evidence / "command.json")
            return wait(lambda: (s := state()) and s["sequence"] == sequence and s)

        def check_corners(hwnd, expected):
            if sys.getwindowsversion().build >= 22000:
                actual = w.DWORD()
                self.assertEqual(dwm.DwmGetWindowAttribute(
                    hwnd, 33, ctypes.byref(actual), ctypes.sizeof(actual)
                ), 0)
                self.assertEqual(actual.value, expected)

        def frame(hwnd):
            rect = w.RECT()
            user.GetWindowRect(hwnd, ctypes.byref(rect))
            return rect

        def point(hwnd, x, y):
            result = w.POINT(round(x), round(y))
            user.ClientToScreen(hwnd, ctypes.byref(result))
            return result

        def pack(p):
            return (p.x & 0xFFFF) | ((p.y & 0xFFFF) << 16)

        def hit(hwnd, x, y):
            return user.SendMessageW(hwnd, 0x84, 0, pack(point(hwnd, x, y)))

        def screenshot(name, hwnd):
            from PIL import ImageGrab

            r = frame(hwnd)
            ImageGrab.grab(
                bbox=(r.left, r.top, r.right, r.bottom), all_screens=True
            ).save(evidence / name)

        try:
            current = wait(state, 40)
            hwnd = current["hwnd"]
            self.assertTrue(
                current["attached"], "Godot must attach the Windows extension"
            )
            check_corners(hwnd, 2)
            user.SetForegroundWindow(hwnd)
            origin = point(hwnd, 0, 0)
            self.assertEqual(
                origin.y, frame(hwnd).top, "Content replaces the standard caption"
            )
            self.assertEqual(
                current["margins"][0], 0, "No macOS traffic-light gap on Windows"
            )
            self.assertGreater(current["margins"][1], 90)
            self.assertEqual(current["bar"][1], 0, "Tab strip starts at the client top")
            self.assertLessEqual(current["bar"][3], 44, "Caption uses one compact row")
            tabs = current["tabs"]
            self.assertLess(tabs[0], 60, "Tabs begin at the left after the menu button")
            self.assertEqual(
                hit(hwnd, tabs[0] + 30, tabs[1] + 18), 1, "Tabs receive client input"
            )
            plus = current["plus"]
            self.assertEqual(hit(hwnd, plus[0] + 12, plus[1] + 12), 1)
            gap_x = current["bar"][2] - current["margins"][1] - 4
            self.assertEqual(
                hit(hwnd, gap_x, 20), 2, "Empty space is a native draggable caption"
            )
            self.assertEqual(hit(hwnd, 200, 1), 12, "Top edge keeps native resizing")
            buttons = w.RECT()
            self.assertEqual(
                dwm.DwmGetWindowAttribute(
                    hwnd, 5, ctypes.byref(buttons), ctypes.sizeof(buttons)
                ),
                0,
            )
            outer = frame(hwnd)
            button_points = []
            for i, expected in enumerate((8, 9, 20)):
                p = w.POINT(
                    outer.left
                    + buttons.left
                    + round((i + 0.5) * (buttons.right - buttons.left) / 3),
                    outer.top + (buttons.top + buttons.bottom) // 2,
                )
                button_points.append(p)
                self.assertEqual(
                    user.SendMessageW(hwnd, 0x84, 0, pack(p)),
                    expected,
                    "Native minimize/maximize/close hit regions (including Snap Layout)",
                )
            # Exercise actual non-client enter/leave delivery and restore the
            # pointer after the fixture. The adapter observes native messages.
            user.SetCursorPos(button_points[1].x, button_points[1].y)
            wait(lambda: (s := state()) and len(s["caption"]) == 17 and s["caption"][13] == 1)
            body = point(hwnd, 100, 160)
            user.SetCursorPos(body.x, body.y)
            wait(lambda: (s := state()) and s["caption"][13] == -1)
            screenshot("window-normal.png", hwnd)
            from PIL import Image

            painted = Image.open(evidence / "window-normal.png").convert("RGB")
            for p in button_points:
                x, y = p.x - outer.left, p.y - outer.top
                glyph = painted.crop((x - 12, y - 12, x + 12, y + 12))
                self.assertGreater(
                    sum(
                        min(glyph.getpixel((x, y))) > 100
                        for y in range(glyph.height)
                        for x in range(glyph.width)
                    ),
                    8,
                    "Each native caption button has a visible glyph above Godot",
                )
            # Real client messages must select the second tab, not move the window.
            p = w.POINT(round(tabs[0] + tabs[2] / 2), round(tabs[1] + 18))
            user.PostMessageW(hwnd, 0x201, 1, pack(p))
            user.PostMessageW(hwnd, 0x202, 0, pack(p))
            wait(lambda: (s := state()) and s["active"] == 2)
            caption = point(hwnd, gap_x, 20)
            user.PostMessageW(
                hwnd, 0xA3, 2, pack(caption)
            )  # WM_NCLBUTTONDBLCLK / HTCAPTION
            wait(lambda: user.IsZoomed(hwnd))
            time.sleep(0.3)
            screenshot("window-maximized.png", hwnd)
            self.assertEqual(
                hit(hwnd, 200, 1), 2, "Maximized top edge is not resizable"
            )
            user.PostMessageW(hwnd, 0x112, 0xF120, 0)  # SC_RESTORE
            wait(lambda: not user.IsZoomed(hwnd))
            moved = command("move", x=180, y=140)
            self.assertEqual(
                moved["position"], [180, 140], "Moving uses the real custom-frame inset"
            )
            for scale in (1.25, 1.5, 1.75, 2.0, 1.0):
                scaled = command("scale", value=scale)
                self.assertAlmostEqual(
                    scaled["margins"][1] * scale, current["margins"][1], delta=2
                )
                plus = scaled["plus"]
                end = plus[0] + plus[2]
                boundary = math.floor(end + 0.5)
                center_y = plus[1] + plus[3] / 2
                self.assertEqual(hit(hwnd, boundary - 1, center_y), 1, "Last pixel of the new-tab button")
                self.assertEqual(hit(hwnd, boundary, center_y), 2, "First pixel of the draggable gap")
                self.assertLessEqual(
                    end, scaled["bar"][2] - scaled["margins"][1] * scale
                )
            full = command("mode", value=3)
            self.assertEqual(
                full["margins"][1], 0, "Fullscreen reserves no caption buttons"
            )
            command("mode", value=0)
            child = command("preview")["preview"]
            check_corners(child["hwnd"], 2)
            self.assertTrue(
                child["attached"], "Detached preview gets its own native frame"
            )
            self.assertEqual(
                hit(child["hwnd"], 100, 20), -1, "Preview does not capture the drag"
            )
            child = command("preview_move")["preview"]
            for axis, expected in enumerate((610, 340)):
                self.assertAlmostEqual(
                    child["position"][axis] + child["grab"][axis], expected, delta=1
                )
            command("preview_close")
            for small in (False, True):
                preference = 3 if small else 2
                check_corners(command("panel", small=small)["panel_hwnd"], preference)
                check_corners(command("panel_remap")["panel_hwnd"], preference)
                command("panel_close")
            user.PostMessageW(hwnd, 0x112, 0xF020, 0)  # SC_MINIMIZE
            wait(lambda: user.IsIconic(hwnd))
            user.PostMessageW(hwnd, 0x112, 0xF120, 0)
            wait(lambda: not user.IsIconic(hwnd))
            user.PostMessageW(hwnd, 0x112, 0xF060, 0)  # SC_CLOSE
            wait(lambda: (s := state()) and s["close_requests"] == 1)
            self.assertIsNone(
                process.poll(), "Close routes through Godot's existing close handler"
            )
            (evidence / "result.json").write_text(
                json.dumps(
                    {
                        "passed": True,
                        "checks": [
                            "native caption buttons",
                            "Snap Layout hit target",
                            "tab input",
                            "drag regions",
                            "resize edges",
                            "maximize/restore",
                            "minimize/restore",
                            "125/150/175/200% UI scaling",
                            "fullscreen",
                            "detached preview",
                            "client-coordinate movement",
                            "close_requested",
                        ],
                    },
                    indent=2,
                )
            )
        finally:
            user.SetCursorPos(original_pointer.x, original_pointer.y)
            if process.poll() is None:
                sequence += 1
                (evidence / "command.json").write_text(
                    json.dumps({"sequence": sequence, "action": "quit"})
                )
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=5)
            log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    os.environ["GRAFFITTY_TEST_EVIDENCE"] = str(args.evidence.resolve())
    unittest.main(argv=[__file__], verbosity=2)
