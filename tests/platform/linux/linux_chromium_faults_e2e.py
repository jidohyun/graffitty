#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2", "nvidia-ml-py>=13,<14"]
# ///
"""Owned Linux process pause, server-crash and private compositor recovery tests.

SIGSTOP is a scheduling outage, not machine suspend. Server recovery starts a fresh authenticated session and browser; it does not
claim automatic workspace restoration.
"""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[3] / d) for d in ("tests/chromium", "tests/support")]
from headless_remote_e2e import Client
from chromium_video_e2e import evaluate
from linux_chromium_lifecycle_e2e import Fixture, decode_color
from linux_chromium_stress_e2e import eventually


def alive(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0] != 'Z'
    except FileNotFoundError:
        return False


def state(f, sid):
    return next((v['state'] for v in f.owner.topology.get('chromiums', []) if v['id'] == sid), {})


def settle(f, sid):
    f.owner.until(lambda: state(f, sid).get('chromiumId', -1) > 0 and not state(f, sid).get('error'))
    return state(f, sid)['pid']


def decoded(f, sid, name):
    stream = f.stream(sid)
    eventually(lambda: len(stream.sample) >= 60, 'Recovered stream did not arrive')
    stream.reset_sample()
    eventually(lambda: len(stream.sample) >= 60, 'Settled sample missing')
    result = decode_color(stream, f.out, name, 0)
    stream.close()
    f.clients.remove(stream)
    return result


@contextmanager
def compositor(args):
    if args.case != 'compositor':
        yield None
        return
    assert args.platform == 'wayland'
    with tempfile.TemporaryDirectory(prefix='gft-weston-') as directory:
        runtime = Path(directory)
        os.chmod(runtime, 0o700)
        previous = {key: os.environ.get(key) for key in ('XDG_RUNTIME_DIR', 'WAYLAND_DISPLAY')}
        os.environ.update(XDG_RUNTIME_DIR=str(runtime), WAYLAND_DISPLAY='validation')
        log = (args.output.parent / (args.output.name + '-weston.log')).open('wb')
        env = dict(os.environ)
        env.pop('WAYLAND_DISPLAY', None)
        if Path('/usr/share/glvnd/egl_vendor.d/10_nvidia.json').exists():
            env['__EGL_VENDOR_LIBRARY_FILENAMES'] = '/usr/share/glvnd/egl_vendor.d/10_nvidia.json'
        children = []
        def launch():
            child = subprocess.Popen(['weston', '--backend=headless', '--renderer=gl', '--socket=validation',
                '--no-config', '--idle-time=0', '--width=1000', '--height=700'], env=env, stdout=log, stderr=log)
            children.append(child)
            eventually(lambda: child.poll() is not None or (runtime / 'validation').exists(), 'Private Weston did not start')
            assert child.poll() is None, 'Private Weston failed; see its log'
            return child
        try:
            first = launch()
            yield (first, launch)
        finally:
            for child in children:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=10)
            log.close()
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


def run(args):
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with compositor(args) as weston, Fixture(args) as f:
        page, sid, host = f.page('faults')
        checks = {}
        if weston:
            first, launch = weston
            checks['initial_decode'] = decoded(f, sid, 'initial')
            first.terminate()
            first.wait(timeout=10)
            f.owner.until(lambda: state(f, sid).get('crashed') is True)
            assert state(f, sid).get('restartable') is True, state(f, sid)
            launch()
            f.rpc('chromium.restart', chromium=page)
            replacement = settle(f, sid)
            assert replacement != host
            assert evaluate(f.rpc, page, "let n=0;function tick(){document.body.style.background='rgb('+(170+n++%70)+',0,0)';requestAnimationFrame(tick)}tick();true")
            checks['compositor_restart_decode'] = decoded(f, sid, 'compositor-recovered')
        else:
            existing = f.stream(sid)
            eventually(lambda: len(existing.sample) >= 60, 'Original stream did not start')
            for kind, pid in [('browser', host), ('server', f.server.pid)]:
                os.kill(pid, signal.SIGSTOP)
                try:
                    time.sleep(10)
                finally:
                    os.kill(pid, signal.SIGCONT)
                assert evaluate(f.rpc, page, 'window.testIdentity') == 'faults'
                existing.reset_sample()
                eventually(lambda: len(existing.sample) >= 60, 'Existing viewer did not resume')
                assert existing.error is None, existing.error
                checks[kind + '_pause_resume'] = decode_color(existing, f.out, kind + '-resumed', 0)
            # Capture the explicit recovery URL, then kill only the owned server.
            old_server = f.server.pid
            old_groups = list(Path(f.env['GODOT_RESOURCE_CGROUP_PARENT']).glob(f'godot-terminal-{old_server}-*'))
            saved = f.rpc('session.capture')
            f.save('before-crash.json', saved)
            f.server.kill()
            f.server.wait(timeout=10)
            eventually(lambda: existing.error, 'Existing viewer did not detect server disconnect')
            existing.close()
            f.clients.remove(existing)
            f.owner.ws.close()
            f.owner = None
            eventually(lambda: not alive(host), 'Browser survived its killed server', timeout=30)
            for group in old_groups:
                eventually(lambda: 'populated 1' not in (group / 'cgroup.events').read_text(), 'Killed server left running descendants')
            # SIGKILL cannot execute Rust destructors. The harness removes only
            # its recorded, empty groups; this is not counted as graceful cleanup.
            for group in old_groups:
                group.rmdir()
            f.save('crash-cleanup.json', {'server_exit': f.server.returncode, 'browser_gone': True, 'empty_groups_removed_by_harness': len(old_groups)})
            (f.out / 'connection.json').unlink(missing_ok=True)
            f.server = subprocess.Popen(f.server.args, env=f.env, stdout=f.log, stderr=f.log)
            eventually(lambda: (f.out / 'connection.json').exists(), 'Replacement server did not publish a descriptor')
            f.descriptor = json.loads((f.out / 'connection.json').read_text())
            f.owner = Client(f.descriptor)
            f.pane = f.owner.topology['panes'][0]['id']
            page, sid, new_host = f.page('after-server-crash')
            assert new_host != host and f.server.pid != old_server
            checks['server_restart_fresh_auth_and_browser'] = decoded(f, sid, 'server-recovered')
        f.save('results.json', {'status': 'pass', 'checks': checks})
        print('PASS faults', json.dumps(checks), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--backend', choices=['chrome', 'alloy'], required=True)
    parser.add_argument('--platform', choices=['wayland', 'x11'], required=True)
    parser.add_argument('--case', choices=['recovery', 'compositor'], required=True)
    run(parser.parse_args())
