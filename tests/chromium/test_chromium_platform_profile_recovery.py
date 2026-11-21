#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Check cross-server profile locking and storage recovery after a crash.

Close and reopen the profile before fault injection so the data under
test is committed. Use native Chromium hosts and check state through CDP.
"""
import json
from pathlib import Path
import time
from urllib.parse import urlsplit
from test_chromium_platform_isolation import Workspace
from test_chromium_platform_stress import main, connection, evaluate, eventually
from test_desktop_chromium import quote


def exercise(matrix, out, descriptor):
    windows = matrix.args.platform == 'windows'
    def directory(folder):
        return matrix.remote + '/' + folder.name if windows else str(folder / 'owner')
    def state(folder):
        if windows:
            matrix.copy(folder / 'live-fixture.json', directory(folder) + '/fixture.json', download=True)
            return json.loads((folder / 'live-fixture.json').read_text())
        return json.loads((folder / 'owner/fixture.json').read_text())
    original = state(out); url = original['origin_url']; profile = directory(out) + '/recovery-profile'
    results = {}
    def save(name, value=True):
        results[name] = value
        (out / 'profile-recovery.json').write_text(json.dumps(results, indent=2))
        print(out.name, name, 'pass', flush=True)
    def open_page(owner, reopening=False):
        def create():
            reply = owner.call('chromium.create', url=url, profile=profile)
            if reply['type'] != 'ack':
                assert reopening and ('already in use' in json.dumps(reply) or 'already owned' in json.dumps(reply)), reply
                return None
            return reply['result']
        result = eventually(create, 'Persistent profile did not unlock after close/crash')
        assert result['temporary_profile'] is False
        browser = result['chromium']; sid = int(browser[1:])
        owner.client.until(lambda: any(b['id'] == sid and b['state'].get('chromiumId', -1) > 0 for b in owner.client.topology.get('chromiums', [])))
        eventually(lambda: evaluate(owner.rpc, browser, 'document.title') == 'Isolation fixture', 'Restored origin did not load')
        return browser
    durable_record = {'text': 'committed 日本語 한글 🚀', 'numbers': list(range(256))}
    def database(owner, browser, operation='read'):
        actions = {
            'write': "store.put(" + json.dumps(durable_record) + ", 'record');",
            'abort': "store.put({text:'must-not-survive'}, 'record');tx.abort();",
            'read': "const request=store.get('record');request.onsuccess=()=>{value=request.result ?? null};",
        }
        expression = """window.recoveryDBResult=null;(()=>{
const open=indexedDB.open('recovery-e2e',1);
open.onupgradeneeded=()=>open.result.createObjectStore('records');
open.onerror=()=>window.recoveryDBResult={error:String(open.error)};
open.onsuccess=()=>{const db=open.result;let value=null;
const tx=db.transaction('records',MODE);const store=tx.objectStore('records');
tx.oncomplete=()=>{db.close();window.recoveryDBResult={status:'committed',value}};
tx.onabort=()=>{db.close();window.recoveryDBResult={status:'aborted'}};
ACTION
};})();true""".replace('MODE', json.dumps('readonly' if operation == 'read' else 'readwrite')).replace('ACTION', actions[operation])
        assert evaluate(owner.rpc, browser, expression) is True
        result = eventually(lambda: evaluate(owner.rpc, browser, 'window.recoveryDBResult'), 'IndexedDB operation timed out')
        assert result.get('status') == ('aborted' if operation == 'abort' else 'committed'), result
        if operation == 'read': assert result['value'] == durable_record, result
        return result['status']
    def storage(owner, browser):
        assert evaluate(owner.rpc, browser, "[localStorage.getItem('durable'),document.cookie]") == ['committed', 'durable=committed']
        database(owner, browser)
    owner = Workspace(descriptor, 'recovery-owner')
    try:
        browser = open_page(owner)
        assert evaluate(owner.rpc, browser, "localStorage.setItem('durable','committed');document.cookie='durable=committed; Max-Age=3600; Path=/';true")
        database(owner, browser, 'write')
        database(owner, browser, 'abort')
        database(owner, browser)
        owner.rpc('chromium.close', chromium=browser)
        browser = open_page(owner, reopening=True); storage(owner, browser)
        assert evaluate(owner.rpc, browser, "window.beforeCrash=42;sessionStorage.setItem('transient','value');true")
        save('storage_committed_before_crash', {'cookie':True, 'local_storage':True, 'indexed_db':True, 'aborted_overwrite_rolled_back':True})
        contender = out.parent / (out.name + '-contender'); contender.mkdir()
        with matrix.fixture(contender, original['backend']):
            with connection(matrix, contender) as remote:
                competitor = Workspace(remote, 'competing-owner')
                try:
                    reply = competitor.call('chromium.create', url=url, profile=profile)
                    assert reply['type'] != 'ack' and ('already in use' in json.dumps(reply) or 'already owned' in json.dumps(reply)), reply
                    assert evaluate(owner.rpc, browser, 'window.beforeCrash') == 42
                    save('cross_server_lock_rejection')
                finally:
                    competitor.close()
        owner.close()
        if windows: matrix.ps('New-Item -ItemType File ' + quote(directory(out) + '/crash') + ' | Out-Null')
        else: Path(directory(out), 'crash').touch()
        deadline = time.monotonic() + 40
        while True:
            ready = matrix.ps('Test-Path ' + quote(directory(out) + '/cleanup.json')) == 'True' if windows else Path(directory(out), 'cleanup.json').exists()
            if ready: break
            assert time.monotonic() < deadline, 'Server crash cleanup timed out'
            time.sleep(.2)
        if windows:
            matrix.copy(out / 'injected-cleanup.json', directory(out) + '/cleanup.json', download=True)
            cleanup = json.loads((out / 'injected-cleanup.json').read_text())
        else: cleanup = json.loads(Path(directory(out), 'cleanup.json').read_text())
        assert cleanup['crashed'] and not cleanup['leaked_processes'], cleanup
        save('server_only_crash_cleanup', cleanup)
        replacement = out.parent / (out.name + '-replacement'); replacement.mkdir()
        matrix.args.origin_port = urlsplit(url).port
        try:
            with matrix.fixture(replacement, original['backend']):
                fresh = state(replacement)
                assert fresh['identity'] != original['identity']
                assert fresh['origin_url'] == url
                with connection(matrix, replacement) as remote:
                    restored = Workspace(remote, 'replacement-owner')
                    try:
                        browser = open_page(restored, reopening=True); storage(restored, browser)
                        assert evaluate(restored.rpc, browser, "[typeof window.beforeCrash,sessionStorage.getItem('transient')]") == ['undefined', None]
                        save('replacement_reuses_profile_with_fresh_document', {'original':original['identity'], 'replacement':fresh['identity']})
                        database(restored, browser, 'abort')
                        database(restored, browser)
                        save('indexed_db_read_and_rollback_after_crash')
                        sid = int(browser[1:])
                        restored.client.action('subscribe', sessions=[sid])
                        restored.client.until(lambda: sid in restored.client.frames)
                        frame = restored.client.frames[sid]
                        assert frame['format'] in ('hevc', 'h264'), frame
                        assert frame['width'] > 0 and frame['height'] > 0, frame
                        save('replacement_video_frame', {k:frame[k] for k in ['format','width','height']})
                        restored.rpc('chromium.close', chromium=browser)
                    finally:
                        restored.close()
        finally:
            matrix.args.origin_port = 0
    finally:
        owner.close()


if __name__ == '__main__':
    raise SystemExit(main(exercise, __doc__, test_origin=True))
