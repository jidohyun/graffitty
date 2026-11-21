"""Godot OSC52 and projected links, with owner AND frontend on a private clipboard."""
import argparse
import base64
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/godot",)]
import test_dashboard as dashboard
import windows_private_desktop
from windows_rich_clipboard_e2e import packet as rich_packet, reply as rich_reply, encoded


def osc52(text=None, bel=False):
    payload = '?' if text is None else base64.b64encode(text.encode()).decode()
    return '\x1b]52;c;' + payload + ('\x07' if bel else '\x1b\\')


def prepare(directory):
    text = 'Private Unicode café 🏰 한글 4729'
    (directory/'start.vt').write_text(osc52(text)+osc52(bel=True)+osc52()+rich_packet('type=read', encoded('text/plain')), encoding='utf-8')
    expected = osc52(text, True)+osc52(text)+rich_reply({'text/plain':text.encode()}, ['text/plain'])
    (directory/'expected-initial-bytes').write_text(str(len(expected)), encoding='utf-8')
    phases = [osc52('DISABLED WRITE')+osc52(), osc52(bel=True), osc52(bel=True),
              osc52(bel=True), osc52(), osc52(bel=True),
              '\x1b[2J\x1b[H\x1b]8;;https://example.invalid/actual?x=4729\x1b\\VISIBLE LABEL\x1b]8;;\x1b\\\x1b[2;1H'
              'https://example.invalid/plain\x1b[3;1H'
              '\x1b]8;;javascript:alert(4729)\x1b\\UNSUPPORTED\x1b]8;;\x1b\\\x1b[4;1H']
    for number, value in enumerate(phases, 1):
        (directory/f'command-{number}.vt').write_text(value, encoding='utf-8')
    expected += osc52(text)+osc52(text, True)+osc52(text, True)
    (directory/'expected.txt').write_text(expected, encoding='utf-8')
    closed = directory/'closed-pane'; closed.mkdir()
    (closed/'start.vt').write_text(osc52(), encoding='utf-8')


def private_station():
    user = ctypes.WinDLL('user32', use_last_error=True)
    user.GetProcessWindowStation.restype = wintypes.HANDLE
    user.GetUserObjectInformationW.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    name = ctypes.create_unicode_buffer(256)
    needed = wintypes.DWORD()
    assert user.GetUserObjectInformationW(user.GetProcessWindowStation(), 2, name, ctypes.sizeof(name), ctypes.byref(needed))
    assert name.value.startswith('GraffittyPrivate-'), 'Refuse clipboard fixture on interactive window station'
    return name.value


def worker(args):
    station = private_station()
    env = dict(os.environ)
    directory = args.evidence.resolve()
    env['GRAFFITTY_INPUT_EVIDENCE'] = str(directory)
    env['GRAFFITTY_INPUT_PYTHON'] = sys.executable
    if args.links_only: env['GRAFFITTY_LINKS_ONLY'] = '1'
    template = next(case for case in dashboard.cases() if case['suite']=='windows' and case['name']=='powershell-7')
    dashboard.configure_owner(template, env, directory)
    with dashboard.PrivateServer(env, directory, template['shell']) as owner:
        with (directory/'replay.log').open('wb') as log:
            result = subprocess.run([dashboard.GODOT, '--path', str(args.project.resolve()), '--script',
                                     str(ROOT/'tests/llm-e2e/suites/godot/integration/replays/protocol-actions.gd'),
                                     '--', '--shell='+template['shell']], env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        (directory/'owner-build.json').write_text(json.dumps({'path':str(owner.binary),'sha256':hashlib.sha256(owner.binary.read_bytes()).hexdigest(),'window_station':station}),encoding='utf-8')
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--project', type=Path, default=dashboard.GODOT_ROOT)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--links-only', action='store_true')
    args = parser.parse_args()
    if args.worker: return worker(args)
    directory = args.evidence.resolve(); directory.mkdir(parents=True, exist_ok=False)
    prepare(directory)
    if args.links_only:
        (directory/'start.vt').write_text((directory/'command-7.vt').read_text(encoding='utf-8'), encoding='utf-8')
        (directory/'expected.txt').write_text('', encoding='utf-8')
    report = {'status':'FAIL'}
    try:
        keep = {'GRAFFITTY_TEST_SERVER','GRAFFITTY_TEST_GODOT','GRAFFITTY_GODOT'}
        env = {k:v for k,v in os.environ.items() if not k.startswith(('CODEX_','CLAUDE_')) and (not k.startswith('GRAFFITTY_') or k in keep)}
        for kind in ('CONFIG','STATE','CACHE','DATA'): env[f'XDG_{kind}_HOME'] = str(directory/kind.lower())
        command = [sys.executable, '-X', 'utf8', __file__, '--worker', '--evidence', str(directory), '--project', str(args.project.resolve())]
        if args.links_only: command.append('--links-only')
        report['scope'] = 'links-only' if args.links_only else 'clipboard-and-links'
        report['isolation'] = windows_private_desktop.run(command,env=env,cwd=ROOT,log=directory/'worker.log',timeout=115)
        log = (directory/'replay.log').read_text(encoding='utf-8',errors='replace')
        report['checks'] = dashboard.CHECK.findall(log)
        assert report['isolation']['exit_code'] == 0 and 'PROTOCOL_ACTIONS_REPLAY_PASS' in log, 'See replay.log/worker.log'
        assert not any(line.lstrip().startswith(('ERROR:','SCRIPT ERROR:','WARNING:')) for line in log.splitlines())
        receipt = json.loads((directory/'receipt.json').read_text(encoding='utf-8'))
        assert receipt['text'] == (directory/'expected.txt').read_text(encoding='utf-8'), 'OSC52 raw byte mismatch'
        report.update(status='PASS', raw_reply_bytes=len(receipt['text'].encode()), raw_reply_sha256=hashlib.sha256(receipt['text'].encode()).hexdigest())
    except Exception as error: report['error'] = str(error)
    extension = args.project.resolve()/'addons/graffitty/bin/libgraffitty.windows.x86_64.dll'
    report['extension'] = {'path':str(extension),'sha256':hashlib.sha256(extension.read_bytes()).hexdigest()}
    if (directory/'owner-build.json').exists(): report['owner'] = json.loads((directory/'owner-build.json').read_text())
    (directory/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
    return report['status'] != 'PASS'


if __name__ == '__main__': sys.exit(main())
