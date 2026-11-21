#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Stress Linux, macOS, and Windows streaming with isolated GPU fixtures.

- Exercise the local-capability protocol.
- On Windows, use an interactive scheduled task and an SSH loopback tunnel.
- Install FFmpeg on the test-driver machine.

The test keeps existing GPU devices running.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import sys
import time
import traceback
from urllib.parse import urlsplit

from test_desktop_chromium import Matrix, quote
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/platform/linux", "tests/support")]
from headless_remote_e2e import Client
from chromium_video_e2e import evaluate
from chromium_slow_link_e2e import PAGE
from linux_chromium_stress_e2e import Stream, eventually


@contextmanager
def connection(matrix, out):
    descriptor = json.loads((out / 'connection.json').read_text())
    tunnel = None
    try:
        if matrix.args.platform == 'windows':
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0)); port = listener.getsockname()[1]
            remote_port = urlsplit(descriptor['url']).port
            log = (out / 'tunnel.log').open('wb')
            tunnel = subprocess.Popen(['ssh', '-N', '-o', 'ExitOnForwardFailure=yes',
                '-o', 'ConnectTimeout=15', '-L', f'127.0.0.1:{port}:127.0.0.1:{remote_port}',
                matrix.args.ssh], stdout=log, stderr=log)
            def ready():
                assert tunnel.poll() is None, 'SSH tunnel exited'
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.2): return True
                except OSError: return False
            eventually(ready, 'SSH loopback tunnel did not start', timeout=20)
            descriptor['url'] = f'ws://127.0.0.1:{port}'
        yield descriptor
    finally:
        if tunnel:
            tunnel.terminate(); tunnel.wait(timeout=15); log.close()


def sample(matrix, out):
    if matrix.args.platform == 'windows':
        text = matrix.ps('& ' + quote(matrix.args.python) + ' ' + quote(matrix.remote + '/fixture.py')
            + ' sample --directory ' + quote(matrix.remote + '/' + out.name)
            + "\nif ($LASTEXITCODE -ne 0) {throw 'Resource sample failed'}")
    else:
        text = subprocess.check_output([sys.executable, str(matrix.helper), 'sample',
            '--directory', str(out / 'owner')], text=True, timeout=15)
    return json.loads(text)


def finish_soak(points, seconds, decode, save):
    """Keep original limits, but retain final video evidence even on growth failure."""
    assert len(points) >= 12
    growth, failures = {}, []
    for key, limit in [('server_rss', 128*1024**2), ('descendant_rss', 256*1024**2), ('server_handles', 32)]:
        early = statistics.median(p[key] for p in points[3:6])
        late = statistics.median(p[key] for p in points[-3:])
        growth[key] = {'early': early, 'late': late, 'growth': late-early, 'limit': limit}
        if late-early > limit:
            failures.append(key)
    result = {'seconds': seconds, 'samples': len(points), 'growth': growth, 'resource_failures': failures}
    save('bounded_soak', result)
    try:
        result['decode'] = decode()
    except Exception as error:
        result['decode_error'] = str(error)
        raise
    finally:
        save('bounded_soak', result)
    assert not failures, growth


