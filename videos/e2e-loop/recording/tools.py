#!/usr/bin/env python3
"""Real side effects behind the scripted agents.

The mock Claude and Codex panes call this through their tool steps:

    tools.py publish N   copy sign-up build N to the served app
    tools.py browser     open the app in a Chromium pane above Codex
    tools.py e2e N       drive that Chromium through the E2E suite
    tools.py send N      send build N's failures to Claude over the graph

It runs beside the take, where record.py placed app/, builds/ and url.
"""
import json, os, shutil, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
GFT = os.environ['GRAFFITTY_BIN']
URL = (HERE / 'url').read_text().strip()


def gft(*args):
    result = subprocess.run([GFT, *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f'gft {args[0]} {args[1]} failed: {result.stderr or result.stdout}')
    return json.loads(result.stdout) if result.stdout.strip() else {}


def publish(build):
    shutil.copyfile(HERE / 'builds' / f'build-{build}.html', HERE / 'app/index.html')
    print(f'Built the sign-up page (build {build}) → app/index.html')


def browser():
    reply = gft('chromium', 'new', '--url', URL, '--side', 'above')
    chromium = reply.get('result', reply).get('chromium')
    if not chromium:
        raise SystemExit(f'No Chromium pane in {reply}')
    (HERE / 'chromium').write_text(chromium)
    print(f'Opened {URL} in Chromium {chromium}')


def js(expression):
    reply = gft('chromium', 'eval', '--target', (HERE / 'chromium').read_text(), '--expression', expression)
    if not isinstance(reply, dict) or 'result' not in reply:
        raise SystemExit(f'Unexpected chromium eval reply: {reply}')
    return reply['result']


def load(build, test):
    gft('chromium', 'navigate', '--target', (HERE / 'chromium').read_text(), '--url', f'{URL}?build={build}&test={test}')
    for _ in range(50):
        if js("document.readyState === 'complete' && !!document.querySelector('h1')"):
            return
        time.sleep(.05)


def submit(email, password):
    js(f"(() => {{ const f = document.getElementById('signup'); f.email.value = {json.dumps(email)};"
       f" f.password.value = {json.dumps(password)}; return true; }})()")
    time.sleep(.35)
    js("document.getElementById('submit').click(), true")
    time.sleep(.45)
    return json.loads(js("JSON.stringify({email: document.getElementById('email-error').textContent,"
                         " password: document.getElementById('password-error').textContent,"
                         " welcome: document.getElementById('welcome').textContent})"))


def quoted(text, missing):
    return f'saw "{text}"' if text else missing


def suite(build):
    """Each test returns (passed, detail shown when it fails)."""
    def renders():
        load(build, 1)
        ok = js("document.querySelector('h1')?.textContent === 'Create your account' && !!document.getElementById('email') && !!document.getElementById('password')")
        return ok, 'form is missing'

    def requires_email():
        load(build, 2)
        state = submit('', 'longenough')
        return state['email'] == 'Email is required', quoted(state['email'], 'no error shown')

    def rejects_invalid_email():
        load(build, 3)
        state = submit('ada@', 'longenough')
        return state['email'] == 'Enter a valid email', quoted(state['email'] or state['welcome'], 'no error shown')

    def requires_long_password():
        load(build, 4)
        state = submit('ada@example.com', 'short')
        return state['password'] == 'Use at least 8 characters', quoted(state['password'], 'no error shown')

    def welcomes():
        load(build, 5)
        state = submit('ada@example.com', 'longenough')
        return state['welcome'] == 'Welcome, ada@example.com!', quoted(state['welcome'], 'no welcome message')

    def clears_errors():
        load(build, 6)
        submit('', '')
        state = submit('ada@example.com', 'longenough')
        stale = state['email'] or state['password']
        return bool(state['welcome']) and not stale, f'"{stale}" still shown' if stale else 'no welcome message'

    return [('shows the sign-up form', renders), ('requires an email', requires_email),
            ('rejects an invalid email', rejects_invalid_email), ('needs 8+ character passwords', requires_long_password),
            ('welcomes a new user', welcomes), ('clears errors after success', clears_errors)]


def e2e(build):
    print(f'Running 6 E2E tests on build {build} in Chromium', flush=True)
    results = []
    for name, test in suite(build):
        passed, detail = test()
        results.append({'name': name, 'passed': bool(passed), 'detail': '' if passed else detail})
        print(f'  ✓ {name}' if passed else f'  ✗ {name}: {detail}', flush=True)
    failed = sum(not r['passed'] for r in results)
    print(f'{len(results) - failed} passed, {failed} failed', flush=True)
    (HERE / f'results-{build}.json').write_text(json.dumps(results, indent=2))
    # The mock agent ends its turn on a failing tool; failures are reported, not raised.
    return 0


def send(build):
    results = json.loads((HERE / f'results-{build}.json').read_text())
    failures = [r for r in results if not r['passed']]
    text = (f'E2E on build {build}: {len(results) - len(failures)}/{len(results)} passed. Please fix:\n'
            + '\n'.join(f'- {r["name"]}: {r["detail"]}' for r in failures))
    nodes = gft('rpc', 'graph.list', '--params', '{}')
    nodes = nodes.get('result', nodes)['nodes']
    if isinstance(nodes, dict):
        nodes = [dict(node, node=key) for key, node in nodes.items()]
    claude = next(n.get('node', n.get('pane')) for n in nodes if n.get('provider') == 'claude')
    # The same CLI a real agent uses; its JSON reply is the visible output, as for real Codex.
    result = subprocess.run([GFT, 'graph', 'send', '--to', claude, '--text', '-'], input=text, capture_output=True, text=True)
    if result.returncode or '"error"' in result.stdout:
        raise SystemExit(f'gft graph send failed: {result.stderr or result.stdout}')
    (HERE / f'sent-{build}.json').write_text(json.dumps({'to': claude, 'text': text}, indent=2))
    print(result.stdout.strip())


if __name__ == '__main__':
    command, *rest = sys.argv[1:]
    if command == 'publish': publish(int(rest[0]))
    elif command == 'browser': browser()
    elif command == 'e2e': sys.exit(e2e(int(rest[0])))
    elif command == 'send': send(int(rest[0]))
    else: raise SystemExit(f'Unknown command {command}')
