#!/usr/bin/env python3
"""Write the sign-up builds and the scripted Claude/Codex sessions for one take.

Five builds converge on a passing E2E suite: 1, 4, 5, 5 (a regression), then
6 of 6. Every result comes from tools.py driving the real Chromium pane.
"""
import json, sys
from pathlib import Path

PAGE = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Sign up</title><style>
body{margin:0;font:24px/1.4 -apple-system,system-ui,sans-serif;background:#eef1f6;color:#1d2330;
 display:grid;place-items:center;min-height:100vh}
main{width:540px;background:#fff;border-radius:18px;padding:30px 40px 26px;box-shadow:0 10px 30px #0002}
h1{margin:0 0 6px;font-size:36px}
label{display:block;font-weight:600;margin-top:12px}
input{width:100%;box-sizing:border-box;font:inherit;padding:8px 14px;margin-top:4px;border:2px solid #c9ced8;border-radius:10px}
.error{color:#c62828;font-size:21px;min-height:29px}
button{margin-top:14px;width:100%;font:inherit;font-weight:700;padding:10px;border:0;border-radius:10px;background:#3b6df0;color:#fff}
#welcome{margin-top:12px;color:#1b7f3b;font-weight:700;min-height:34px;text-align:center}
footer{position:fixed;right:18px;bottom:10px;color:#7a8194;font-size:20px}
</style></head><body><main><h1>Create your account</h1>
<form id="signup" novalidate>
<label for="email">Email</label><input id="email" autocomplete="off"><div class="error" id="email-error"></div>
<label for="password">Password</label><input id="password" type="password"><div class="error" id="password-error"></div>
<button id="submit">Sign up</button><div id="welcome"></div></form></main>
<footer>build {build}</footer>
<script>
const form = document.getElementById('signup');
form.addEventListener('submit', event => {
  event.preventDefault();
{body}
});
</script></body></html>
'''

STRICT = r'/^[^@\s]+@[^@\s]+\.[^@\s]+$/'
LOOSE = r'/@/'


def validation(pattern, field, clears):
    # Without `clears`, a message is only ever written, never removed.
    show = ("const show = (id, message) => { document.getElementById(id).textContent = message; if (message) ok = false; };"
            if clears else
            "const show = (id, message) => { if (message) { document.getElementById(id).textContent = message; ok = false; } };")
    return f'''  const user = {{ email: form.email.value.trim() }};
  const password = form.password.value;
  let ok = true;
  {show}
  show('email-error', !user.email ? 'Email is required' : !{pattern}.test(user.email) ? 'Enter a valid email' : '');
  show('password-error', password.length < 8 ? 'Use at least 8 characters' : '');
  document.getElementById('welcome').textContent = ok ? `Welcome, ${{user.{field}}}!` : '';'''


BUILDS = {
    1: '  // TODO: validate and welcome the user',
    2: validation(STRICT, 'name', clears=False),
    3: validation(STRICT, 'email', clears=False),
    4: validation(LOOSE, 'email', clears=True),
    5: validation(STRICT, 'email', clears=True),
}
EXPECTED_PASSES = {1: 1, 2: 4, 3: 5, 4: 5, 5: 6}

PLACEHOLDER = '''<!doctype html><html><head><meta charset="utf-8"><title>Sign up</title></head>
<body style="margin:0;display:grid;place-items:center;min-height:100vh;background:#eef1f6;
 font:28px -apple-system,system-ui,sans-serif;color:#7a8194">Waiting for the first build…</body></html>
'''

CLAUDE_PROMPT = 'Build the sign-up page from spec.md'
CODEX_PROMPT = 'Test each build in Chromium and send failures to Claude.'

# What Claude shows for each build; the files themselves come from BUILDS.
FIXES = {
    1: ('Reading spec.md', 2400, 'app/index.html', '',
        '<form id="signup">\n  <input id="email"> <input id="password" type="password">\n  <button>Sign up</button>\n</form>',
        'Build 1 is ready: an email and password sign-up form.'),
    2: ('Fixing 5 failing tests', 2000, 'app/signup.js', '// TODO: validate and welcome the user',
        "show('email-error', !user.email ? 'Email is required' : …);\nshow('password-error', password.length < 8 ? …);\nwelcome.textContent = `Welcome, ${user.name}!`;",
        'Build 2: added validation messages and a welcome message.'),
    3: ('Fixing the welcome message', 1600, 'app/signup.js', 'welcome.textContent = `Welcome, ${user.name}!`;',
        'welcome.textContent = `Welcome, ${user.email}!`;',
        'Build 3: the welcome message now shows the email.'),
    4: ('Clearing stale errors', 1500, 'app/signup.js',
        'if (message) { error.textContent = message; }\nconst valid = /^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/;',
        'error.textContent = message;\nconst valid = /@/;',
        'Build 4: errors now clear after a successful sign-up.'),
    5: ('Restoring the email check', 1400, 'app/signup.js', 'const valid = /@/;',
        'const valid = /^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$/;',
        'Build 5: restored the stricter email check.'),
}


def main(out: Path):
    (out / 'builds').mkdir()
    (out / 'app').mkdir()
    for build, body in BUILDS.items():
        (out / 'builds' / f'build-{build}.html').write_text(PAGE.replace('{build}', str(build)).replace('{body}', body))
    (out / 'app/index.html').write_text(PLACEHOLDER)
    (out / 'expected.json').write_text(json.dumps(EXPECTED_PASSES))
    tools = [sys.executable, str(out / 'tools.py')]
    url = (out / 'url').read_text().strip()
    base = {'directory': '/home/demo', 'animation_clock': str(out / 'animation-clock'),
            'scenario_clock': str(out / 'animation-clock'), 'char_ms': 10, 'tip': '', 'real_tool_calling': True,
            'completion': {'elapsed_ms': 6000, 'completed_at': '2:30 PM'}}

    claude = []
    for build, (thought, ms, path, before, after, response) in FIXES.items():
        turn = {'steps': [
            {'type': 'think', 'text': thought, 'ms': ms},
            {'type': 'edit', 'path': path, 'before': before, 'after': after, 'preview_lines': 4, 'ms': 500},
            {'type': 'tool', 'name': 'Bash', 'input': 'npm run build', 'command': tools + ['publish', str(build)], 'ms': 300},
        ], 'response': response}
        if build == 1:
            turn['prompt'] = CLAUDE_PROMPT
        claude.append(turn)
    (out / 'claude.json').write_text(json.dumps({**base, 'turns': claude}))

    codex = [{'prompt': CODEX_PROMPT, 'steps': [
        {'type': 'think', 'text': 'Opening the app', 'ms': 500},
        {'type': 'tool', 'name': 'exec_command', 'input': f'gft chromium new --url {url} --side above',
         'command': tools + ['browser'], 'ms': 300},
    ], 'response': 'Ready. Chromium is open above me; I’ll test every build Claude finishes.'}]
    for build, passes in EXPECTED_PASSES.items():
        steps = [{'type': 'think', 'text': f'Testing build {build}', 'ms': 500},
                 {'type': 'tool', 'name': 'exec_command', 'input': 'npm run e2e', 'command': tools + ['e2e', str(build)],
                  'preview_lines': 8, 'ms': 300}]
        if passes < 6:
            steps.append({'type': 'tool', 'name': 'exec_command', 'input': f"gft graph send --to %1 --text 'E2E on build {build}: {passes}/6 passed. Please fix: …'",
                          'command': tools + ['send', str(build)], 'ms': 300})
            response = f'Build {build}: {passes}/6 passed. Sent the failures to Claude.'
        else:
            response = f'Build {build}: all 6 E2E tests pass. Nothing to send.'
        codex.append({'steps': steps, 'response': response})
    (out / 'codex.json').write_text(json.dumps({**base, 'model': 'GPT-6-Astra medium', 'turns': codex}))


if __name__ == '__main__':
    main(Path(sys.argv[1]))
