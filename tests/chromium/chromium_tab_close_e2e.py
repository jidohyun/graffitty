# /// script
# dependencies = ["websocket-client>=1.8,<2", "pillow>=11"]
# ///
"""Closing a selected tab selects its neighbour without flashing the first tab."""
import json
import subprocess
import tempfile
import time
from io import BytesIO
from pathlib import Path
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from functools import partial
import threading
from PIL import Image
import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from headless_remote_e2e import BINARY, Client


def main():
    with tempfile.TemporaryDirectory(prefix='gr-close-') as directory:
        root = Path(directory)
        for color in ['red', 'lime', 'blue']:
            (root/(color+'.html')).write_text(f'<body style="margin:0;background:{color}">')
        http=ThreadingHTTPServer(('127.0.0.1',0),partial(SimpleHTTPRequestHandler,directory=str(root)))
        threading.Thread(target=http.serve_forever,daemon=True).start()
        with (root/'server.log').open('w') as log:
            server = subprocess.Popen([BINARY, 'server', '--listen', '127.0.0.1:0',
                '--connection', root/'server.json', '--auth-file', root/'auth.json',
                '--shell', '/bin/sh'], stdout=log, stderr=log)
        client = None
        try:
            deadline = time.monotonic()+60
            while not (root/'server.json').exists():
                assert server.poll() is None
                assert time.monotonic()<deadline
                time.sleep(.05)
            client = Client(json.loads((root/'server.json').read_text()), chromium_video=[], chromium_image_format='png')
            pane = client.topology['panes'][0]['id']
            seq = 0
            def rpc(method, **params):
                nonlocal seq
                seq += 1
                client.action('rpc', pane, request=seq, method=method, params=params)
                client.until(lambda:any(v.get('request')==seq for v in client.messages))
                response = next(v for v in client.messages if v.get('request')==seq)
                assert response['type']=='ack', response
                return response['result']
            def url(color):
                return f'http://127.0.0.1:{http.server_port}/{color}.html'
            chromium = rpc('chromium.create', url=url('red'))['chromium']
            bid = int(chromium[1:])
            client.action('subscribe', sessions=[bid])
            def command(action, **args):
                ticket=rpc('chromium.command', chromium=chromium, action=action, args=args)['ticket']
                deadline=time.monotonic()+20
                while time.monotonic()<deadline:
                    response=rpc('chromium.result', chromium=chromium, ticket=ticket)
                    if response is not None:
                        assert 'error' not in response, response
                        return response.get('result', response)
                    time.sleep(.01)
                raise AssertionError('Chromium command timed out')
            def settle(channel):
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    command('chrome-state')
                    if bid in client.payloads:
                        image=Image.open(BytesIO(client.payloads[bid])).convert('RGB')
                        pixel=image.getpixel((image.width//2,image.height//2))
                        if pixel[channel]>100 and all(pixel[k]<50 for k in range(3) if k!=channel): return
                    time.sleep(.02)
                raise AssertionError('Selected tab pixels did not arrive')
            settle(0)
            command('tab-new',url=url('lime'));settle(1)
            command('tab-new',url=url('blue'));settle(2)
            seen=[]
            receive=client.receive
            def observe():
                receive()
                if bid in client.payloads:
                    image=Image.open(BytesIO(client.payloads[bid])).convert('RGB')
                    seen.append(image.getpixel((image.width//2,image.height//2)))
            client.receive=observe
            state=command('tab-close',chromium_id=3)
            assert len(state['tabs'])==2 and state['chromiumId']==2,state
            settle(1)
            assert not any(r>100 and g<50 and b<50 for r,g,b in seen), 'First tab flashed during closure'
            client.receive=receive
            state=command('tab-close',chromium_id=2)
            assert len(state['tabs'])==1 and state['chromiumId']==1,state
            settle(0)
            command('tab-new',url=url('lime'));settle(1)
            command('tab-new',url=url('blue'));settle(2)
            tabs=command('chrome-state')['tabs']
            lime,blue=(next(t['id'] for t in tabs if colour in t['url']) for colour in ('lime','blue'))
            state=command('tab-close',chromium_id=lime)
            assert len(state['tabs'])==2 and state['chromiumId']==blue,state
            settle(2)
            # Page ids follow pages: a moved tab keeps its id and selection.
            red=next(t['id'] for t in state['tabs'] if 'red' in t['url'])
            state=command('tab-move',chromium_id=blue,index=0)
            assert [t['id'] for t in state['tabs']]==[blue,red] and state['chromiumId']==blue,state
            settle(2)
            print('PASS one close per tab; selected neighbour pixels; inactive close retains selection; no first-tab flash; moved tabs keep their ids')
        finally:
            if client: client.ws.close()
            server.terminate();server.wait(timeout=15)
            http.shutdown();http.server_close()

if __name__=='__main__': main()
