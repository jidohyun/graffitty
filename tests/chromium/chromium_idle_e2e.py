#!/usr/bin/env python3
"""A hidden chromium remains responsive while other chromium panes are active."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from local_media_e2e import LocalClient, PrivateServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=float, default=90)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='graffitty-chromium-idle-') as directory:
        folder = Path(directory)
        page = folder / 'hidden.html'
        page.write_text('<title>Retained page</title><p id="retained">Keep this chromium alive</p>')
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('GRAFFITTY_', 'CODEX_'))}
        for kind in ['CONFIG', 'DATA', 'STATE', 'CACHE']:
            env['XDG_' + kind + '_HOME'] = str(folder / kind.lower())
        with PrivateServer(env, folder, '/bin/sh') as server:
            client = LocalClient(json.loads(server.descriptor.read_text()))
            owner = int(client.topology['panes'][0]['id'])

            def rpc(method, **params):
                return client.action('rpc', owner, method=method, params=params)

            def command(chromium, action, **params):
                ticket = rpc('chromium.command', chromium=chromium, action=action, args=params)['ticket']
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    result = rpc('chromium.result', chromium=chromium, ticket=ticket)
                    if result is not None:
                        assert 'error' not in result, result
                        return result['result']
                    time.sleep(.02)
                raise AssertionError('Hidden chromium command did not complete')

            def ready(chromium):
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if command(chromium, 'chrome-state').get('chromiumId', -1) > 0:
                        return
                    time.sleep(.05)
                raise AssertionError('Chromium did not become ready')

            try:
                hidden = rpc('chromium.open', path=str(page), new=True)['chromium']
                client.send({'type': 'subscribe', 'sessions': [owner, int(hidden[1:])]})
                ready(hidden)
                client.send({'type': 'subscribe', 'sessions': [owner]})
                active = [rpc('chromium.create', url='about:blank')['chromium'] for _ in range(2)]
                client.send({'type': 'subscribe', 'sessions': [owner, *[int(b[1:]) for b in active]]})
                for chromium in active:
                    ready(chromium)
                deadline = time.monotonic() + args.seconds
                count = 0
                while time.monotonic() < deadline:
                    for chromium in active:
                        command(chromium, 'cdp', method='Runtime.evaluate', params={
                            'expression': f'document.title = "Active {count}"', 'returnByValue': True})
                    count += 1
                    time.sleep(.25)
                started = time.monotonic()
                value = command(hidden, 'cdp', method='Runtime.evaluate', params={
                    'expression': '!!document.querySelector("#retained")', 'returnByValue': True})
                latency = time.monotonic() - started
                assert value['result']['value'] is True, value
                assert latency < 5, f'Hidden chromium took {latency:.2f}s to respond'
                print(f'PASS: hidden chromium retained its page for {args.seconds:g}s; response {latency:.3f}s')
            finally:
                client.close()


if __name__ == '__main__':
    main()
