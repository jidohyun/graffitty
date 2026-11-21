#!/usr/bin/env python3
"""Own an isolated server and loopback Gemini/OpenAI fixtures; no real keys."""
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

directory, mode, provider_name, model = Path(sys.argv[1]), *sys.argv[2:]


def record(**event):
    with (directory / "provider.jsonl").open("a") as log:
        log.write(json.dumps(event) + "\n")


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def receive(self):
        header = self.rfile.read(2)
        if len(header) != 2 or header[0] & 15 == 8:
            return None
        size = header[1] & 127
        if size == 126:
            size = struct.unpack("!H", self.rfile.read(2))[0]
        elif size == 127:
            size = struct.unpack("!Q", self.rfile.read(8))[0]
        assert size < 65536 and header[1] & 128
        mask = self.rfile.read(4)
        data = self.rfile.read(size)
        return json.loads(bytes(byte ^ mask[index % 4] for index, byte in enumerate(data)))

    def send(self, value):
        body = json.dumps(value).encode()
        length = bytes([len(body)]) if len(body) < 126 else b"\x7e" + struct.pack("!H", len(body))
        self.wfile.write(b"\x81" + length + body)
        self.wfile.flush()

    def error(self, code):
        self.send({"type": "error", "error": {"code": code, "message": "Sensitive provider detail: invalid-test-key"}})

    def do_GET(self):
        try:
            self.session()
        except (BrokenPipeError, ConnectionResetError):
            record(event="disconnected")
        except Exception as error:
            record(event="fixture-error", detail=repr(error))
        finally:
            self.close_connection = True

    def session(self):
        openai = provider_name == "openai"
        key_ok = (self.headers.get("Authorization") == "Bearer invalid-test-key" if openai
                  else self.headers.get("x-goog-api-key") == "invalid-test-key")
        record(event="connection", key_is_dummy=key_ok, path=self.path, mode=mode)
        assert key_ok
        if openai:
            assert self.path == "/v1/realtime?intent=transcription"
        error = {"error": {"code": 400, "status": "INVALID_ARGUMENT",
                           "message": "Sensitive provider detail: invalid-test-key",
                           "details": [{"reason": "API_KEY_INVALID"}]}}
        if mode in ("bad-key-401", "bad-key-403", "rate-limit-http"):
            status = {"bad-key-401": 401, "bad-key-403": 403, "rate-limit-http": 429}[mode]
            if status == 429:
                error = {"error": {"code": "rate_limit_exceeded"}}
            body = json.dumps(error).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        accept = base64.b64encode(hashlib.sha1(
            (self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        ).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        setup = self.receive()
        record(event="setup", setup=setup)
        if openai:
            assert setup["type"] == "session.update"
            assert setup["session"]["type"] == "transcription"
            audio = setup["session"]["audio"]["input"]
            assert audio["format"] == {"type": "audio/pcm", "rate": 24000}
            assert audio["turn_detection"] is None and audio["noise_reduction"] is None
            assert audio["transcription"]["model"] == model
            assert audio["transcription"]["languages"] == ["ko"]
            assert (audio["transcription"].get("delay") == "minimal") == (model == "gpt-live-transcribe")
        else:
            assert setup["setup"]["model"] == "models/gemini-3.5-transcribe-live"
        if mode == "bad-key-event":
            self.error("invalid_api_key") if openai else self.send(error)
            time.sleep(.3)
            return
        if mode in ("quota-event", "model-error"):
            self.error("insufficient_quota" if mode == "quota-event" else "model_not_found")
            time.sleep(.3)
            return
        assert openai
        if mode == "setup-timeout":
            time.sleep(15)
            return
        if mode == "early-stop":
            time.sleep(1)
        self.send({"type": "session.updated"})
        total = 0
        while True:
            event = self.receive()
            if event is None:
                record(event="closed", bytes=total)
                return
            if event["type"] == "input_audio_buffer.append":
                pcm = base64.b64decode(event["audio"], validate=True)
                assert len(pcm) % 2 == 0 and 0 < len(pcm) <= 4800
                record(event="audio", bytes=len(pcm))
                if total == 0 and model == "gpt-live-transcribe" and mode != "empty-commit":
                    self.send({"type": "conversation.item.input_audio_transcription.delta", "item_id": "word", "delta": "안녕 draft"})
                total += len(pcm)
                if mode == "cancel":
                    time.sleep(.7)
                    self.send({"type": "conversation.item.input_audio_transcription.completed", "item_id": "word", "transcript": "must never insert"})
            elif event["type"] == "input_audio_buffer.commit":
                assert total >= 4800
                record(event="commit", bytes=total)
                if mode == "empty-commit":
                    self.error("input_audio_buffer_commit_empty")
                elif mode == "failed-event":
                    self.send({"type": "conversation.item.input_audio_transcription.failed", "item_id": "word"})
                elif mode == "disconnect":
                    self.wfile.write(b"\x88\x02\x03\xf0")  # Policy close 1008.
                    self.wfile.flush()
                    return
                elif mode == "final-timeout":
                    time.sleep(15)
                    return
                else:
                    self.send({"type": "input_audio_buffer.committed", "item_id": "word", "previous_item_id": None})
                    time.sleep(.15)
                    self.send({"type": "conversation.item.input_audio_transcription.completed", "item_id": "word", "transcript": "안녕 final words"})
                time.sleep(.3)
                return
            else:
                raise AssertionError(event)


provider = ThreadingHTTPServer(("127.0.0.1", 7184), Provider)
threading.Thread(target=provider.serve_forever, daemon=True).start()
env = {key: value for key, value in os.environ.items() if not key.startswith("GRAFFITTY_")}
for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
    env[f"XDG_{kind}_HOME"] = str(directory / kind.lower())
if mode != "missing-key":
    env[f"GRAFFITTY_{provider_name.upper()}_API_KEY"] = "invalid-test-key"
with (directory / "server.log").open("w") as log:
    server = subprocess.Popen([
        "/target/debug/gft", "server", "--config", str(directory / "server.toml"),
        "--connection", str(directory / "server.json"), "--listen", "0.0.0.0:7183",
        "--auth-file", str(directory / "auth.json"), "--shell", "/bin/sh",
    ], env=env, stdout=log, stderr=subprocess.STDOUT)
    try:
        while not (directory / "stop").exists():
            if server.poll() is not None:
                raise RuntimeError(f"Test server exited: {server.returncode}")
            time.sleep(.05)
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
        provider.shutdown()
        provider.server_close()
        (directory / "stopped").touch()
