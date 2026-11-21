#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Native profile template ownership, copied storage and independent mutations."""
import json
from test_chromium_platform_isolation import Workspace
from test_chromium_platform_stress import main, evaluate, eventually, sample


def exercise(matrix, out, descriptor):
    directory = matrix.remote + '/' + out.name if matrix.args.platform == 'windows' else str(out / 'owner')
    if matrix.args.platform == 'windows':
        matrix.copy(out / 'live-fixture.json', directory + '/fixture.json', download=True)
        fixture = json.loads((out / 'live-fixture.json').read_text())
    else:
        fixture = json.loads((out / 'owner/fixture.json').read_text())
    url = fixture['origin_url']; profile = directory + '/template'
    owner = Workspace(descriptor, 'template-owner'); results = {}

    def page(**params):
        result = owner.rpc('chromium.create', url=url, **params)
        browser = result['chromium']; sid = int(browser[1:])
        owner.client.until(lambda: any(b['id'] == sid and b['state'].get('chromiumId', -1) > 0 for b in owner.client.topology.get('chromiums', [])))
        eventually(lambda: evaluate(owner.rpc, browser, 'document.title') == 'Isolation fixture', 'Template page did not load')
        state = next(b['state'] for b in owner.client.topology['chromiums'] if b['id'] == sid)
        return browser, state['pid'], result

    def close(browser, pid):
        owner.rpc('chromium.close', chromium=browser)
        eventually(lambda: all(p['pid'] != pid for p in sample(matrix, out)['descendants']), 'Browser did not finish closing')

    def storage(browser):
        return evaluate(owner.rpc, browser, "[localStorage.getItem('template-value'),document.cookie]")

    def save(name):
        results[name] = True
        (out / 'templates.json').write_text(json.dumps(results, indent=2))
        print(out.name, name, 'pass', flush=True)

    try:
        source, pid, _ = page(profile=profile)
        assert evaluate(owner.rpc, source, "localStorage.setItem('template-value','original');document.cookie='template=original; Max-Age=3600; Path=/';true")
        rejected = owner.call('chromium.create', url=url, profile_template=profile)
        assert rejected['type'] != 'ack' and 'in use' in json.dumps(rejected), rejected
        assert storage(source) == ['original', 'template=original']
        save('live_template_rejected_without_affecting_owner')
        close(source, pid)
        copies = []
        for _ in range(2):
            browser, pid, result = page(profile_template=profile)
            assert result['temporary_profile'], result
            assert storage(browser) == ['original', 'template=original']
            copies.append((browser, pid))
        save('copies_inherit_durable_storage')
        assert evaluate(owner.rpc, copies[0][0], "localStorage.setItem('template-value','changed');document.cookie='template=changed; Max-Age=3600; Path=/';true")
        assert storage(copies[0][0]) == ['changed', 'template=changed']
        assert storage(copies[1][0]) == ['original', 'template=original']
        save('concurrent_copies_are_independent')
        for browser, pid in copies:
            close(browser, pid)
        source, pid, _ = page(profile=profile)
        assert storage(source) == ['original', 'template=original']
        close(source, pid)
        save('original_template_unchanged_after_copy_mutation_and_close')
    finally:
        owner.close()


if __name__ == '__main__':
    raise SystemExit(main(exercise, __doc__, test_origin=True))
