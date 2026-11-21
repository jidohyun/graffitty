#!/usr/bin/env python3
"""Owned macOS/Windows Chromium test server; requires psutil in the Python runtime."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import threading
import psutil


def identity(process):
    return {'pid': process.pid, 'created': process.create_time()}


def same(value):
    try:
        p = psutil.Process(value['pid'])
        return p if p.create_time() == value['created'] and p.status() != psutil.STATUS_ZOMBIE else None
    except psutil.NoSuchProcess:
        return None


def kill_owned(directory, host_pid, kind):
    state = json.loads((directory / 'fixture.json').read_text())
    owner = same(state['identity'])
    assert owner is not None, 'Fixture owner no longer exists'
    host = psutil.Process(host_pid)
    executable = host.exe()
    # macOS Chromium runs from a hard-linked code-signing clone of its bundle, so the
    # kernel can report either path for the same file. Compare file identity.
    assert os.path.samefile(executable, state['host']), f'Unexpected browser executable {executable!r}, expected {state["host"]!r}'
    assert owner in host.parents(), 'Browser is not owned by this fixture'
    targets = [host] if kind == 'host' else [p for p in host.children(recursive=True)
        if ('--type=gpu-process' if kind == 'gpu' else '--type=renderer') in p.cmdline()
        and '--extension-process' not in p.cmdline()]
    assert targets, 'No owned target found'
    identities = [identity(p) for p in targets]
    for process in targets:
        process.kill()
    print(json.dumps({'kind': kind, 'targets': identities}))


def sample_owned(directory):
    state = json.loads((directory / 'fixture.json').read_text())
    owner = same(state['identity'])
    assert owner is not None, 'Fixture owner no longer exists'
    descendants = []
    for child in owner.children(recursive=True):
        try:
            owned = identity(child)
            try:
                arguments = child.cmdline()
            except psutil.AccessDenied:
                if sys.platform != 'darwin': raise
                value = subprocess.run(['ps', '-o', 'command=', '-p', str(child.pid)],
                    capture_output=True, text=True, timeout=5)
                if not same(owned): continue
                assert value.returncode == 0 and value.stdout.strip(), value.stderr
                arguments = value.stdout.split()
                owned['command_provider'] = 'ps'
            owned['chromium_type'] = next((a.removeprefix('--type=') for a in arguments if a.startswith('--type=')), '')
            provider = 'psutil'
            try:
                rss = child.memory_info().rss
            except psutil.AccessDenied:
                # macOS can deny task info during renderer teardown. Check the
                # native process table, retaining identity checks across it.
                if sys.platform != 'darwin': raise
                value = subprocess.run(['ps', '-o', 'rss=', '-p', str(child.pid)],
                    capture_output=True, text=True, timeout=5)
                if not same(owned): continue
                assert value.returncode == 0 and value.stdout.strip().isdigit(), value.stderr
                rss = int(value.stdout.strip()) * 1024
                provider = 'ps'
            if same(owned): descendants.append({**owned, 'rss': rss, 'provider': provider})
        except psutil.NoSuchProcess:
            pass
    print(json.dumps({'server_rss': owner.memory_info().rss,
        'server_handles': owner.num_handles() if os.name == 'nt' else owner.num_fds(),
        'descendant_rss': sum(p['rss'] for p in descendants), 'descendants': descendants}))


def serve(config):
    out = Path(config['directory']); out.mkdir(parents=True, exist_ok=False)
    origin = None
    if config.get('test_origin'):
        class Page(BaseHTTPRequestHandler):
            def do_GET(self):
                body = b'<!doctype html><title>Isolation fixture</title><body>Owned test origin</body>'
                if config['test_origin'] == 'checkpoint':
                    name = 'second' if self.path.split('?', 1)[0] == '/second.html' else 'first'
                    body = ('<!doctype html><title>' + name + '</title><body>' + name).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)
            def log_message(self, *_): pass
        origin = ThreadingHTTPServer(('127.0.0.1', config.get('origin_port', 0)), Page)
        config['origin_url'] = 'http://127.0.0.1:' + str(origin.server_port) + '/'
        threading.Thread(target=origin.serve_forever, daemon=True).start()
    env = {k: v for k, v in os.environ.items() if not k.startswith('GRAFFITTY_')}
    env.update(GRAFFITTY_CHROMIUM_HOST=config['host'], GRAFFITTY_SERVER__CHROMIUM__BACKEND=config['backend'], RUST_LOG='graffitty_video=debug')
    if config.get('test_origin') == 'checkpoint': env['GRAFFITTY_SERVER__CHECKPOINTS__ENABLED'] = 'false'
    if config.get('ozone'):
        env['GRAFFITTY_CHROMIUM_OZONE_PLATFORM'] = config['ozone']
        if config['ozone'] == 'wayland': env.pop('DISPLAY', None)
    for kind in ('CONFIG', 'STATE', 'DATA', 'CACHE'): env['XDG_' + kind + '_HOME'] = str(out / kind.lower())
    stopping = False
    def stop(*_):
        nonlocal stopping
        stopping = True
    for sig in (signal.SIGTERM, signal.SIGINT): signal.signal(sig, stop)
    owned = {}
    with (out / 'server.log').open('wb') as log:
        process = subprocess.Popen([config['server'], 'server', '--listen', config['listen'],
            '--connection', str(out / 'connection.json'), '--auth-file', str(out / 'auth.json'),
            '--shell', config['shell']], env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        owner = psutil.Process(process.pid)
        def collect():
            try:
                for p in owner.children(recursive=True):
                    try: owned[(p.pid, p.create_time())] = identity(p)
                    except psutil.NoSuchProcess: pass
            except psutil.NoSuchProcess: pass
        paths = [Path(config['server']), Path(config['host'])]
        if os.name == 'nt': paths.append(Path(config['host']).with_suffix('.dll'))
        (out / 'fixture.json').write_text(json.dumps({'identity': identity(owner), **config,
            'sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}}, indent=2))
        deadline = time.monotonic() + 1800
        crashed = False
        try:
            while process.poll() is None and not stopping and not (out / 'stop').exists():
                collect()
                if (out / 'crash').exists():
                    live = []
                    for value in owned.values():
                        child = same(value)
                        if child:
                            try: live.append({**value, 'exe': child.exe()})
                            except psutil.NoSuchProcess: pass
                    assert any(Path(p['exe']).resolve() == Path(config['host']).resolve() for p in live), 'Crash must interrupt a live browser'
                    (out / 'crash.json').write_text(json.dumps({'owner': identity(owner), 'descendants': live}, indent=2))
                    crashed = True
                    process.kill()
                    process.wait(timeout=15)
                    break
                if time.monotonic() > deadline: raise TimeoutError('Fixture lifetime exceeded')
                time.sleep(.2)
        finally:
            collect()
            if process.poll() is None:
                if os.name == 'nt':
                    subprocess.run(['taskkill.exe', '/PID', str(process.pid), '/T', '/F'], capture_output=True, timeout=15)
                else: process.terminate()
                try: process.wait(timeout=15)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
            deadline = time.monotonic() + 15
            while any(same(v) for v in owned.values()) and time.monotonic() < deadline: time.sleep(.1)
            leaks = [v for v in owned.values() if same(v)]
            # Replacement fixtures may reuse this origin as soon as cleanup is
            # published. Release its listening socket before publishing it.
            if origin: origin.shutdown(); origin.server_close()
            (out / 'cleanup.json').write_text(json.dumps({'exit': process.returncode,
                'crashed': crashed, 'forced_server_shutdown': os.name == 'nt' and not crashed, 'leaked_processes': leaks}, indent=2))
            # Record the failure before removing any surviving owned processes.
            for value in leaks:
                p = same(value)
                if p: p.kill()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    serve_parser = sub.add_parser('serve'); serve_parser.add_argument('--config', type=Path, required=True)
    kill_parser = sub.add_parser('kill'); kill_parser.add_argument('--directory', type=Path, required=True)
    kill_parser.add_argument('--host-pid', type=int, required=True); kill_parser.add_argument('--kind', choices=['host','renderer','gpu'], required=True)
    sample_parser = sub.add_parser('sample'); sample_parser.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    if args.action == 'serve': serve(json.loads(args.config.read_text(encoding='utf-8-sig')))
    elif args.action == 'kill': kill_owned(args.directory, args.host_pid, args.kind)
    else: sample_owned(args.directory)

if __name__ == '__main__': main()
