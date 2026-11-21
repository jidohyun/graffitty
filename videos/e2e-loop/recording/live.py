#!/usr/bin/env python3
"""Run the loop scenario with real Claude Code and Codex, to compare with the mocks.

    CLAUDE_CONFIG_DIR=<claude account> CODEX_HOME=<codex account> \
      python3 videos/e2e-loop/recording/live.py --output <dir>

Not footage: Godot runs in real time without a movie.

The layout, wiring and prompts are the recorded demo's; the agents do the
real work in a scratch project (spec.md, e2e.md, app/ served on localhost).

Each agent gets a private home holding only a copy of the given account's
login, deleted afterwards. The output keeps the agents' final screens and
transcripts.
"""
import argparse, functools, http.server, importlib.machinery, importlib.util, json, os, shlex, shutil
import socketserver, subprocess, sys, tempfile, threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'tests/support'))
from e2e_background import prepare_background, clear_background
from e2e_server import PrivateServer


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


effects = load('record_effects', ROOT / 'videos/effects/recording/record.py')
runner = load('agent_e2e', ROOT / 'tests/agents/test_agent_e2e.py')

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--claude-model', default='sonnet')
parser.add_argument('--codex-model', default='gpt-6.1-sol')
parser.add_argument('--minutes', type=int, default=25, help='Stop waiting for the loop after this long')
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
# Agents' hooks and tools find `gft` on PATH, so the server binary must be named gft.
server_binary = Path(os.environ.get('GRAFFITTY_TEST_SERVER') or ROOT / 'target/release/gft').resolve()
if server_binary.name != 'gft':
    parser.error('GRAFFITTY_TEST_SERVER must point at a file named gft (its directory goes first on PATH)')


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


# Outside the repository: agents read CLAUDE.md/AGENTS.md from every parent directory.
work = Path('/Users/Shared/demo/e2e-loop-live') / out.name
(work / 'app').mkdir(parents=True)
(out / 'work').symlink_to(work, target_is_directory=True)
http_server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=str(work / 'app')))
http_server.daemon_threads = True
url = f'http://localhost:{http_server.server_address[1]}/'
threading.Thread(target=http_server.serve_forever, daemon=True).start()
(work / 'app/index.html').write_text((HERE / 'live/placeholder.html').read_text())
for name in ['spec.md', 'e2e.md']:
    (work / name).write_text((HERE / 'live' / name).read_text())
# Each agent reads its own role: AGENTS.md (Codex) tests, CLAUDE.md (Claude) implements.
for name in ['AGENTS.md', 'CLAUDE.md']:
    (work / name).write_text((HERE / 'live' / name).read_text().replace('{url}', url))

env = {k: v for k, v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'CODEX_', 'SLACK_', 'CLAUDE'))}
clear_background(env)
# Short paths: Codex's daemon socket lives in CODEX_HOME and must fit SUN_LEN.
scratch = Path(tempfile.mkdtemp(prefix='e2el-', dir='/tmp'))
homes = {name: scratch / name for name in ('claude', 'codex')}
for home in homes.values():
    home.mkdir(mode=0o700)
# Like a user's own launch: no traffic limits, which can switch off session messaging.
env.update(CLAUDE_CONFIG_DIR=str(homes['claude']), CODEX_HOME=str(homes['codex']), DISABLE_AUTOUPDATER='1',
           PATH=str(server_binary.parent) + os.pathsep + env.get('PATH', ''),
           GRAFFITTY_TEST_SERVER=str(server_binary))
