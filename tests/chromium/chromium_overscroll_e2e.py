# /// script
# dependencies = ["websocket-client>=1.8,<2", "pillow>=11,<13"]
# ///
"""A page stretches past its edge only under trackpad or touchscreen fingers, as
far as Chrome allows.

Wheels and unphased scrolling stop at the edge. Trackpad momentum carries the page
but never adds stretch, so repeated flicks cannot push the page away.
"""
import base64
import io
import json
import math
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from PIL import Image
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client

# A red bar marks the top of the page; rows above it are stretch.
PAGE = ('<!doctype html><style>html,body{margin:0;background:#fff}#bar{height:40px;background:#f00}'
        '#rest{height:4000px}</style><div id=bar></div><div id=rest></div>')
FLICK = [-80 * math.exp(-i / 12) for i in range(40)]


def main():
    with tempfile.TemporaryDirectory(prefix='gr-overscroll-') as directory:
        root = Path(directory)
        with (root/'server.log').open('w') as log:
            server = subprocess.Popen([BINARY, 'server', '--listen', '127.0.0.1:0', '--connection', root/'server.json',
                '--auth-file', root/'auth.json', '--shell', '/bin/sh'], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 60
            while not (root/'server.json').exists():
                assert server.poll() is None, 'Private server failed'
                assert time.monotonic() < deadline, 'Private server startup timed out'
                time.sleep(.05)
            run(Client(json.loads((root/'server.json').read_text()), chromium_video=['hevc', 'h264']))
        finally:
            server.terminate()
            server.wait(timeout=30)


def run(owner):
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
        return command('cdp', method='Runtime.evaluate', params={'expression': expression, 'returnByValue': True})['result']['result'].get('value')

    def stretch():
        """Rows above the red bar, as a fraction of the viewport height."""
        shot = command('cdp', method='Page.captureScreenshot', params={'format': 'png'})
        image = Image.open(io.BytesIO(base64.b64decode(shot['result']['data']))).convert('RGB')
        for y in range(image.height):
            r, g, _ = image.getpixel((image.width // 2, y))
            if r > 200 and g < 80: return y / image.height
        return 1.0

    def wheel(dy, phase=None, momentum=None):
        params = {'type': 'mouseWheel', 'x': 400, 'y': 300, 'modifiers': 0, 'buttons': 0, 'deltaX': 0, 'deltaY': dy}
        if phase: params['phase'] = phase
        if momentum: params['momentumPhase'] = momentum
        call('chromium.input', chromium=handle, event={'method': 'Input.dispatchMouseEvent', 'params': params})
        pump(1 / 120)

    def settled():
        pump(1.5)
        return stretch()

    handle = call('chromium.create', url='about:blank')['chromium']
    bid = int(handle[1:])
    end = time.monotonic() + 60
    while not any(b['id'] == bid and b['state'].get('chromiumId', -1) > 0 for b in owner.topology.get('chromiums', [])):
        assert time.monotonic() < end, 'Chromium did not start'
        pump(.2)
    command('resize', width=800, height=600)
    # Screenshots need a presented surface.
    owner.action('subscribe', sessions=[bid])
    assert js('document.open();document.write(' + json.dumps(PAGE) + ');document.close();scrollTo(0,0);true')
    pump(1)
    assert stretch() == 0, 'The page starts at its top edge'

    for _ in range(30): wheel(-120)
    assert stretch() == 0 and settled() == 0, 'A wheel stops at the edge'
    for _ in range(40): wheel(-15)
    assert stretch() == 0 and settled() == 0, 'Unphased scrolling stops at the edge'

    wheel(-15, 'began')
    for _ in range(40): wheel(-15, 'changed')
    held = stretch()
    wheel(0, 'ended')
    elastic = sys.platform == 'darwin'
    assert (0 < held < .15) if elastic else held == 0, f'Trackpad fingers stretch the page with resistance: {held}'
    assert settled() == 0, 'The stretch springs back when the fingers lift'

    after_flicks = []
    for _ in range(5):
        wheel(-40, 'began')
        for _ in range(3): wheel(-40, 'changed')
        wheel(0, 'ended')
        wheel(FLICK[0], momentum='began')
        for dy in FLICK[1:30]: wheel(dy, momentum='changed')
        wheel(0, momentum='ended')
        after_flicks.append(stretch())
    assert max(after_flicks) < .05, f'Repeated flicks never accumulate stretch: {after_flicks}'
    assert settled() == 0, 'Flicks leave the page at its edge'

    # A touchscreen finger, as the client sends it: began and changed under
    # the finger, its glide as momentum "changed" with no "began", and the
    # gesture's single end as momentum "ended". It stretches like a trackpad.
    js('scrollTo(0,0);1')
    pump(.4)
    wheel(-15, 'began')
    for _ in range(40): wheel(-15, 'changed')
    held = stretch()
    assert (0 < held < .15) if elastic else held == 0, f'A finger stretches the page past its edge: {held}'
    for dy in FLICK[:20]: wheel(dy, momentum='changed')
    wheel(0, momentum='ended')
    assert settled() == 0, 'A finger\'s stretch and glide spring back to the edge'

    # Momentum keeps scrolling however late it follows the fingers' release.
    for gap in (0, .15):
        js('scrollTo(0,2000);1')
        pump(.4)
        wheel(-30, 'began')
        for _ in range(4): wheel(-30, 'changed')
        wheel(0, 'ended')
        pump(gap)
        wheel(-50, momentum='began')
        for _ in range(5): wheel(-50, momentum='changed')
        wheel(0, momentum='ended')
        pump(.4)
        moved = 2000 - js('scrollY')
        assert moved == 450, f'Momentum {gap * 1000:.0f} ms after release scrolls the page: moved {moved}'

    # A pane shown small renders the page at a lower scale; it still scrolls
    # by the page distance the client asked for.
    owner.action('chromium_stream', viewports={str(bid): 360})
    pump(1.5)
    js('scrollTo(0,0);1')
    pump(.4)
    for _ in range(10): wheel(50)
    pump(.6)
    assert js('scrollY') == 500, f'A wheel scrolls its full distance at reduced render scale: {js("scrollY")}'
    print('CHROMIUM_OVERSCROLL_PASS', flush=True)


if __name__ == '__main__':
    main()
