# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Stress real Chromium native scrolling with independent hardware-video clients.

Owns an isolated server/profile. Saves ordered video, frame timings, DOM progress,
and server diagnostics for comparison with physical-client captures.
"""
import argparse
import json
import os
from pathlib import Path
import select
import statistics
import subprocess
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client


class ScrollRun:
    def __init__(self, output):
        self.output = output
        self.clients = []
        self.timeline = []
        self.sequence = 0
        self.started = time.monotonic()
        self.streams = {}

    def pump(self, seconds=0.0, predicate=None):
        end = time.monotonic() + seconds
        while time.monotonic() < end and not (predicate and predicate()):
            ready, _, _ = select.select([c.ws.sock for c in self.clients], [], [], max(0, min(.01, end - time.monotonic())))
            for c in self.clients:
                if c.ws.sock not in ready:
                    continue
                previous = c.frames.get(self.bid, {}).get('frame')
                c.receive()
                frame = c.frames.get(self.bid, {})
                if frame.get('frame') != previous:
                    assert frame.get('format') in ('hevc', 'h264'), frame
                    index = self.clients.index(c)
                    self.timeline.append({'time': time.monotonic() - self.started, 'client': index, **frame})
                    fmt = frame.get('format')
                    if fmt in ('hevc', 'h264'):
                        key = (index, fmt)
                        if key not in self.streams:
                            self.streams[key] = (self.output / f'client-{index}.{fmt}').open('wb')
                        self.streams[key].write(c.payloads[self.bid])
                errors = [b for b in (c.topology or {}).get('chromiums', []) if b.get('state', {}).get('error')]
                assert not errors, errors
        if predicate:
            assert predicate(), 'Protocol response deadline exceeded'

    def send(self, method, **params):
        self.sequence += 1
        self.clients[0].action('rpc', self.pane, request=self.sequence, method=method, params=params)
        return self.sequence

    def rpc(self, method, **params):
        ticket = self.send(method, **params)
        owner = self.clients[0]
        self.pump(10, lambda: any(m.get('request') == ticket for m in owner.messages))
        response = next(m for m in owner.messages if m.get('request') == ticket)
        assert response['type'] == 'ack', response
        return response['result']

    def evaluate(self, expression):
        ticket = self.rpc('chromium.command', chromium=self.chromium, action='cdp', args={
            'method':'Runtime.evaluate', 'params':{'expression':expression, 'returnByValue':True}})['ticket']
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = self.rpc('chromium.result', chromium=self.chromium, ticket=ticket)
            if result is not None:
                assert 'error' not in result, result
                return result['result']['result'].get('value')
            self.pump(.01)
        raise AssertionError('CDP evaluation deadline exceeded')

    def run(self, descriptor, cycles, client_count, width=1280, height=720, layered=False):
        self.bid = -1
        owner = Client(descriptor, chromium_video=['hevc', 'h264'])
        self.clients.append(owner)
        self.pane = owner.topology['panes'][0]['id']
        self.chromium = self.rpc('chromium.create', url='about:blank')['chromium']
        self.bid = int(self.chromium[1:])
        self.pump(15, lambda: any(b['id'] == self.bid and b['state'].get('chromiumId', -1) > 0 for b in owner.topology.get('chromiums', [])))
        self.rpc('chromium.command', chromium=self.chromium, action='resize', args={'width':width, 'height':height})
        html = '''<!doctype html><meta charset=utf-8><style>
html,body{margin:0;background:#f08060}body{font:32px sans-serif;color:#222}
section{height:160px;padding:8px;box-sizing:border-box;background:linear-gradient(110deg,#20ffff,#ffcc40)}
section:nth-child(even){background:linear-gradient(20deg,#ff80ff,#80ff40)}
</style>''' + ''.join(f'<section>Scroll stability row {i}: 한글 日本語</section>' for i in range(80))
        if layered:
            html += '<style>section{will-change:transform;transform:translateZ(0)}.fixed{position:fixed;top:0;width:100%;height:65px;background:#ffffff80;backdrop-filter:blur(12px);z-index:2}.sticky{position:sticky;top:65px;background:#eeffff80;transform:translateZ(0)}</style><div class=fixed>Composited header</div>'
        assert self.evaluate('document.open();document.write('+json.dumps(html)+');document.close();true')
        owner.action('subscribe', sessions=[self.bid])
        for index in range(1, client_count):
            c = Client(descriptor, chromium_video=['h264'] if index == 2 else ['hevc', 'h264'])
            self.clients.append(c)
            c.action('subscribe', sessions=[self.bid])
        self.pump(10, lambda: all(self.bid in c.frames for c in self.clients))
        positions = []
        for mode in ('wheel', 'touchpad'):
            for cycle in range(cycles):
                for direction in (1, -1):
                    start = time.monotonic() - self.started
                    first_frame = len(self.timeline)
                    for step in range(121):
                        params = {'type':'mouseWheel','x':400,'y':300,'modifiers':0,'buttons':0,'deltaX':.001 if step%2 else -.001,'deltaY':direction*160}
                        if mode == 'touchpad':
                            # The fingers lift at the end of a trackpad sequence.
                            params['phase'] = 'began' if step == 0 else 'ended' if step == 120 else 'changed'
                            if step == 120: params.update(deltaX=0, deltaY=0)
                        elif step == 120:
                            break
                        self.send('chromium.input', chromium=self.chromium, event={'method':'Input.dispatchMouseEvent','params':params})
                        self.pump(1/120)
                    self.pump(.6)
                    value = self.evaluate('({y:scrollY,height:innerHeight,total:document.documentElement.scrollHeight})')
                    video_progress = []
                    for index in range(len(self.clients)):
                        frames = [frame for frame in self.timeline[first_frame:] if frame['client'] == index]
                        assert len(frames) >= 2, f'Client {index} video stalled during {mode} cycle {cycle}, direction {direction}: {frames}'
                        video_progress.append({'client':index, 'frames':len(frames),
                                               'first_frame_seconds':frames[0]['time'] - start})
                    positions.append({'mode':mode,'cycle':cycle,'direction':direction,
                                      'start_seconds':start, 'end_seconds':time.monotonic()-self.started,
                                      'video_progress':video_progress, **value})
                    assert abs(value['y'] - (value['total']-value['height'] if direction>0 else 0)) <= 1, value
                    print(json.dumps(positions[-1]), flush=True)
        failures = [m for c in self.clients for m in c.messages if m.get('type') == 'error']
        assert not failures, failures[-10:]
        assert self.evaluate('document.querySelectorAll("section").length') == 80
        self.output.joinpath('positions.json').write_text(json.dumps(positions, indent=2))
        self.rpc('chromium.close', chromium=self.chromium)
        self.pump(5, lambda: not owner.topology.get('chromiums'))
        print('CHROMIUM_SCROLL_STABILITY_PASS', flush=True)

    def close(self):
        self.output.joinpath('frames.json').write_text(json.dumps(self.timeline, indent=2))
        summaries = []
        for index in range(len(self.clients)):
            frames = [frame for frame in self.timeline if frame['client'] == index]
            gaps = [after['time'] - before['time'] for before, after in zip(frames, frames[1:])]
            summaries.append({'client':index, 'frames':len(frames),
                              'formats':sorted({frame['format'] for frame in frames}),
                              'median_interval_seconds':statistics.median(gaps) if gaps else None,
                              'max_interval_seconds_including_idle':max(gaps, default=None)})
        self.output.joinpath('summary.json').write_text(json.dumps(summaries, indent=2))
        for stream in self.streams.values(): stream.close()
        for client in self.clients: client.ws.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cycles', type=int, default=8)
    parser.add_argument('--clients', type=int, default=3)
    parser.add_argument('--width', type=int, default=1280)
    parser.add_argument('--height', type=int, default=720)
    parser.add_argument('--layered', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output.resolve()
    env = dict(os.environ, **{'XDG_'+kind+'_HOME':str(out/kind.lower()) for kind in ['STATE','CACHE','CONFIG','DATA']})
    runner = ScrollRun(out)
    descriptor = out/'server.json'
    with (out/'server.log').open('w') as log:
        server = subprocess.Popen([BINARY,'server','--listen','127.0.0.1:0','--connection',descriptor,'--auth-file',out/'auth.json','--shell','/bin/sh'],env=env,stdout=log,stderr=log)
        try:
            deadline = time.monotonic()+15
            while not descriptor.exists():
                assert server.poll() is None, 'Private server failed'
                assert time.monotonic()<deadline, 'Private server startup timed out'
                time.sleep(.025)
            runner.run(json.loads(descriptor.read_text()), args.cycles, args.clients, args.width, args.height, args.layered)
        finally:
            try:
                runner.close()
            finally:
                server.terminate()
                try: server.wait(timeout=10)
                except subprocess.TimeoutExpired: server.kill();server.wait(timeout=5)


if __name__ == '__main__':
    main()
