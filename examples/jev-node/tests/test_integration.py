"""Real FastAPI processes + real Godot graph/socket; only Jev is mocked."""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
import pytest

from test_node import event_file

EXAMPLE = Path(__file__).resolve().parents[1]
ROOT = EXAMPLE.parents[1]


def wait_until(check, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Timed out waiting for integration result")


def rpc(path, token, method, params):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(5)
        peer.connect(str(path))
        request = {"id": str(uuid.uuid4()), "version": 1, "token": str(token),
                   "method": method, "params": params}
        peer.sendall((json.dumps(request) + "\n").encode())
        reply = json.loads(peer.makefile("rb").readline())
        assert reply["id"] == request["id"]
        assert "error" not in reply, reply
        return reply["result"]


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)


@pytest.mark.skipif(not shutil.which("godot"), reason="Requires Godot extension")
@pytest.mark.parametrize("provider,custom", [("codex", False), ("claude", True)])
def test_real_host_routing(provider, custom):
    with tempfile.TemporaryDirectory(prefix="jev-e2e-", dir="/tmp") as directory:
        directory = Path(directory)
        raw = event_file(directory, provider)
        # Actual host takes its own current byte checkpoint.
        with open(raw["sessions"][0]["path"], "r+b") as file:
            file.truncate(raw["sessions"][0]["checkpoint"]["byte_offset"])
        config = {"question": "Review outcome?"}
        if custom:
            config.update(options={"accept": "Approved", "revise": "Fixes needed"})
        config_path = directory / "config.json"
        config_path.write_text(json.dumps(config))
        captured = []

        class Jev(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                assert self.path == "/api/alpha/decisions"
                assert self.headers["Authorization"] == "Bearer integration-key"
                captured.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                answer = {"type": "choice", "choice": "revise"} if custom else {"type": "noul", "noul": 0.9}
                body = json.dumps({"answers": {"route": answer}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        model = ThreadingHTTPServer(("127.0.0.1", 0), Jev)
        thread = threading.Thread(target=model.serve_forever, daemon=True)
        thread.start()
        processes = []
        try:
            with (directory / "host.log").open("w+") as host_log, (directory / "node.log").open("w+") as node_log:
                host = subprocess.Popen(["godot", "--headless", "--path", str(ROOT), "--script", "tests/jev_node_host.gd"],
                    env={**os.environ, "JEV_TEST_DIRECTORY": str(directory)}, stdout=host_log, stderr=host_log,
                    start_new_session=True)
                processes.append(host)
                ready = directory / "ready.json"
                try:
                    wait_until(ready.exists)
                except AssertionError:
                    host_log.seek(0)
                    pytest.fail(host_log.read())
                endpoint = json.loads(ready.read_text())["socket"]
                env = {**os.environ, "GRAFFITTY_SOCKET": endpoint, "GRAFFITTY_TOKEN": "2",
                       "OPENROUTER_API_KEY": "integration-key", "JEV_CONFIG": str(config_path)}
                bootstrap = directory / "start.py"
                code = f"import sys\nsys.path.insert(0, {str(EXAMPLE)!r})\nimport common\ncommon.DECISIONS_URL = 'http://127.0.0.1:{model.server_port}/api/alpha/decisions'\n"
                with socket.socket() as port_socket:
                    port_socket.bind(("127.0.0.1", 0))
                    port = port_socket.getsockname()[1]
                code += f"import uvicorn\nfrom fastapi_node import app\nuvicorn.run(app, host='127.0.0.1', port={port}, log_level='warning')\n"
                command = [sys.executable, str(bootstrap)]
                bootstrap.write_text(code)
                process = subprocess.Popen(command, env=env, stdout=node_log, stderr=node_log, start_new_session=True)
                processes.append(process)
                def registered():
                    nodes = rpc(endpoint, 1, "graph.list", {})["nodes"]
                    return next((n for n in nodes if n["node"] == "%2" and n.get("manifest")), None)
                wait_until(registered)
                labels = list(config.get("options", {"True": "", "False": ""}))
                for label, target in zip(labels, [3, 4]):
                    rpc(endpoint, 1, "graph.connect", {"from": "%2", "to": f"%{target}", "from_port": label, "send": True})
                def healthy():
                    try:
                        return httpx.get(f"http://127.0.0.1:{port}/health").status_code == 200
                    except httpx.ConnectError:
                        return False
                wait_until(healthy)
                manifest = httpx.get(f"http://127.0.0.1:{port}/manifest", headers={"Authorization": "Bearer 2"}).json()
                assert {o["id"] for o in manifest["outputs"]} == set(labels)
                rpc(endpoint, 1, "agent.event", {"provider": provider, "event": "SessionStart",
                    "session_id": "fixture-session", "transcript_path": raw["sessions"][0]["path"]})
                rpc(endpoint, 1, "graph.connect", {"from": "%1", "to": "%2", "from_port": "turn_completed", "to_port": "evaluate"})
                rpc(endpoint, 1, "agent.event", {"provider": provider, "event": "Stop", "text": raw["text"]})
                try:
                    receipts = wait_until(lambda: rpc(endpoint, 1, "graph.list", {})["receipts"])
                except AssertionError:
                    node_log.seek(0)
                    pytest.fail(node_log.read())
                assert receipts[-1]["status"] == "delivered", receipts
                selected, other = (4, 3) if custom else (3, 4)
                output = rpc(endpoint, selected, "graph.take", {})["events"]
                assert len(output) == 1
                assert output[0]["source"] == "%2"
                assert output[0]["text"] == raw["text"]
                assert output[0]["source_port"] == ("revise" if custom else "True")
                assert output[0]["payload"] is None
                assert output[0]["sessions"][0]["path"] == raw["sessions"][0]["path"]
                assert output[0]["kind"] == "turn.completed"
                assert output[0]["run_id"]
                assert rpc(endpoint, other, "graph.take", {})["events"] == []
                assert len(captured) == 1
                state = captured[0]["state"]
                assert len(state["recent_messages"]) == 10
                assert state["recent_messages"][0]["text"] == "message 5 한글"
                assert state["last_message"] == raw["text"]
                stop(process)
                nodes = rpc(endpoint, 1, "graph.list", {})["nodes"]
                assert next(n for n in nodes if n["node"] == "%2")["status"] == "offline"
        finally:
            for process in reversed(processes):
                stop(process)
            model.shutdown()
            model.server_close()
            thread.join(timeout=2)
