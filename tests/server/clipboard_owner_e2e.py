"""Check actual owner routing with two viewers; never access an OS clipboard."""
import argparse
import base64
import shlex
import json
import os
from pathlib import Path
import struct
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from private_session_e2e import PrivateClient, local_socket


def terminal_write(sequence):
    if os.name == 'nt':
        encoded = base64.b64encode(sequence.encode()).decode()
        return "[Console]::Write([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('" + encoded + "')))\r"
    return "printf '%b' " + shlex.quote(''.join('\\%03o' % byte for byte in sequence.encode())) + "\r"


READ_CLIPBOARD = terminal_write("\x1b]5522;type=read;dGV4dC9wbGFpbg==\x1b\\")


class Peer(PrivateClient):
    def __init__(self, descriptor, workspace='main', new=False, clipboard=True):
        self.socket = local_socket(descriptor['url'])
        self.sequence = 0
        self.events = []
        self.send(dict(type='auth_local', version=1, token=descriptor['token'], workspace=workspace,
                       new_session=new, features=['clipboard'] if clipboard else []))
        self.workspace = self.until(lambda m: m.get('type') == 'ready')['workspace']
        self.topology = self.until(lambda m: m.get('type') == 'topology')
        self.id = self.topology['panes'][0]['id']
        self.send(dict(type='subscribe', sessions=[self.id]))

    def until(self, predicate):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            kind, size = struct.unpack('<BI', self.read_exact(5))
            data = self.read_exact(size)
            if kind != 1:
                continue
            message = json.loads(data)
            if message.get('type') in ('clipboard', 'clipboard_reset'):
                self.events.append(message)
            if predicate(message):
                return message
        raise AssertionError('Owner reply timeout')

    def query(self):
        self.events.clear()
        assert self.action('text', self.id, text=READ_CLIPBOARD)['type'] == 'ack'
        if not any(m['type'] == 'clipboard' for m in self.events):
            self.until(lambda m: m.get('type') == 'clipboard')
        return next(m for m in self.events if m['type'] == 'clipboard')

    def reply(self, request):
        return self.action('clipboard_reply', self.id, generation=request['generation'],
                           ticket=request['ticket'], offset=0, done=True, data='')['type']

    def barrier(self):
        assert self.action('sync')['type'] == 'ack'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    env = {k:v for k,v in os.environ.items() if not k.startswith('GRAFFITTY_')}
    for kind in ('CONFIG','STATE','CACHE','DATA'):
        env[f'XDG_{kind}_HOME'] = str(directory/kind.lower())
    config = directory/'config/graffitty/server.toml'
    config.parent.mkdir(parents=True)
    config.write_text('[terminal]\nlogin_shell=false\n', encoding='utf-8')
    checks = []
    peers = []
    try:
        with PrivateServer(env, directory, 'pwsh.exe' if os.name == 'nt' else '/bin/sh') as owner:
            local = json.loads(owner.descriptor.read_text())['local']
            first = Peer(local, new=True); peers.append(first)
            second = Peer(local, first.workspace); peers.append(second)
            request = first.query()
            second.barrier()
            assert not any(m['type'] == 'clipboard' for m in second.events)
            assert second.reply(request) == 'error'
            assert first.reply(request) == 'ack'
            assert first.reply(request) == 'error'
            checks.append('Single viewer delivery; foreign and duplicate replies rejected')
            stale = first.query()
            assert second.action('text', second.id, text='# clipboard ownership\r')['type'] == 'ack'
            assert first.reply(stale) == 'error'
            request = second.query()
            assert second.reply(request) == 'ack'
            checks.append('Input ownership transfer revokes old consent')
            stale = second.query()
            assert second.action('text', second.id, text=terminal_write("\x1bc"))['type'] == 'ack'
            second.until(lambda m: m.get('type') == 'clipboard_reset' and m['generation'] != stale['generation'])
            assert second.reply(stale) == 'error'
            checks.append('Terminal reset revokes outstanding request')
            second.socket.close(); peers.remove(second)
            request = first.query()
            assert first.reply(request) == 'ack'
            third = Peer(local, first.workspace); peers.append(third)
            third.barrier()
            assert not any(m['type'] == 'clipboard' for m in third.events)
            checks.append('Disconnect falls back to surviving viewer; reconnect never replays clipboard')
            assert first.action('create', first.id, kind='tab')['type'] == 'ack'
            moved = first.action('session_transfer', tab=first.topology['panes'][0]['tab'])
            assert moved['type'] == 'ack', moved
            viewer = Peer(local, moved['workspace']); peers.append(viewer)
            control = Peer(local, moved['workspace'], clipboard=False); peers.append(control)
            assert control.action('text', control.id, text=READ_CLIPBOARD)['type'] == 'ack'
            request = viewer.until(lambda m: m.get('type') == 'clipboard')
            assert viewer.reply(request) == 'ack'
            checks.append('Pane transfer revokes viewers in the previous workspace')
        result = {'status':'PASS', 'checks':checks}
    except Exception as error:
        result = {'status':'FAIL', 'checks':checks, 'error':str(error)}
    finally:
        for peer in peers: peer.socket.close()
    (directory/'report.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
    return result['status'] != 'PASS'


if __name__ == '__main__':
    sys.exit(main())
