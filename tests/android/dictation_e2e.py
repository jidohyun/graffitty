#!/usr/bin/env python3
"""Real Godot/server Live WebSocket streaming, cancellation and pane insertion."""
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from e2e_background import prepare_background


def main():
    root = Path(tempfile.mkdtemp(prefix="graffitty-dictation-"))
    print("Evidence:", root, flush=True)
    received, failures = [], []

    class Provider(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *_):
            pass

        def event(self, value):
            payload = json.dumps(value).encode()
            header = bytes([0x81, len(payload)]) if len(payload) < 126 else b"\x81\x7e" + struct.pack("!H", len(payload))
            self.wfile.write(header + payload)
            self.wfile.flush()

        def read_event(self):
            header = self.rfile.read(2)
            if len(header) != 2 or header[0] & 15 == 8:
                raise EOFError
            size = header[1] & 127
            if size == 126:
                size = struct.unpack("!H", self.rfile.read(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", self.rfile.read(8))[0]
            assert size < 65536 and header[1] & 128
            mask = self.rfile.read(4)
            payload = self.rfile.read(size)
            return json.loads(bytes(c ^ mask[i % 4] for i, c in enumerate(payload)))

        def do_GET(self):
            try:
                assert self.path == "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
                assert self.headers["x-goog-api-key"] == "server-secret"
                accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()
                setup = self.read_event()["setup"]
                assert setup["model"] == "models/gemini-3.5-transcribe-live"
                assert setup["realtimeInputConfig"]["automaticActivityDetection"]["disabled"]
                assert setup["inputAudioTranscription"]["languageCodes"] == ["ko-KR"]
                time.sleep(.2)  # Exercise queued audio and Stop before setup completes.
                self.event({"setupComplete": {}})
                started = False
                while True:
                    value = self.read_event()["realtimeInput"]
                    if "activityStart" in value:
                        assert not started
                        started = True
                    elif "audio" in value:
                        assert started
                        audio = value["audio"]
                        assert audio["mimeType"] == "audio/pcm;rate=16000"
                        raw = base64.b64decode(audio["data"])
                        assert raw and len(raw) % 2 == 0
                        received.append(len(raw))
                        self.event({"serverContent": {"interimInputTranscription": {"text": "Interim words"}}})
                    elif "activityEnd" in value:
                        assert started
                        # turnComplete alone is not final source transcription.
                        self.event({"serverContent": {"turnComplete": True}})
                        time.sleep(.15)
                        self.event({"serverContent": {"inputTranscription": {"text": "안녕 final words"}, "generationComplete": True}})
                    else:
                        raise AssertionError(value)
            except (EOFError, BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                failures.append(repr(error))
                print("Provider fixture:", repr(error), flush=True)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GRAFFITTY_", "CODEX_"))}
    for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
        env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
    env.update(GRAFFITTY_DICTATION_TEST_OUTPUT=str(root / "typed.txt"),
               GRAFFITTY_GEMINI_API_KEY="server-secret",
               GRAFFITTY_SERVER__DICTATION__ENABLED="true",
               GRAFFITTY_SERVER__DICTATION__PROVIDER="gemini",
               GRAFFITTY_SERVER__DICTATION__LANGUAGE="ko",
               GRAFFITTY_SERVER__DICTATION__PROVIDERS__GEMINI__BASE_URL=f"http://127.0.0.1:{server.server_port}/v1beta")
    try:
        with PrivateServer(env, root, "/bin/sh"):
            args = prepare_background(env, root / "native") if "--gpu" in sys.argv else ["--headless"]
            with (root / "godot.log").open("w") as log:
                result = subprocess.run(["godot", *args, "--path", str(ROOT / "frontends/godot/project"),
                                         "--script", "res://tests/dictation_smoke.gd", "--", "--shell=/bin/sh"],
                                        env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
            output = (root / "godot.log").read_text()
            print(output)
            assert result.returncode == 0 and "DICTATION_SMOKE_REPLAY_PASS" in output
            assert received and not failures, failures
            assert 320 in received, "The 10 ms recording must survive setup and stop"
    finally:
        server.shutdown()
        server.server_close()
    print("DICTATION_PASS")


if __name__ == "__main__":
    main()