secrets = []
try:
    secrets = runner.seed_auth(env, homes['codex'], homes['claude'], os.environ)
    runner.private_json(homes['claude'] / '.claude.json', {'hasCompletedOnboarding': True,
                        'projects': {work.as_posix(): {'hasTrustDialogAccepted': True}}})
    # The private home has no record of the one-time bypass-permissions consent.
    runner.private_json(homes['claude'] / 'settings.json', {'skipDangerousModePermissionPrompt': True})
    (homes['codex'] / 'config.toml').write_text(
        f'model = {json.dumps(args.codex_model)}\ncheck_for_update_on_startup = false\n'
        f'[projects.{json.dumps(str(work))}]\ntrust_level = "trusted"\n')
    for provider in ('claude', 'codex'):
        subprocess.run([str(server_binary), 'integrate', provider, '--apply'], cwd=work, env=env,
                       capture_output=True, timeout=30, check=True)
    commands = {
        'claude': [shutil.which('claude'), '--model', args.claude_model, '--dangerously-skip-permissions'],
        'codex': [shutil.which('codex'), '-m', args.codex_model, '--dangerously-bypass-approvals-and-sandbox'],
    }
    # A plain zsh with Graffitty's shell integration, which reports the cwd.
    shutil.copy2(ROOT / 'apps/server/shell-integration/integration.sh', out / 'integration.sh')
    (out / '.zshrc').write_text('HISTFILE=/dev/null\nPROMPT="%~ $ "\nRPROMPT=""\nPROMPT_EOL_MARK=""\n'
                                f'source {shlex.quote(str(out / "integration.sh"))}\ncd {shlex.quote(str(work))}\n')
    shell = out / 'shell.sh'
    shell.write_text('#!/bin/sh\nexport ZDOTDIR=' + shlex.quote(str(out)) + '\nexec /bin/zsh -i\n')
    shell.chmod(0o700)
    project = effects.stage_project(out, '2400x1500')
    (project / 'llm-e2e').symlink_to(ROOT / 'tests/llm-e2e', target_is_directory=True)
    state = out / 'state'
    env.update(DEMO_RUNTIME=str(out), XDG_CONFIG_HOME=str(out / 'config'), XDG_STATE_HOME=str(state),
               XDG_DATA_HOME=str(out / 'data'), XDG_CACHE_HOME=str(out / 'cache'),
               E2E_LOOP_LIVE=json.dumps({'claude': shlex.join(commands['claude']), 'codex': shlex.join(commands['codex']),
                                         'minutes': args.minutes}))
    command = [shutil.which('godot'), *prepare_background(env, out), '--path', str(project), '--language', 'en',
               '--script', 'res://videos/e2e-loop/recording/LoopDemo.gd', '--', '--live', '--tabs=1',
               '--shell=' + str(shell), '--cwd=' + str(work), '--bg=#4a4d54', '--opacity=1', '--no-focus-skip',
               '--demo-output=' + str(out)]
    # Claude deletes its session record on exit; keep copies while it runs (never .key files).
    watching = threading.Event()
    def keep_sessions():
        while not watching.wait(3):
            for record in (homes['claude'] / 'sessions').glob('*.json'):
                (out / 'claude-sessions').mkdir(exist_ok=True)
                shutil.copy2(record, out / 'claude-sessions' / record.name)
    threading.Thread(target=keep_sessions, daemon=True).start()
    with PrivateServer(env, out, str(shell)) as server:
        # Codex tools lose the pane token (Codex drops *TOKEN* variables) and find
        # their pane through the session server's default descriptor instead.
        default = state / 'graffitty/server.json'
        default.parent.mkdir(parents=True, exist_ok=True)
        # A private regular file is required (symlinks are rejected); the server
        # writes its descriptor once at startup.
        shutil.copy2(server.descriptor, default)
        default.chmod(0o600)
        with (out / 'godot.log').open('w') as log:
            subprocess.run(command, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                           timeout=args.minutes * 60 + 600)
    # Keep the transcripts beside the screens; credentials never leave the private homes.
    watching.set()
    for provider, folder in (('claude', 'projects'), ('codex', 'sessions')):
        source = homes[provider] / folder
        if source.is_dir():
            shutil.copytree(source, out / 'transcripts' / provider, dirs_exist_ok=True)
    print(out)
finally:
    if (homes['codex'] / 'app-server-control/app-server-control.sock').exists():
        subprocess.run([shutil.which('codex'), 'app-server', 'daemon', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
    runner.stop_private_codex_helpers(homes['codex'])
    shutil.rmtree(homes['codex'] / 'packages', ignore_errors=True)
    for path in secrets + [homes['claude'] / '.credentials.json', homes['codex'] / 'auth.json']:
        path.unlink(missing_ok=True)
    shutil.rmtree(scratch, ignore_errors=True)
    http_server.shutdown()