def exercise(matrix, out, descriptor):
    owner = Client(descriptor)
    clients, results = [], {}
    pane, request = owner.topology['panes'][0]['id'], 0
    def rpc(method, **params):
        nonlocal request
        request += 1
        owner.action('rpc', pane, request=request, method=method, params=params)
        owner.until(lambda: any(v.get('request') == request for v in owner.messages))
        reply = next(v for v in owner.messages if v.get('request') == request)
        assert reply['type'] == 'ack', reply
        owner.messages.clear()
        return reply['result']
    def stream(**kwargs):
        s = Stream(descriptor, sid, **kwargs); clients.append(s); return s
    def close(s):
        s.close(); clients.remove(s)
    def save(phase, result):
        results[phase] = result
        (out / 'phases.json').write_text(json.dumps(results, indent=2))
        print(out.name, phase, 'complete', flush=True)
    def measure(seconds=8):
        start = time.monotonic(); time.sleep(seconds); return fast.stats(start)
    def flowing(value, baseline):
        if value['fps'] < max(10, baseline * .7) or value['longest_gap_s'] >= 2:
            results.setdefault('throughput_failures', []).append({'baseline_fps':baseline,'actual':value})
            (out/'phases.json').write_text(json.dumps(results,indent=2))
            print(out.name, 'throughput check failed', value['fps'], flush=True)
    def decode(s, name):
        s.reset_sample()
        eventually(lambda: len(s.sample) >= 60, name + ' lacks fresh frames', timeout=30)
        return s.decode(out, name)
    try:
        page = rpc('chromium.create', url='about:blank')['chromium']; sid = int(page[1:])
        owner.until(lambda: any(b['id'] == sid and b['state'].get('chromiumId', -1) > 0
            for b in owner.topology.get('chromiums', [])))
        rpc('chromium.command', chromium=page, action='resize', args={'width':800,'height':600})
        assert evaluate(rpc,page,'document.open();document.write('+json.dumps(PAGE)+');document.close();window.stressIdentity="retained";true')
        fast = stream()
        eventually(lambda: fast.latest, 'Hardware stream did not start')
        initial = decode(fast, 'initial')
        baseline = measure(); assert baseline['fps'] >= 20, baseline
        capture_scale = (baseline['latest']['source_width']/800, baseline['latest']['source_height']/600)
        save('baseline', {'video':baseline,'decode':initial})
        low = stream(codecs=['h264'], quality={'max_height':360,'fps':15,'bitrate_kbps':1500})
        slow = stream(ack_delay=.35, rate_kb=250)
        eventually(lambda: slow.latest and low.latest, 'Mixed viewers did not start')
        mixed = measure(12); flowing(mixed, baseline['fps'])
        assert low.latest['format']=='h264' and low.latest['height']<=360, low.latest
        save('mixed_slow', {'healthy':mixed, 'low':decode(low,'low'), 'slow':decode(slow,'slow')})
        close(low); close(slow)
        stalled = stream(paused=True)
        value = measure(); flowing(value, baseline['fps'])
        stalled.paused.clear()
        save('stalled_resume', {'healthy':value,'resumed':decode(stalled,'resumed')})
        close(stalled)
        peers, attempts = [], []
        for index in range(matrix.args.pressure_viewers):
            peer = stream(ack_delay=.65, allow_unavailable=True); peers.append(peer)
            eventually(lambda: peer.latest or peer.unavailable, 'Pressure viewer got neither video nor error')
            time.sleep(1)
            attempts.append({'index':index,'frame':peer.latest,'error':peer.unavailable})
            if peer.unavailable: break
        pressure = measure(); flowing(pressure, baseline['fps'])
        for peer in peers: close(peer)
        newcomer = stream(quality={'max_height':360,'fps':15,'bitrate_kbps':1500})
        save('bounded_pressure', {'attempts':attempts,'exhausted':any(p['error'] for p in attempts),
            'healthy':pressure,'released_capacity_decode':decode(newcomer,'after-pressure')})
        close(newcomer)
        for index in range(12):
            late = stream(codecs=['h264'] if index%2 else ['hevc','h264'],ack_delay=.2)
            decode(late, f'churn-{index}'); close(late)
        save('churn', {'fresh_connections':12,'healthy':measure()})
        sizes = [(960,540),(800,600)] * 4
        for width,height in sizes:
            old = fast.latest['epoch']
            rpc('chromium.command',chromium=page,action='resize',args={'width':width,'height':height})
            expected = tuple(int(size*scale)//2*2 for size,scale in zip((width,height),capture_scale))
            eventually(lambda: fast.latest['epoch'] != old and (fast.latest['width'],fast.latest['height'])==expected,
                'Resize did not replace encoder generation')
        save('resize', {'css_sizes':sizes,'capture_scale':capture_scale,'decode':decode(fast,'after-resize')})
        points=[]; start=time.monotonic()
        while time.monotonic()-start < matrix.args.seconds:
            value=measure(5); flowing(value,baseline['fps'])
            assert evaluate(rpc,page,'window.stressIdentity')=='retained'
            point={'elapsed':time.monotonic()-start,**sample(matrix,out),'video':value}
            points.append(point)
            (out/'samples.json').write_text(json.dumps(points,indent=2))
        finish_soak(points, time.monotonic()-start, lambda: decode(fast, 'final'), save)
        assert not results.get('throughput_failures'), results['throughput_failures']
    finally:
        for s in clients: s.close()
        owner.ws.close()


def main(exercise_fn=exercise, description=__doc__, test_origin=False):
    os.umask(0o077)
    p=argparse.ArgumentParser(description=description)
    p.add_argument('--platform',choices=['linux','macos','windows'],required=True)
    for name in ['server','host','shell']: p.add_argument('--'+name,required=True)
    p.add_argument('--ozone',choices=['wayland','x11'])
    for name in ['ssh','remote-dir','python','principal-task']: p.add_argument('--'+name)
    p.add_argument('--backend',action='append',choices=['chrome','alloy'])
    p.add_argument('--seconds',type=int,default=120)
    p.add_argument('--pressure-viewers',type=int,default=6)
    p.add_argument('--artifacts',type=Path,required=True)
    args=p.parse_args()
    if args.platform!='windows' and sys.platform!={'macos':'darwin','linux':'linux'}[args.platform]:p.error('Unix fixtures must run on the requested OS')
    if args.seconds<90 or not 1<=args.pressure_viewers<=12: p.error('Use >=90 seconds and 1..12 pressure viewers')
    if args.platform=='linux' and not args.ozone: p.error('Linux requires --ozone')
    if args.platform=='windows' and not all((args.ssh,args.remote_dir,args.python,args.principal_task)): p.error('Windows requires SSH, remote directory, Python and interactive principal task')
    args.listen='127.0.0.1:0';args.url=None;args.adb='unused';args.backend=args.backend or ['chrome','alloy']
    args.test_origin = test_origin
    matrix=Matrix(args)
    sources={Path(__file__).resolve(),Path(sys.argv[0]).resolve(),matrix.helper,Path(__file__).with_name('test_desktop_chromium.py')}
    (matrix.out/'source-hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},indent=2))
    results={}
    for backend in args.backend:
        name='-'.join(filter(None,[args.platform,args.ozone,backend]));out=matrix.out/name;out.mkdir()
        try:
            with matrix.fixture(out,backend):
                with connection(matrix,out) as descriptor: exercise_fn(matrix,out,descriptor)
            results[name]={'status':'pass'}
        except Exception as error:
            (out/'failure.txt').write_text(traceback.format_exc());results[name]={'status':'fail','reason':str(error)}
        (matrix.out/'results.json').write_text(json.dumps(results,indent=2))
        print(name,results[name],flush=True)
    return int(any(v['status']!='pass' for v in results.values()))

if __name__=='__main__': raise SystemExit(main())
