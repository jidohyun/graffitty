#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2", "nvidia-ml-py>=13,<14"]
# ///
"""Linux browser automation interactions; native dialogs and client audio are out of scope."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import time

import sys
sys.path[:0] = [str(Path(__file__).resolve().parents[3] / d) for d in ("tests/chromium",)]
from chromium_video_e2e import evaluate
from chromium_popup_tab_e2e import run as popup_cases
from linux_chromium_lifecycle_e2e import Fixture
from linux_chromium_stress_e2e import eventually


def command(f, page, method, **params):
    ticket = f.rpc('chromium.command', chromium=page, action='cdp', args={'method': method, 'params': params})['ticket']
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        result = f.rpc('chromium.result', chromium=page, ticket=ticket)
        if result is not None:
            assert 'error' not in result, result
            return result['result']
        time.sleep(.02)
    raise AssertionError(f'{method} timed out')


def js(f, page, expression):
    result = command(f, page, 'Runtime.evaluate', expression=expression, returnByValue=True, awaitPromise=True, userGesture=True)
    assert 'exceptionDetails' not in result, result
    return result['result'].get('value')


class Site(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def run(args):
    with Fixture(args) as f:
        site = f.out / 'site'
        site.mkdir()
        (site / 'index.html').write_text('<title>interactions</title><input id="text"><input id="file" type="file"><video id="v" muted loop width="640" height="360"></video>')
        payload = 'upload 한글 😀\n'
        upload = site / 'upload.txt'
        upload.write_text(payload)
        (site / 'download.bin').write_bytes(bytes(range(256)) * 32)
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', "nullsrc=s=640x360:r=30,geq=r='170+mod(N,70)':g=0:b=0,format=yuv420p", '-t', '4', '-c:v', 'libvpx', '-b:v', '500k', '-y', str(site / 'video.webm')], check=True, timeout=60)
        web = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Site, directory=str(site)))
        threading.Thread(target=web.serve_forever, daemon=True).start()
        try:
            base = f'http://127.0.0.1:{web.server_port}/'
            (site / 'target.html').write_text('<title>target</title>target')
            with (site / 'index.html').open('a') as source:
                source.write("<a id=blank target=_blank href='target.html?blank'>blank</a>")
            popup_cases(f.owner, base)
            f.owner.ws.settimeout(5)
            f.owner.messages.clear()
            for browser in list(f.owner.topology.get('chromiums', [])):
                f.rpc('chromium.close', chromium='%' + str(browser['id']))
            page, sid, _ = f.page('interactions')
            stream = f.stream(sid)
            eventually(lambda: stream.latest, 'Viewer did not subscribe')
            command(f, page, 'Page.navigate', url=base + 'index.html')
            eventually(lambda: evaluate(f.rpc, page, '!!document.getElementById("text")'), 'Page did not load')
            checks = {'popup_cases': 4}
            js(f, page, "document.getElementById('text').focus();window.events=[];for(let t of ['compositionstart','compositionupdate','compositionend'])document.addEventListener(t,e=>events.push([e.type,e.data]));true")
            command(f, page, 'Input.imeSetComposition', text='한', selectionStart=1, selectionEnd=1)
            command(f, page, 'Input.imeSetComposition', text='한글', selectionStart=2, selectionEnd=2)
            f.rpc('chromium.input', chromium=page, event={'method': 'Input.insertText', 'params': {'text': '한글 😀 café'}})
            eventually(lambda: js(f, page, "document.getElementById('text').value") == '한글 😀 café', 'Unicode composition commit failed')
            events = js(f, page, 'events')
            assert any(v[0] == 'compositionend' for v in events), events
            checks['cdp_composition_and_protocol_commit'] = events
            root = command(f, page, 'DOM.getDocument')['root']['nodeId']
            node = command(f, page, 'DOM.querySelector', nodeId=root, selector='#file')['nodeId']
            command(f, page, 'DOM.setFileInputFiles', nodeId=node, files=[str(upload)])
            assert js(f, page, "document.getElementById('file').files[0].text()") == payload
            checks['upload_automation'] = 'pass'
            downloads = f.out / 'downloads'
            downloads.mkdir()
            command(f, page, 'Browser.setDownloadBehavior', behavior='allow', downloadPath=str(downloads))
            js(f, page, "let a=document.createElement('a');a.href='download.bin';a.download='result.bin';a.click();true")
            eventually(lambda: (downloads / 'result.bin').exists(), 'Download did not complete')
            assert (downloads / 'result.bin').read_bytes() == (site / 'download.bin').read_bytes()
            checks['download_automation'] = 'pass'
            js(f, page, "window.permissionResults={};Notification.requestPermission().then(v=>permissionResults.notification=v,e=>permissionResults.notification=e.name);navigator.mediaDevices.getUserMedia({audio:true,video:true}).then(s=>{s.getTracks().forEach(t=>t.stop());permissionResults.media='unexpected grant'},e=>permissionResults.media=e.name);true")
            def permissions_settled():
                current = js(f, page, 'permissionResults')
                f.save('permissions.json', current)
                return 'notification' in current and 'media' in current
            eventually(permissions_settled, 'Permission requests did not settle', timeout=15)
            permission_results = js(f, page, 'permissionResults')
            permissions = [permission_results['notification'], permission_results['media']]
            assert permissions[0] == 'denied' and permissions[1] in ('NotAllowedError', 'NotFoundError'), permissions
            checks['permission_denial'] = permissions
            assert js(f, page, "v.style='position:fixed;inset:0;width:100vw;height:100vh;object-fit:fill';v.src='video.webm';v.play().then(()=>true)")
            eventually(lambda: len(stream.sample) >= 60, 'Initial video sample missing')
            stream.reset_sample()
            start = js(f, page, 'v.currentTime')
            time.sleep(2)
            media = js(f, page, '[v.currentTime,v.getVideoPlaybackQuality().totalVideoFrames,v.paused,v.error?.code||0]')
            assert media[1] > 30 and not media[2] and media[3] == 0, media
            eventually(lambda: len(stream.sample) >= 60, 'Video sample missing')
            checks['video_playback'] = {'initial_time': start, 'media': media, 'decode': stream.decode(f.out, 'media')}
            # Browser clipboard API is tested with an explicit temporary origin grant;
            # this does not exercise a frontend clipboard bridge or a native prompt.
            command(f, page, 'Browser.grantPermissions', origin=base.rstrip('/'), permissions=['clipboardReadWrite', 'clipboardSanitizedWrite'])
            formats = js(f, page, 'navigator.clipboard.read().then(items=>items.flatMap(i=>i.types))')
            assert all(t == 'text/plain' for t in formats), 'Clipboard test requires no rich clipboard formats'
            original = js(f, page, 'navigator.clipboard.readText()')
            assert not original, 'Clipboard test requires an empty disposable desktop clipboard'
            try:
                assert js(f, page, "navigator.clipboard.writeText('clipboard 한글 😀').then(()=>navigator.clipboard.readText())") == 'clipboard 한글 😀'
            finally:
                js(f, page, 'navigator.clipboard.writeText(' + json.dumps(original) + ').then(()=>true)')
                command(f, page, 'Browser.resetPermissions')
            checks['browser_clipboard_text_roundtrip'] = 'pass'
            f.save('results.json', {'status': 'pass', 'checks': checks})
            print('PASS interactions', json.dumps(checks), flush=True)
        finally:
            web.shutdown()
            web.server_close()


if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--backend', choices=['chrome', 'alloy'], required=True)
    parser.add_argument('--platform', choices=['wayland', 'x11'], required=True)
    run(parser.parse_args())
