"""Test the icat CLI and controlling TTY.

    cargo build -p graffitty-cli
    python3 -m unittest discover -s tests/server -p test_icat.py

Set GRAFFITTY_TEST_BIN to use a different binary. The test runs without
a GUI or external image tools.
"""
import base64
import http.server
import os
from pathlib import Path
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]
BIN = Path(os.environ.get("GRAFFITTY_TEST_BIN", ROOT / "target/debug/gft"))
OFFLINE = ("--use-window-size=80,24,800,480", "--transfer-mode=stream", "--passthrough=none")


def png(width=2, height=1):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\x20\x40\xff" * width) * height))
            + chunk(b"IEND", b""))


def packets(data):
    return [(dict(key.split("=", 1) for key in keys.decode().split(",")), base64.b64decode(payload))
            for keys, payload in re.findall(rb"\x1b_G([^;]*);([^\x1b]*)\x1b\\", data)]


def run(*args, data=b"", offline=True):
    env = {key: value for key, value in os.environ.items() if key != "TMUX" and not key.startswith("GRAFFITTY_")}
    return subprocess.run([str(BIN), "terminal", "icat", *(OFFLINE if offline else ()), *map(str, args)],
                          input=data, capture_output=True, env=env,
                          start_new_session=True, timeout=10)


