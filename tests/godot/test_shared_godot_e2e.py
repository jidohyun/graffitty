#!/usr/bin/env python3
"""Isolated real Godot -> shared owner -> detach/reconnect conformance."""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, signal, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
PROJECT = ROOT / 'frontends/godot/project'
sys.path[:0] = [str(ROOT / d) for d in ("tools",)]
from check_godot import failed
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def identity(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'lstart=,command='], text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else ''
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=pathlib.Path, required=True)
    parser.add_argument('--server', type=pathlib.Path, default=ROOT/'target/debug/gft')
    parser.add_argument('--godot', default='godot')
    args = parser.parse_args(); evidence = args.evidence.resolve(); evidence.mkdir(parents=True, exist_ok=False)
    env = {key: value for key, value in os.environ.items() if not key.startswith(('GRAFFITTY_',))}
    for kind in ('STATE', 'CONFIG', 'CACHE', 'DATA'): env[f'XDG_{kind}_HOME'] = str(evidence/kind.lower())
    descriptor = evidence/'private/server.json'
    env.update(GRAFFITTY_SERVER=str(args.server.resolve()), GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor),
               GRAFFITTY_BIN=str(ROOT/'target/debug/gft'), SHELL='/bin/sh')
    reports=[]; owner=None; owned_identity=''; result={'status':'FAIL', 'binary_sha256':sha(args.server),
        'extension_sha256':sha(PROJECT/'addons/graffitty/bin/libgraffitty.macos.dylib'), 'phases': reports}
    try:
        for phase in ('first', 'reconnect'):
            path=evidence/f'{phase}.json'; env.update(GRAFFITTY_TEST_PHASE=phase,GRAFFITTY_TEST_REPORT=str(path))
            with (evidence/f'{phase}.log').open('w') as log:
                process=subprocess.run([args.godot,'--verbose','--headless','--path',str(PROJECT),'--script',
                    'res://tests/shared_session_smoke.gd','--','--shell=/bin/sh'],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=40)
            if descriptor.exists() and owner is None:
                owner=int(json.loads(descriptor.read_text())['pid']); owned_identity=identity(owner)
                assert str(descriptor) in owned_identity and str(args.server.resolve()) in owned_identity
            assert not failed(process.returncode, (evidence/f'{phase}.log').read_text()), f'{phase}: Godot exit {process.returncode}; inspect log'
            report=json.loads(path.read_text()); reports.append(report)
            assert not report['failures'], report['failures']
            assert identity(owner)==owned_identity, 'server survives frontend exit'
            assert identity(report['shell_pid']), 'PTY shell survives frontend exit'
            ppid=subprocess.check_output(['ps','-p',str(report['shell_pid']),'-o','ppid='],text=True).strip()
            assert int(ppid)==owner, 'server, not frontend, owns shell'
        for field in ('server_pid','session','shell_pid'):
            assert reports[0][field]==reports[1][field], f'{field} retained across fresh process reconnect'
        result['status']='PASS'
    except BaseException as error:
        result['error']=str(error)
        raise
    finally:
        if owner is None and descriptor.exists():
            owner=int(json.loads(descriptor.read_text())['pid']); owned_identity=identity(owner)
        if owner and owned_identity and str(descriptor) in owned_identity and identity(owner)==owned_identity:
            os.kill(owner,signal.SIGTERM)
            deadline=time.monotonic()+5
            while identity(owner)==owned_identity and time.monotonic()<deadline:time.sleep(.05)
            if identity(owner)==owned_identity:os.kill(owner,signal.SIGKILL)
        result['owned_server_stopped']=not owner or identity(owner)!=owned_identity
        (evidence/'report.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
