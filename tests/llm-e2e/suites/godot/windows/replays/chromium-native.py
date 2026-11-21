"""Capture and close only a test-owned Chromium native window."""
import ctypes
from ctypes import wintypes as w
from pathlib import Path
import sys
import time
from PIL import ImageGrab

pid = int(sys.argv[1])
output = Path(sys.argv[2]).resolve()
user = ctypes.WinDLL("user32", use_last_error=True)
user.SetProcessDpiAwarenessContext.argtypes = [w.HANDLE]
user.SetProcessDpiAwarenessContext(w.HANDLE(-4))
callback_type = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
user.GetWindowThreadProcessId.argtypes = [w.HWND, ctypes.POINTER(w.DWORD)]
user.IsWindowVisible.argtypes = [w.HWND]
user.GetWindowRect.argtypes = [w.HWND, ctypes.POINTER(w.RECT)]
user.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
user.EnumWindows.argtypes = [callback_type, w.LPARAM]
windows = []
@callback_type
def collect(hwnd, _):
    owner = w.DWORD()
    user.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
    if owner.value == pid and user.IsWindowVisible(hwnd): windows.append(hwnd)
    return True
user.EnumWindows(collect, 0)
if len(windows) != 1: raise SystemExit(f"Expected one visible owned chromium, got {len(windows)}")
rect = w.RECT()
if not user.GetWindowRect(windows[0], ctypes.byref(rect)): raise ctypes.WinError(ctypes.get_last_error())
if sys.argv[2] == "--activate":
    # A replay's Input.parse_input_event does not establish Windows foreground
    # permission. Give this owned Godot window actual desktop input first.
    user.SetWindowPos.argtypes = [w.HWND, w.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, w.UINT]
    # The replay runs this helper on a worker, keeping Godot's UI responsive.
    user.SetWindowPos(windows[0], w.HWND(0), 0, 0, 0, 0, 0x4013)
    time.sleep(.1)
    user.SetCursorPos(rect.left + 40, rect.top + 110)
    user.mouse_event(0x0002, 0, 0, 0, 0)
    user.mouse_event(0x0004, 0, 0, 0, 0)
    user.SetForegroundWindow.argtypes = [w.HWND]
    activated = user.SetForegroundWindow(windows[0])
    user.GetForegroundWindow.restype = w.HWND
    user.WindowFromPoint.argtypes = [w.POINT]
    user.WindowFromPoint.restype = w.HWND
    hit = user.WindowFromPoint(w.POINT(rect.left + 40, rect.top + 110))
    hit_pid = w.DWORD()
    user.GetWindowThreadProcessId(hit, ctypes.byref(hit_pid))
    foreground_pid = w.DWORD()
    user.GetWindowThreadProcessId(user.GetForegroundWindow(), ctypes.byref(foreground_pid))
    print("focus target", pid, "rect", (rect.left, rect.top, rect.right, rect.bottom), "click owner", hit_pid.value, "activation", activated, "foreground", foreground_pid.value, flush=True)
    deadline = time.monotonic() + 2
    while user.GetForegroundWindow() != windows[0] and time.monotonic() < deadline:
        time.sleep(.01)
    if user.GetForegroundWindow() != windows[0]:
        raise SystemExit("The owned Godot window did not receive desktop focus")
    raise SystemExit(0)
output.parent.mkdir(parents=True, exist_ok=True)
ImageGrab.grab(bbox=(rect.left, rect.top, rect.right, rect.bottom), all_screens=True).save(output)
if not user.PostMessageW(windows[0], 0x112, 0xF060, 0): raise ctypes.WinError(ctypes.get_last_error())