@unittest.skipUnless(BIN.exists(), "cargo build -p graffitty-cli first")
class IcatTests(unittest.TestCase):
    def test_stdin_and_dash(self):
        for args in ((), ("--stdin=yes",), ("-",)):
            with self.subTest(args=args):
                result = run(*args, data=png())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(packets(result.stdout)[0][0]["a"], "T")

    def test_files_directories_file_urls_and_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "subdir").mkdir()
            (root / "first image.png").write_bytes(png())
            (root / "subdir/second.png").write_bytes(png())
            (root / "ignore.txt").write_text("not an image")
            result = run("--image-id=4294967295", root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual([keys["i"] for keys, _ in packets(result.stdout)], ["4294967295", "1"])
            result = run("--stdin=no", (root / "first image.png").as_uri())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(packets(result.stdout)), 1)

    def test_no_tty_recipe_and_placement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "photo.png"
            path.write_bytes(png(100, 50))
            result = run("--stdin=no", "--place=4x3@2x1", "--align=left", path)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.startswith(b"\r\x1b[2;3H"))
            keys, payload = packets(result.stdout)[0]
            self.assertEqual((keys["s"], keys["v"], keys["C"]), ("40", "20", "1"))
            self.assertEqual(struct.unpack(">II", payload[16:24]), (40, 20))
            self.assertFalse(result.stdout.endswith(b"\n"))

    def test_http_url_and_http_error(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if self.path == "/image.png" else 404)
                self.end_headers()
                self.wfile.write(png())
            def log_message(self, *_args):
                pass
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}"
                good = run("--stdin=no", url + "/image.png")
                self.assertEqual(good.returncode, 0, good.stderr)
                bad = run("--stdin=no", url + "/missing")
                self.assertNotEqual(bad.returncode, 0)
                self.assertIn(b"404", bad.stderr)
            finally:
                server.shutdown()
                thread.join()

    def test_clear_and_window_size_do_not_need_tty(self):
        for flag, target in (("--clear", "A"), ("--clear-all", "R")):
            result = run(flag, "--stdin=no", offline=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(packets(result.stdout)[0][0]["d"], target)
        result = run("--print-window-size")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"800x480")
        result = run("--clear", data=png())
        self.assertEqual([keys["a"] for keys, _ in packets(result.stdout)], ["d", "T"])

    def test_place_rejects_multiple_images_before_displaying(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "image.png"
            path.write_bytes(png())
            result = run("--stdin=no", "--place=10x5@0x0", path, path)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertIn(b"single image", result.stderr)

    def test_bad_options_and_corrupt_input(self):
        for args in (("--align=bad",), ("--place=0x1@0x0",), ("--use-window-size=0,24,800,480",),
                     ("--detection-timeout=NaN",), ("--image-id=-+1",), ("--clear=maybe",)):
            with self.subTest(args=args):
                result = run(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
        result = run("--engine=builtin", "--stdin=yes", data=b"invalid image")
        self.assertNotEqual(result.returncode, 0)

    def test_passthrough_implies_placeholders(self):
        result = run("--passthrough=tmux", data=png())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"\x1bPtmux;\x1b\x1b_G", result.stdout)
        self.assertIn("\U0010eeee".encode(), result.stdout)

    def test_help_and_completion_include_icat(self):
        result = run("--help", offline=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        for flag in (b"--clear-all", b"--transfer-mode", b"--unicode-placeholder", b"--loop"):
            self.assertIn(flag, result.stdout)
        result = subprocess.run([str(BIN), "__complete_word__", "--shell", "zsh", "--line", "gft terminal icat --trans"], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"--transfer-mode", result.stdout)

    @unittest.skipUnless(shutil.which("magick"), "ImageMagick not installed")
    def test_imagemagick_engine_and_svg_fallback(self):
        data = b'<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8"><rect width="12" height="8" fill="red"/></svg>'
        for engine in ("magick", "auto"):
            result = run("--engine=" + engine, data=data)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(packets(result.stdout)[0][0]["s"], "12")

    @unittest.skipUnless(os.name == "posix", "requires POSIX PTYs")
    def test_background_preview_reads_size_without_changing_tty_modes(self):
        import fcntl
        import pty
        import termios
        master, slave = pty.openpty()
        try:
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 800, 480))
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "preview.png"
                path.write_bytes(png())
                keeper = """
import os, subprocess, sys, termios
fd = int(sys.argv[1])
before = termios.tcgetattr(fd)
child = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=os.setpgrp)
try:
    out, err = child.communicate(timeout=3)
except subprocess.TimeoutExpired:
    child.kill()
    child.communicate()
    sys.exit('Background preview suspended while reading terminal size')
assert termios.tcgetattr(fd) == before, 'Preview changed terminal modes'
sys.stdout.buffer.write(out)
sys.stderr.buffer.write(err)
sys.exit(child.returncode)
"""
                result = subprocess.run(
                    [sys.executable, "-c", keeper, str(slave), str(BIN), "terminal", "icat",
                     "--stdin=no", "--transfer-mode=stream", "--passthrough=none",
                     "--unicode-placeholder", "--place=20x10@0x0", str(path)],
                    capture_output=True, start_new_session=True, pass_fds=(slave,),
                    preexec_fn=lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0), timeout=6)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(packets(result.stdout))
                self.assertIn("\U0010eeee".encode(), result.stdout)
        finally:
            os.close(master)
            os.close(slave)

    @unittest.skipUnless(os.name == "posix", "requires POSIX PTYs")
    def test_queries_and_raw_mode_restoration(self):
        import fcntl
        import pty
        import termios
        for replies, expected, pixel_size in ((b"\x1b_Gi=1;OK\x1b\\", b"stream", (800, 480)),
                                               (b"\x1b_Gi=1;OK\x1b\\\x1b_Gi=2;OK\x1b\\", b"file", (800, 480)),
                                               (b"\x1b_Gi=1;OK\x1b\\\x1b_Gi=3;OK\x1b\\", b"memory", (800, 480)),
                                               (b"", None, (800, 480)),
                                               (None, None, (800, 480)),
                                               (b"\x1b_Gi=1;OK\x1b\\", b"stream", (0, 0))):
            with self.subTest(expected=expected, replies=replies, size=pixel_size):
                master, slave = pty.openpty()
                try:
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, *pixel_size))
                    # A session leader keeps the PTY alive to inspect its modes
                    # after icat exits; macOS revokes it when that leader exits.
                    keeper = """
import subprocess, sys, termios
fd = int(sys.argv[1])
before = termios.tcgetattr(fd)
code = subprocess.call(sys.argv[2:])
after = termios.tcgetattr(fd)
# macOS sets this transient kernel status bit when restoring canonical mode.
before[3] &= ~getattr(termios, 'PENDIN', 0)
after[3] &= ~getattr(termios, 'PENDIN', 0)
if after != before:
    print('RAW_MODE_NOT_RESTORED', file=sys.stderr)
sys.exit(code)
"""
                    proc = subprocess.Popen([sys.executable, "-c", keeper, str(slave), str(BIN), "terminal", "icat", "--detect-support", "--passthrough=none", "--detection-timeout=.2"],
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                            start_new_session=True, pass_fds=(slave,),
                                            preexec_fn=lambda: fcntl.ioctl(slave, termios.TIOCSCTTY, 0))
                    pending = b""
                    while proc.poll() is None:
                        if select.select([master], [], [], 0.05)[0]:
                            pending += os.read(master, 65536)
                            if b"\x1b[c" in pending:
                                if b"\x1b[14t" in pending:
                                    response = b"\x1b[4;480;800t\x1b[8;24;80t\x1b[?1;2c"
                                elif replies is not None:
                                    response = replies + b"\x1b[?1;2c"
                                else:
                                    response = b""
                                for start in range(0, len(response), 5):
                                    os.write(master, response[start:start + 5])
                                pending = b""
                    stdout, stderr = proc.communicate(timeout=3)
                    self.assertEqual(stdout, b"")
                    if expected:
                        self.assertEqual(proc.returncode, 0, stderr)
                        self.assertEqual(stderr.strip(), expected)
                    else:
                        self.assertNotEqual(proc.returncode, 0)
                    self.assertNotIn(b"RAW_MODE_NOT_RESTORED", stderr)
                finally:
                    os.close(master)
                    os.close(slave)


if __name__ == "__main__":
    unittest.main()
