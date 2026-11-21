"""Real Godot/ConPTY rich clipboard transfer on a private Windows window station."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import random
import struct
import sys
import zlib

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/godot",)]
import test_dashboard as dashboard
import windows_private_desktop


def encoded(value):
    return base64.b64encode(value if isinstance(value, bytes) else value.encode()).decode()


def packet(metadata, value=None):
    return '\x1b]5522;' + metadata + ('' if value is None else ';' + value) + '\x1b\\'


def reply(data, types):
    result = packet('type=read:status=OK')
    for mime in types:
        value = data[mime]
        for offset in range(0, len(value), 4096):
            result += packet('type=read:status=DATA:mime='+encoded(mime), encoded(value[offset:offset+4096]))
    return result + packet('type=read:status=DONE')


def prepare(directory):
    rng = random.Random(4729)
    pixels = b''.join(b'\0'+rng.randbytes(256*4) for _ in range(256))
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data)&0xffffffff)
    png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB',256,256,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b'')
    assert len(png) > 128*1024
    data = {'text/plain': 'Unicode café 🏰 한글'.encode(), 'image/png': png,
            'application/x-graffitty-binary': b'\0\1\xff\0\0'}
    output = packet('type=write')
    for mime, value in data.items():
        text = encoded(value)
        for offset in range(0, len(text), 4096):
            output += packet('type=wdata:mime='+encoded(mime), text[offset:offset+4096])
    output += packet('type=walias:mime='+encoded('image/png'), encoded('application/x-graffitty-png'))
    data['application/x-graffitty-png'] = png
    output += packet('type=wdata')
    names = sorted(data)
    output += packet('type=read', encoded('.')) + packet('type=read', encoded(' '.join(names)))
    (directory/'start.vt').write_text(output, encoding='utf-8')
    read_text = packet('type=read', encoded('text/plain'))
    commands = [read_text, packet('type=write'), read_text, read_text, read_text,
                packet('type=read:loc=primary', encoded('text/plain'))+packet('type=write:loc=primary')]
    for phase, command in enumerate(commands, 1):
        (directory/f'command-{phase}.vt').write_text(command, encoding='utf-8')
    expected = packet('type=write:status=DONE') + reply({'.': ' '.join(names).encode()}, ['.']) + reply(data, names)
    (directory/'expected-initial-bytes').write_text(str(len(expected)), encoding='utf-8')
    expected += packet('type=read:status=EPERM')+packet('type=write:status=EPERM')+packet('type=read:status=EPERM')
    expected += reply(data, ['text/plain'])
    expected += packet('type=read:status=ENOSYS')+packet('type=write:status=ENOSYS')
    (directory/'expected.txt').write_text(expected, encoding='utf-8')
    return {'png_bytes':len(png), 'png_sha256':hashlib.sha256(png).hexdigest(), 'expected_sha256':hashlib.sha256(expected.encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--project', type=Path, default=dashboard.GODOT_ROOT)
    args = parser.parse_args()
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    report = {'status':'FAIL', 'payload':prepare(directory)}
    try:
        env = {k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'CODEX_', 'CLAUDE_'))}
        env.update({f'XDG_{kind}_HOME':str(directory/kind.lower()) for kind in ('CONFIG','STATE','CACHE','DATA')})
        env['GRAFFITTY_INPUT_EVIDENCE'] = str(directory)
        env['GRAFFITTY_INPUT_PYTHON'] = sys.executable
        template = next(case for case in dashboard.cases() if case['suite']=='windows' and case['name']=='powershell-7')
        dashboard.configure_owner(template, env, directory)
        with dashboard.PrivateServer(env, directory, template['shell']) as owner:
            report['owner'] = {'path':str(owner.binary), 'sha256':hashlib.sha256(owner.binary.read_bytes()).hexdigest()}
            report['isolation'] = windows_private_desktop.run(
                [dashboard.GODOT,'--path',str(args.project.resolve()),'--script',
                 str(ROOT/'tests/llm-e2e/suites/godot/integration/replays/rich-clipboard.gd'), '--', '--shell='+template['shell']],
                env=env, cwd=ROOT, log=directory/'replay.log', timeout=90)
        log = (directory/'replay.log').read_text(encoding='utf-8',errors='replace')
        report['checks'] = dashboard.CHECK.findall(log)
        assert report['isolation']['exit_code'] == 0, 'Godot failed; see replay.log'
        assert 'RICH_CLIPBOARD_REPLAY_PASS' in log and not any(status=='FAIL' for status,_ in report['checks'])
        assert not any(line.lstrip().startswith(('ERROR:', 'SCRIPT ERROR:', 'WARNING:')) for line in log.splitlines()), 'Unexpected Godot diagnostic'
        receipt = json.loads((directory/'receipt.json').read_text(encoding='utf-8'))
        assert receipt['text'] == (directory/'expected.txt').read_text(encoding='utf-8'), 'Raw PTY transfer differs from exact expected bytes'
        report.update(status='PASS', raw_reply_bytes=len(receipt['text'].encode()), raw_reply_sha256=hashlib.sha256(receipt['text'].encode()).hexdigest())
    except Exception as error:
        report['error'] = str(error)
    extension = args.project.resolve()/'addons/graffitty/bin/libgraffitty.windows.x86_64.dll'
    report['extension'] = {'path':str(extension),'sha256':hashlib.sha256(extension.read_bytes()).hexdigest()}
    (directory/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
    return 0 if report['status']=='PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
