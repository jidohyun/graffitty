# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Real Chromium: visited pages come back as Chrome-ranked address-bar history.

Needs a CEF framework and host built from fork/cef with graffitty_history.cc.
"""

import json
import os
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "index"
        body = f"<title>Graffitty history {name}</title><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    site = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=site.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{site.server_address[1]}"
    with tempfile.TemporaryDirectory(prefix="gr-history-") as directory:
        path = Path(directory) / "server.json"
        with (Path(directory) / "server.log").open("w") as log:
            server = subprocess.Popen(
                [BINARY, "server", "--listen", "127.0.0.1:0", "--connection", path,
                 "--auth-file", Path(directory) / "auth.json", "--shell", "/bin/sh"],
                stdout=log, stderr=log, env=dict(os.environ, DISPLAY="", WAYLAND_DISPLAY=""),
            )
        client = None
        try:
            for _ in range(100):
                if path.is_file():
                    break
                assert server.poll() is None
                time.sleep(0.05)
            client = Client(json.loads(path.read_text()), chromium_video=["h264", "hevc", "av1"])
            pane = client.topology["panes"][0]["id"]
            request = 0

            def rpc(method, **params):
                nonlocal request
                request += 1
                client.action("rpc", pane, request=request, method=method, params=params)
                client.until(lambda: any(m.get("request") == request for m in client.messages))
                response = next(m for m in client.messages if m.get("request") == request)
                assert response["type"] == "ack", response
                return response["result"]

            chromium = rpc("chromium.create", url="about:blank")["chromium"]
            client.until(lambda: (client.topology.get("chromiums") or [{}])[0]
                         .get("state", {}).get("chromiumId", -1) > 0)

            def command(action, **args):
                ticket = rpc("chromium.command", chromium=chromium, action=action, args=args)["ticket"]
                for _ in range(400):
                    reply = rpc("chromium.result", chromium=chromium, ticket=ticket)
                    if reply is not None:
                        return reply if "error" in reply else reply["result"]
                    time.sleep(0.025)
                raise AssertionError(f"{action} timed out")

            for name in ("alpha", "beta"):
                navigated = command("tab-navigate", text=f"{origin}/{name}")
                assert "error" not in navigated, navigated
                time.sleep(1)

            # History commits asynchronously; Chrome's providers read it back.
            matches = []
            for _ in range(40):
                result = command("history-query", text="127.0.0.1", limit=8)
                assert "error" not in result, result
                matches = result.get("matches")
                assert isinstance(matches, list), result
                if {f"{origin}/alpha", f"{origin}/beta"} <= {m["url"] for m in matches}:
                    break
                time.sleep(0.25)
            urls = {m["url"]: m["title"] for m in matches}
            assert urls.get(f"{origin}/alpha") == "Graffitty history alpha", matches
            assert urls.get(f"{origin}/beta") == "Graffitty history beta", matches

            titled = command("history-query", text="history bet", limit=8)["matches"]
            assert titled and titled[0]["url"] == f"{origin}/beta", titled
            assert command("history-query", text="  ", limit=8) == {"matches": []}
            limited = command("history-query", text="127.0.0.1", limit=21)
            assert "error" in limited, limited
            print("CHROMIUM_HISTORY_PASS", json.dumps(matches))
        finally:
            if client is not None:
                client.ws.close()
            server.terminate()
            server.wait(timeout=10)
            site.shutdown()


if __name__ == "__main__":
    main()
