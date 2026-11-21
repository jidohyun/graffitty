#!/usr/bin/env python3
"""Real Godot checkpoint save/crash/restore against an owned Linux server via SSH IPC.

The frontend runs on the invoking machine; this does not claim a native Linux UI.
The remote checkout must be shared with the SSH host at --shared-root.
"""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('ssh', 'enter', 'remote-root', 'shared-root', 'server', 'host'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--godot', default=shutil.which('godot'))
    p.add_argument('--cli', type=Path, default=ROOT / 'dist/bin/gft')
    p.add_argument('--backend', choices=['chrome', 'alloy'], required=True)
    p.add_argument('--platform', choices=['wayland', 'x11'], required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    prefix = PurePosixPath(args.remote_root)
    shared = PurePosixPath(args.shared_root)
    run = uuid.uuid4().hex[:8]
    helper = prefix / '.cache' / ('checkpoint-owner-' + run + '.py')
    def ssh(words, **kwargs):
        return subprocess.run(['ssh', '-o', 'ConnectTimeout=15', args.ssh, shlex.join([str(w) for w in words])], check=True, timeout=30, **kwargs)
    def remote_read(path):
        return ssh(['cat', path], capture_output=True, text=True).stdout
    ssh(['python3', '-c', 'import pathlib,sys,os;os.umask(0o077);pathlib.Path(sys.argv[1]).write_bytes(sys.stdin.buffer.read())', shared / '.cache' / helper.name], input=(ROOT / 'tests/platform/linux/linux_chromium_checkpoint_owner.py').read_bytes(), capture_output=True)
    env = {k: v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'CODEX_', 'CLAUDE_'))}
    for kind in ('CONFIG', 'STATE', 'DATA', 'CACHE'): env['XDG_' + kind + '_HOME'] = str(out / kind.lower())
    env.update(GRAFFITTY_SERVER='/nonexistent-test-owner', GRAFFITTY_BIN=str(args.cli.resolve()), GRAFFITTY_CHECKPOINT_DIR=str(out / 'history'), CHECKPOINT_DOCUMENT=str(out / 'saved.json'), CHECKPOINT_RESTORED=str(out / 'restored.json'))
    results = {}
    with tempfile.TemporaryDirectory(prefix='gft-ck-', dir='/tmp') as local:
        @contextmanager
        def owner(phase, port=0):
            relative = PurePosixPath('.cache/r') / (run + phase[0])
            directory, host_directory = prefix / relative, shared / relative
            log = (out / (phase + '-launcher.log')).open('wb')
            process = subprocess.Popen(['ssh', args.ssh, shlex.join([args.enter, 'python3', str(helper), '--output', str(directory), '--server', args.server, '--host', args.host, '--backend', args.backend, '--platform', args.platform, '--site-port', str(port)])], stdout=log, stderr=log)
            tunnel = None
            link = '/tmp/gft-ck-' + run + phase[0]
            crashed = False
            try:
                deadline = time.monotonic() + 45
                while True:
                    check = subprocess.run(['ssh', args.ssh, shlex.join(['test', '-f', str(host_directory / 'bridge-ready')])], timeout=15)
                    if check.returncode == 0: break
                    assert process.poll() is None and time.monotonic() < deadline, 'Linux owner failed to start'
                    time.sleep(.2)
                descriptor = json.loads(remote_read(host_directory / 'connection.json'))
                fixture = json.loads(remote_read(host_directory / 'fixture.json'))
                host_ipc = str(host_directory / 'ipc.sock')
                ssh(['ln', '-s', str(PurePosixPath(host_ipc).parent), link], capture_output=True)
                sock = str(Path(local) / (phase + '.sock'))
                tunnel = subprocess.Popen(['ssh', '-o', 'ExitOnForwardFailure=yes', '-N', '-L', sock + ':' + link + '/' + PurePosixPath(host_ipc).name, args.ssh], stdout=log, stderr=log)
                deadline = time.monotonic() + 15
                while not Path(sock).exists():
                    assert tunnel.poll() is None and time.monotonic() < deadline
                    time.sleep(.1)
                descriptor['local']['url'] = 'ipc://' + sock
                descriptor_path = out / (phase + '-connection.json')
                descriptor_path.write_text(json.dumps(descriptor))
                env['GRAFFITTY_SERVER_DESCRIPTOR'] = str(descriptor_path)
                env['CHECKPOINT_SITE'] = 'http://127.0.0.1:' + str(fixture['site_port'])
                def crash():
                    nonlocal crashed
                    ssh([args.enter, 'touch', str(directory / 'kill')], capture_output=True)
                    process.wait(timeout=40)
                    crashed = True
                fixture['directory'] = str(directory)
                fixture['shared_directory'] = str(host_directory)
                yield fixture, crash
            finally:
                if process.poll() is None:
                    ssh([args.enter, 'touch', str(directory / 'stop')], capture_output=True)
                    process.wait(timeout=40)
                if tunnel:
                    tunnel.terminate(); tunnel.wait(timeout=10)
                ssh(['rm', '-f', link], capture_output=True)
                for filename in ('server.log','cleanup.json'):
                    try: (out / (phase + '-' + filename)).write_text(remote_read(host_directory / filename))
                    except subprocess.CalledProcessError: pass
                log.close()
                cleanup = json.loads((out / (phase + '-cleanup.json')).read_text())
                assert cleanup['exit'] == (-9 if crashed else 0) and not cleanup['leaked_cgroups'], cleanup
                results[phase] = cleanup
        def frontend(phase, script, extra=()):
            with (out / (phase + '-godot.log')).open('wb') as log:
                result = subprocess.run([args.godot, '--headless', '--path', str(ROOT / 'frontends/godot/project'), '--script', 'tests/' + script, '--', *extra, '--cwd=/tmp'], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=120)
            text = (out / (phase + '-godot.log')).read_text()
            assert result.returncode == 0 and 'SCRIPT ERROR' not in text, text[-6000:]
            return text
        def native_save(fixture, source, phase):
            remote_input = PurePosixPath(fixture['directory']) / 'capture.json'
            host_input = PurePosixPath(fixture['shared_directory']) / 'capture.json'
            ssh(['python3', '-c', 'import pathlib,sys;pathlib.Path(sys.argv[1]).write_bytes(sys.stdin.buffer.read())', host_input], input=source.read_bytes(), capture_output=True)
            result = ssh([args.enter, 'env', 'GRAFFITTY_CHECKPOINT_DIR=' + fixture['directory'] + '/history', args.server, 'checkpoint', 'save', '--input', remote_input], capture_output=True, text=True)
            (out / (phase + '-native-save.json')).write_text(result.stdout)
            saved_path = json.loads(result.stdout)['path']
            assert saved_path.startswith(args.remote_root + '/')
            document = remote_read(args.shared_root + saved_path[len(args.remote_root):])
            (out / (phase + '-native-document.json')).write_text(document)
            assert json.loads(document)['windows'][0]['chromiums'] == json.loads(source.read_text())['windows'][0]['chromiums']
        with owner('before') as (first, crash):
            assert 'CHROMIUM_CHECKPOINT_SAVE_PASS' in frontend('before','chromium_checkpoint_save.gd')
            saved = json.loads((out / 'saved.json').read_text())
            assert saved['windows'][0]['chromiums'][0]['urls'] == [env['CHECKPOINT_SITE'] + '/second.html',env['CHECKPOINT_SITE'] + '/first.html']
            native_save(first, out / 'saved.json', 'before')
            crash()
        prepared = subprocess.run([str(args.cli), 'checkpoint', 'restore', '--prepare-only', '--checkpoint', str(out / 'before-native-document.json')], env=env, capture_output=True, text=True, timeout=30)
        (out / 'prepare.log').write_text(prepared.stdout + prepared.stderr)
        assert prepared.returncode == 0, prepared.stderr
        path = json.loads(prepared.stdout)['prepared']
        with owner('after', first['site_port']) as (second, _):
            assert second['pid'] != first['pid']
            text = frontend('after','linux_chromium_checkpoint_restore.gd', ['--restore-checkpoint=' + path])
            assert 'CHECKPOINT RESTORE SMOKE: PASS' in text, text[-6000:]
            assert (out / 'restored.json').exists()
            native_save(second, out / 'restored.json', 'after')
        (out / 'results.json').write_text(json.dumps({'status':'pass','cleanup':results,'frontend_platform':os.uname().sysname,'linux_backend':args.backend,'display':args.platform},indent=2))
        print('PASS saved workspace restored on replacement Linux owner')
    ssh(['rm','-f',shared / '.cache' / helper.name], capture_output=True)

if __name__ == '__main__': main()
