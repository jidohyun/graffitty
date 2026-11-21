#!/usr/bin/env python3
"""Owned Linux checkpoint fixture with a shareable IPC directory and crash cleanup."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import threading
import time


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--server', type=Path, required=True)
    p.add_argument('--host', type=Path, required=True)
    p.add_argument('--backend', choices=['chrome', 'alloy'], required=True)
    p.add_argument('--platform', choices=['wayland', 'x11'], required=True)
    p.add_argument('--site-port', type=int, default=0)
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / 'tmp').mkdir()
    (out / 'site').mkdir()
    for name in ('first', 'second'):
        (out / 'site' / (name + '.html')).write_text('<title>' + name + '</title><body>' + name)
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_): pass
    web = http.server.ThreadingHTTPServer(('127.0.0.1', args.site_port), functools.partial(Quiet, directory=str(out / 'site')))
    threading.Thread(target=web.serve_forever, daemon=True).start()
    env = dict(os.environ, TMPDIR=str(out / 'tmp'), GRAFFITTY_CHROMIUM_HOST=str(args.host),
        GRAFFITTY_CHROMIUM_OZONE_PLATFORM=args.platform, GRAFFITTY_SERVER__CHROMIUM__BACKEND=args.backend,
        GRAFFITTY_SERVER__CHECKPOINTS__ENABLED='false', SHELL='/bin/sh')
    for key in ('CONFIG', 'STATE', 'DATA'): env['XDG_' + key + '_HOME'] = str(out / key.lower())
    if args.platform == 'wayland': env.pop('DISPLAY', None)
    stopping = False
    def stop(*_):
        nonlocal stopping
        stopping = True
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT): signal.signal(sig, stop)
    with (out / 'server.log').open('wb') as log:
        server = subprocess.Popen([str(args.server), 'server', '--connection', str(out / 'connection.json'), '--auth-file', str(out / 'auth.json'), '--shell', '/bin/sh'], env=env, stdout=log, stderr=log)
        (out / 'fixture.json').write_text(json.dumps({'pid': server.pid, 'site_port': web.server_port}))
        def bridge():
            deadline = time.monotonic() + 30
            while not (out / 'connection.json').exists() and server.poll() is None and time.monotonic() < deadline: time.sleep(.05)
            if not (out / 'connection.json').exists(): return
            endpoint = json.loads((out / 'connection.json').read_text())['local']['url'].removeprefix('ipc://')
            def pump(source, destination):
                try:
                    while data := source.recv(65536): destination.sendall(data)
                except OSError: pass
                finally:
                    try: destination.shutdown(socket.SHUT_WR)
                    except OSError: pass
            def connection(client):
                with client, socket.socket(socket.AF_UNIX) as upstream:
                    upstream.connect(endpoint)
                    worker = threading.Thread(target=pump, args=(client, upstream), daemon=True)
                    worker.start(); pump(upstream, client); worker.join(timeout=5)
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(out / 'ipc.sock')); listener.listen(16); listener.settimeout(.2)
                (out / 'bridge-ready').touch()
                while server.poll() is None:
                    try: client, _ = listener.accept()
                    except socket.timeout: continue
                    threading.Thread(target=connection, args=(client,), daemon=True).start()
            (out / 'ipc.sock').unlink(missing_ok=True)
        threading.Thread(target=bridge, daemon=True).start()
        crashed = False
        groups = []
        try:
            deadline = time.monotonic() + 600
            while server.poll() is None and not stopping and not (out / 'stop').exists():
                if (out / 'kill').exists():
                    groups = list(Path(env['GODOT_RESOURCE_CGROUP_PARENT']).glob(f'godot-terminal-{server.pid}-*'))
                    server.kill()
                    crashed = True
                    break
                if time.monotonic() > deadline: raise TimeoutError('Fixture deadline exceeded')
                time.sleep(.1)
        finally:
            if server.poll() is None: server.terminate()
            try: server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait(timeout=10)
            if crashed:
                deadline = time.monotonic() + 20
                while any(g.exists() and 'populated 1' in (g / 'cgroup.events').read_text() for g in groups) and time.monotonic() < deadline: time.sleep(.1)
                for group in groups:
                    if group.exists(): group.rmdir()
            parent = Path(env['GODOT_RESOURCE_CGROUP_PARENT'])
            leaked = [p.name for p in parent.glob(f'godot-terminal-{server.pid}-*')]
            (out / 'cleanup.json').write_text(json.dumps({'exit': server.returncode, 'crashed': crashed, 'leaked_cgroups': leaked, 'crash_empty_groups_removed': len(groups)}))
            web.shutdown(); web.server_close()
            assert not leaked

if __name__ == '__main__': main()
