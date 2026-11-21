#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Persistent profile close/reopen, storage durability and exclusive ownership.

Uses owned native browser hosts and CDP assertions, not native desktop input.
Profiles are disposable fixture directories; no personal browser data is used.
"""
import json
from test_chromium_platform_isolation import Workspace
from test_chromium_platform_stress import main, evaluate, eventually


def exercise(matrix, out, descriptor):
    windows = matrix.args.platform == 'windows'
    directory = matrix.remote + '/' + out.name if windows else str(out / 'owner')
    if windows:
        matrix.copy(out / 'live-fixture.json', directory + '/fixture.json', download=True)
        fixture = json.loads((out / 'live-fixture.json').read_text())
    else:
        fixture = json.loads((out / 'owner/fixture.json').read_text())
    url = fixture['origin_url']; profile = directory + '/persistent-profile'
    owner = Workspace(descriptor, 'profile-owner'); results = {}; pids = []
    def save(name, value=True):
        results[name] = value
        (out / 'profiles.json').write_text(json.dumps(results, indent=2))
        print(out.name, name, 'pass', flush=True)
    def page(path, reopening=False):
        def create():
            reply = owner.call('chromium.create', url=url, profile=path)
            if reply['type'] != 'ack':
                assert reopening and ('already in use' in json.dumps(reply) or 'already owned' in json.dumps(reply)), reply
                return None
            return reply['result']
        result = eventually(create, 'Profile remained locked after browser close')
        assert result['temporary_profile'] == (path == ''), result
        browser = result['chromium']; sid = int(browser[1:])
        owner.client.until(lambda: any(b['id'] == sid and b['state'].get('chromiumId', -1) > 0 for b in owner.client.topology.get('chromiums', [])))
        eventually(lambda: evaluate(owner.rpc, browser, 'document.title') == 'Isolation fixture', 'Page did not load')
        return browser, next(b['state']['pid'] for b in owner.client.topology['chromiums'] if b['id'] == sid)
    def db(browser, write=False):
        operation = "s.put('durable-value','key');" if write else "const r=s.get('key');r.onsuccess=()=>{value=r.result ?? null};"
        expression = """window.profileDBResult=null;(()=>{
const request=indexedDB.open('profile-e2e',1);
request.onupgradeneeded=()=>request.result.createObjectStore('values');
request.onerror=()=>window.profileDBResult={error:String(request.error)};
request.onsuccess=()=>{const d=request.result;let value=null;
const t=d.transaction('values',MODE);const s=t.objectStore('values');OPERATION
 t.oncomplete=()=>{d.close();window.profileDBResult={ok:true,value}};
 t.onabort=()=>{d.close();window.profileDBResult={error:String(t.error)}};
};})();true""".replace('MODE', json.dumps('readwrite' if write else 'readonly')).replace('OPERATION', operation)
        assert evaluate(owner.rpc, browser, expression) is True
        value = eventually(lambda: evaluate(owner.rpc, browser, 'window.profileDBResult'), 'IndexedDB operation did not complete')
        assert value.get('ok'), value
        return value['value']
    try:
        browser, pid = page(profile); pids.append(pid)
        assert evaluate(owner.rpc, browser, "localStorage.setItem('durable','value');document.cookie='durable=value; Max-Age=3600; Path=/';sessionStorage.setItem('transient','value');window.transientValue=42;true")
        db(browser, write=True)
        reply = owner.call('chromium.create', url=url, profile=profile)
        assert reply['type'] != 'ack' and ('already in use' in json.dumps(reply) or 'already owned' in json.dumps(reply)), reply
        assert evaluate(owner.rpc, browser, 'window.transientValue') == 42
        save('live_profile_lock_rejects_second_owner')
        for path, label in [(directory + '/other-profile', 'separate_persistent_profile'), ('', 'temporary_profile')]:
            other, _ = page(path)
            assert evaluate(owner.rpc, other, "[localStorage.getItem('durable'),document.cookie]") == [None, '']
            assert db(other) is None
            owner.rpc('chromium.close', chromium=other)
            save(label + '_isolated')
        for generation in range(3):
            owner.rpc('chromium.close', chromium=browser)
            browser, pid = page(profile, reopening=True)
            assert pid not in pids, (pid, pids)
            pids.append(pid)
            assert evaluate(owner.rpc, browser, "[localStorage.getItem('durable'),document.cookie,sessionStorage.getItem('transient'),typeof window.transientValue]") == ['value', 'durable=value', None, 'undefined']
            assert db(browser) == 'durable-value'
            save('reopen_' + str(generation + 1), {'host_pid':pid, 'cookie':True, 'local_storage':True, 'indexed_db':True, 'fresh_document':True})
        owner.rpc('chromium.close', chromium=browser)
        save('distinct_browser_processes', pids)
    finally:
        owner.close()


if __name__ == '__main__':
    raise SystemExit(main(exercise, __doc__, test_origin=True))
