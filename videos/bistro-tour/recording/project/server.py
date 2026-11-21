"""Table orders for the bistro: a small JSON API and the menu page."""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import orders
from reservations import Book

ROOT = Path(__file__).parent
PORT = int(os.environ.get("PORT", "8090"))
TICKETS = ROOT / "logs/tickets.log"
OPEN = []
BOOK = Book()
COLORS = {"GET": "\033[36m", "POST": "\033[35m"}


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body, kind="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        self.status = status

    def do_GET(self):
        started = time.perf_counter()
        path = self.path.split("?")[0]
        if path == "/":
            self.reply(200, (ROOT / "static/index.html").read_bytes(), "text/html; charset=utf-8")
        elif path == "/menu":
            self.reply(200, list(orders.MENU.values()))
        elif path == "/orders":
            self.reply(200, OPEN[-12:])
        elif path == "/reservations":
            self.reply(200, BOOK.tonight())
        else:
            self.reply(404, {"error": "not found"})
        self.log(started)

    def do_POST(self):
        started = time.perf_counter()
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or "{}")
        try:
            if self.path == "/orders":
                order = orders.create_order(body.get("table"), body.get("items", []))
                OPEN.append(order)
                with TICKETS.open("a") as log:
                    log.write(orders.ticket(order, time.strftime("%H:%M")))
                self.reply(201, order)
            elif self.path == "/reservations":
                self.reply(201, BOOK.reserve(body.get("name"), body.get("party"), body.get("slot")))
            else:
                self.reply(404, {"error": "not found"})
        except orders.OrderError as error:
            self.reply(422, {"error": str(error)})
        self.log(started)

    def log(self, started):
        # Dashboards refresh every second; keep the log to real customer traffic.
        if "watch=1" in self.path:
            return
        ms = (time.perf_counter() - started) * 1000
        color = "\033[32m" if self.status < 400 else "\033[31m"
        print(f"{time.strftime('%H:%M:%S')}  {COLORS[self.command]}{self.command:<5}\033[0m"
              f"{self.path:<16}{color}{self.status}\033[0m  {ms:4.1f} ms", flush=True)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    TICKETS.parent.mkdir(exist_ok=True)
    print(f"bistro-orders listening on http://localhost:{PORT}", flush=True)
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
