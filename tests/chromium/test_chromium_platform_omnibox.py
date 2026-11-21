#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Test how Graffitty.tabs.classify resolves address-bar text.

Chrome and Alloy both use the page's Chrome profile.

- Scheme-less hosts use Chrome's URL fixup.
- Search terms use the profile's default search engine.
- The server rejects results outside HTTP and HTTPS.

The profile supplies the search URL before any request. Internet access
is needed to load the results page.
"""
import json
from test_chromium_platform_isolation import Workspace
from test_chromium_platform_stress import main, evaluate, eventually


def exercise(matrix, out, descriptor):
    fixture = json.loads((out/'owner/fixture.json').read_text())
    origin = fixture['origin_url']
    w = Workspace(descriptor, 'omnibox')
    results = {}
    try:
        page, _ = w.page(origin)
        def navigate(text):
            ticket = w.rpc('chromium.command', chromium=page, action='tab-navigate', args={'text': text})['ticket']
            return eventually(lambda: w.rpc('chromium.result', chromium=page, ticket=ticket), 'navigate result', 20)
        def href():
            return evaluate(w.rpc, page, 'location.href')
        host = origin.split('://', 1)[1].rstrip('/')
        # Scheme-less host:port gets http (Chrome's URL fixup), not a search.
        r = navigate(host + '/second?x=1'); assert 'error' not in r, r
        results['scheme-less host:port'] = eventually(lambda: (h := href()).startswith(origin.rstrip('/') + '/second') and h, 'host fixup')
        # Plain words become a search with the profile's default engine.
        r = navigate('graffitty omnibox test'); assert 'error' not in r, r
        results['words search'] = eventually(lambda: (h := href()) and 'graffitty' in h and 'omnibox' in h and not h.startswith(origin) and h, 'search', 30)
        r = navigate('about:blank'); assert 'error' not in r, r
        results['about:blank'] = eventually(lambda: href() == 'about:blank' and 'about:blank', 'blank')
        for text in ('chrome://settings', 'file:///etc/hosts'):
            r = navigate(text)
            assert 'error' in r and 'http' in json.dumps(r['error']), (text, r)
            results[text] = r['error']
        assert href() == 'about:blank'
    finally:
        (out/'omnibox.json').write_text(json.dumps(results, indent=2)); print(json.dumps(results, indent=2), flush=True)
        w.close()


if __name__ == '__main__':
    raise SystemExit(main(exercise, __doc__, test_origin=True))
