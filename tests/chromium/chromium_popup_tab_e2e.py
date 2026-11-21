# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Check that links and scripts open new windows as adjacent Chromium tabs.

- Keep each new page in the opener's pane, with no extra pane even briefly.
- Select the new tab and present its page.
- Preserve the opener for scripted popups.
"""
import json
import subprocess
import sys
import tempfile
import threading
import time
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client


class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    with tempfile.TemporaryDirectory(prefix='gr-popup-') as directory:
        root = Path(directory)
        site = root / 'site'
        site.mkdir()
        (site / 'index.html').write_text("<title>index</title><a id=blank target=_blank href='target.html?blank'>blank</a>")
        (site / 'target.html').write_text('<title>target</title>target')
        web = ThreadingHTTPServer(('127.0.0.1', 0), partial(Quiet, directory=str(site)))
        threading.Thread(target=web.serve_forever, daemon=True).start()
        base = f'http://127.0.0.1:{web.server_address[1]}/'
        with (root/'server.log').open('w') as log:
            server = subprocess.Popen([BINARY, 'server', '--listen', '127.0.0.1:0', '--connection', root/'server.json',
                '--auth-file', root/'auth.json', '--shell', '/bin/sh'], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 60
            while not (root/'server.json').exists():
                assert server.poll() is None, 'Private server failed'
                assert time.monotonic() < deadline, 'Private server startup timed out'
                time.sleep(.05)
            run(Client(json.loads((root/'server.json').read_text()), chromium_video=['hevc', 'h264']), base)
        finally:
            server.terminate()
            server.wait(timeout=30)
            web.shutdown()


def run(owner, base):
    owner.ws.settimeout(.05)
    pane = owner.topology['panes'][0]['id']
    sequence = 0

    def pump(seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                owner.receive()
            except Exception as error:
                if 'timed out' not in str(error): raise

    def call(method, **params):
        nonlocal sequence
        sequence += 1
        mine = sequence
        owner.action('rpc', pane, request=mine, method=method, params=params)
        end = time.monotonic() + 30
        while time.monotonic() < end:
            pump(.005)
            found = next((m for m in owner.messages if m.get('request') == mine), None)
            if found:
                owner.messages.remove(found)
                assert found['type'] == 'ack', found
                return found['result']
        raise AssertionError(f'{method} reply deadline exceeded')

    def command(action, **args):
        ticket = call('chromium.command', chromium=handle, action=action, args=args)['ticket']
        end = time.monotonic() + 20
        while time.monotonic() < end:
            result = call('chromium.result', chromium=handle, ticket=ticket)
            if result is not None:
                assert 'error' not in result, result
                return result
            pump(.005)
        raise AssertionError(f'{action} result deadline exceeded')

    def js(expression):
        return command('cdp', method='Runtime.evaluate', params={'expression': expression, 'returnByValue': True,
                                                                  'userGesture': True})['result']['result'].get('value')

    handle = call('chromium.create', url=base + 'index.html')['chromium']
    bid = int(handle[1:])
    def state():
        return next((b['state'] for b in owner.topology.get('chromiums', []) if b['id'] == bid), {})
    end = time.monotonic() + 60
    while state().get('chromiumId', -1) <= 0:
        assert time.monotonic() < end, 'Chromium did not start'
        pump(.2)
    owner.action('subscribe', sessions=[bid])
    pump(1)
    cases = [
        ('a target=_blank link', "document.getElementById('blank').click()", '?blank', False),
        ('window.open(url)', f"window.open('{base}target.html?open')", '?open', True),
        ("window.open(url, '_blank')", f"window.open('{base}target.html?named', '_blank')", '?named', True),
        ('a window.open popup', f"window.open('{base}target.html?popup', '_blank', 'width=420,height=320')", '?popup', True),
    ]
    for count, (name, expression, marker, keeps_opener) in enumerate(cases, start=2):
        js(expression + ';1')
        panes = 0
        end = time.monotonic() + 3
        while time.monotonic() < end:
            pump(.02)
            panes = max(panes, len(owner.topology.get('chromiums', [])))
        tabs = state().get('tabs', [])
        selected = next((tab for tab in tabs if tab.get('selected')), {})
        assert panes == 1, f'{name} opens no other pane, even briefly: saw {panes}'
        assert len(tabs) == count and selected.get('url', '').endswith(marker), f'{name} opens a selected tab: {tabs}'
        assert state().get('capturedPageId') == state().get('chromiumId'), f'{name} shows the new tab in the pane'
        opener = js("window.opener ? window.opener.location.pathname : ''")
        assert bool(opener) == keeps_opener, f'{name} keeps the opener only when the page asked for one: {opener!r}'
    print('CHROMIUM_POPUP_TAB_PASS', flush=True)


if __name__ == '__main__':
    main()
