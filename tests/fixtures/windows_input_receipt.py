"""Read actual ConPTY input inside the tested shell; never inject desktop input."""
import ctypes
import argparse
from ctypes import wintypes
import json
import os
from pathlib import Path
import queue
import sys
import threading
import time


def emit_output(text):
    # An unbuffered Windows console write can accept only a prefix of a large
    # TextIOWrapper write. Keep each call bounded and check its result so the
    # fixture actually emits the entire transfer through ConPTY.
    for offset in range(0, len(text), 2048):
        chunk = text[offset:offset + 2048]
        if sys.stdout.write(chunk) != len(chunk):
            raise RuntimeError('Short fixture console write')
        sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--timeout', type=float, default=45)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 180: parser.error('timeout must be between 1 and 180 seconds')
    directory = args.directory
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetStdHandle.argtypes = [wintypes.DWORD]
    kernel.GetStdHandle.restype = wintypes.HANDLE
    kernel.GetConsoleMode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.SetConsoleMode.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    modes = []
    for number in (-10, -11):
        handle = kernel.GetStdHandle(number & 0xffffffff)
        previous = wintypes.DWORD()
        if not kernel.GetConsoleMode(handle, ctypes.byref(previous)):
            raise ctypes.WinError(ctypes.get_last_error())
        mode = (previous.value & ~7) | 0x200 if number == -10 else previous.value | 4
        if not kernel.SetConsoleMode(handle, mode):
            raise ctypes.WinError(ctypes.get_last_error())
        modes.append((handle, previous.value))
    received = ""
    chunks = queue.Queue()
    stopping = threading.Event()
    kernel.ReadConsoleW.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]

    def read_stream():
        # getwch() filters INPUT_RECORDs to keyboard events. ReadConsoleW is
        # the VT stream boundary and includes encoded mouse reports.
        while not stopping.is_set():
            data = ctypes.create_unicode_buffer(256)
            count = wintypes.DWORD()
            if not kernel.ReadConsoleW(modes[0][0], data, 256, ctypes.byref(count), None):
                break
            chunks.put(data[:count.value])

    reader = threading.Thread(target=read_stream, daemon=True)
    reader.start()
    try:
        print("\x1b[2J\x1b[HPRIVATE_INPUT_READY\r\nneedle raw input fixture", flush=True)
        if (directory / "start.vt").exists():
            emit_output((directory / "start.vt").read_text(encoding="utf-8"))
            print("\r\nPRIVATE_MODES_READY", flush=True)
        (directory / "ready").touch()
        deadline = time.monotonic() + args.timeout
        phase = 1
        progress_at = 0
        while time.monotonic() < deadline:
            try:
                received += chunks.get(timeout=.2)
            except queue.Empty:
                if (directory / "finish").exists():
                    break
            for request in directory.glob('grid-request-*'):
                response = directory / request.name.replace('grid-request-', 'grid-response-')
                if not response.exists():
                    grid = os.get_terminal_size()
                    response.write_text(json.dumps({'columns': grid.columns, 'rows': grid.lines, 'pid': os.getpid()}), encoding='utf-8')
            if (directory / 'expected-initial-bytes').exists() and time.monotonic() >= progress_at:
                (directory / 'received-bytes').write_text(str(len(received)), encoding='utf-8')
                progress_at = time.monotonic() + .1
            command = directory / f"phase-{phase}.vt"
            if command.exists():
                (directory / f"receipt-before-phase-{phase}.json").write_text(json.dumps({"text": received}), encoding="utf-8")
                emit_output(command.read_text(encoding="utf-8"))
                if not (directory / 'quiet-phases').exists():
                    print(f"\r\nPRIVATE_PHASE_{phase}_READY", flush=True)
                phase += 1
        (directory / "receipt.json").write_text(json.dumps({"text": received, "utf8_hex": received.encode("utf-8").hex(), "input_mode": modes[0][1]}), encoding="utf-8")
    finally:
        stopping.set()
        kernel.OpenThread.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenThread.restype = wintypes.HANDLE
        kernel.CancelSynchronousIo.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        thread_handle = kernel.OpenThread(1, False, reader.native_id)
        if thread_handle:
            kernel.CancelSynchronousIo(thread_handle)
            kernel.CloseHandle(thread_handle)
        reader.join(timeout=1)
        sys.stdout.write("\x1b[?1000l\x1b[?1006l\x1b[?1049l")
        sys.stdout.flush()
        for handle, previous in modes:
            kernel.SetConsoleMode(handle, previous)
    print("PRIVATE_INPUT_FINISHED", flush=True)


if __name__ == "__main__":
    main()
