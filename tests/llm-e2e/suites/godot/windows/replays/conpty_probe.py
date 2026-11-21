"""Run inside a Graffitty PTY, never in a separately created Python PTY."""
import ctypes
from ctypes import wintypes
import json
import msvcrt
from pathlib import Path
import re
import sys
import time


def main():
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetStdHandle.argtypes = [wintypes.DWORD]
    kernel.GetStdHandle.restype = wintypes.HANDLE
    kernel.GetConsoleMode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.SetConsoleMode.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    handle = kernel.GetStdHandle(-10 & 0xffffffff)
    previous = wintypes.DWORD()
    if not kernel.GetConsoleMode(handle, ctypes.byref(previous)):
        raise ctypes.WinError(ctypes.get_last_error())
    output = kernel.GetStdHandle(-11 & 0xffffffff)
    output_previous = wintypes.DWORD()
    if not kernel.GetConsoleMode(output, ctypes.byref(output_previous)):
        raise ctypes.WinError(ctypes.get_last_error())
    if not kernel.SetConsoleMode(output, output_previous.value | 0x4):
        raise ctypes.WinError(ctypes.get_last_error())
    if not kernel.SetConsoleMode(handle, (previous.value & ~0x7) | 0x200):
        raise ctypes.WinError(ctypes.get_last_error())
    received = ""
    try:
        print("CONPTY_PROBE_READY", flush=True)
        sys.stdout.write("\x1b]10;?\x07\x1b]11;?\x07\x1b[?1000h\x1b[?1006h")
        sys.stdout.flush()
        Path(sys.argv[1] + ".ready").write_text("ready", encoding="utf-8")
        deadline = time.monotonic() + 12
        reported = False
        while time.monotonic() < deadline:
            if msvcrt.kbhit():
                received += msvcrt.getwch()
            else:
                time.sleep(.005)
            colors = all(re.search(r"\x1b\]" + str(n) + r";rgb:[0-9a-fA-F/]+(?:\x07|\x1b\\)", received) for n in (10, 11))
            wheel = bool(re.search(r"\x1b\[<6[45];\d+;\d+M", received))
            if colors and wheel and not reported:
                Path(sys.argv[1]).write_text(json.dumps({"colors": colors, "wheel": wheel,
                    "received": received}), encoding="utf-8")
                reported = True
            # Keep consuming input until the replay has completed the entire
            # press/release gesture; don't leave queued mouse bytes for PSReadLine.
            if reported and Path(sys.argv[1] + ".finish").exists() and not msvcrt.kbhit():
                break
    finally:
        sys.stdout.write("\x1b[?1000l\x1b[?1006l")
        sys.stdout.flush()
        kernel.SetConsoleMode(handle, previous.value)
        kernel.SetConsoleMode(output, output_previous.value)
    result = {"colors": colors, "wheel": wheel, "received": received,
              "original_input_mode": previous.value, "original_output_mode": output_previous.value}
    Path(sys.argv[1]).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print("CONPTY_PROBE_DONE", flush=True)
    return 0 if colors and wheel else 1


if __name__ == "__main__":
    sys.exit(main())
