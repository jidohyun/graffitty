#!/usr/bin/env python3
"""Record the implement → E2E → fix loop in a fresh, offline desktop session.

    python3 videos/e2e-loop/recording/record.py --output videos/e2e-loop/assets/takes/<name>

Claude and Codex are the dev mocks; builds, Chromium, the E2E run and the
feedback delivery are real.

Set GRAFFITTY_TEST_SERVER to a snapshot of `gft` when other work may rebuild
target/ during the take.
"""
import argparse, functools, http.server, importlib.machinery, importlib.util, json, os, shlex, shutil
import socketserver, subprocess, sys, threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tests/support')]
from av1 import check_encoder, probe_av1
from e2e_background import prepare_background, clear_background, background_failures
from e2e_server import PrivateServer
loader = importlib.machinery.SourceFileLoader('record_effects', str(ROOT / 'videos/effects/recording/record.py'))
effects = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(effects)

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)


def run(command, **kw):
    return subprocess.run([str(x) for x in command], check=True, **kw)


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_): pass
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


# The app is served from localhost so the address bar shows no host paths.
server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), functools.partial(Quiet, directory=str(out / 'app')))
server.daemon_threads = True
(out / 'url').write_text(f'http://localhost:{server.server_address[1]}/\n')
shutil.copy2(HERE / 'tools.py', out / 'tools.py')
run([sys.executable, HERE / 'fixtures.py', out])
threading.Thread(target=server.serve_forever, daemon=True).start()

shutil.copy2(ROOT / 'apps/server/shell-integration/integration.sh', out / 'integration.sh')
(out / '.zshrc').write_text('HISTFILE=/dev/null\nPROMPT="%~ $ "\nRPROMPT=""\nPROMPT_EOL_MARK=""\nunsetopt PROMPT_SP\n'
                            'source /recording/integration.sh\n'
                            + '\n'.join(f'{kind}() {{ print {kind} > /recording/launch-$DEMO_KEY; exit; }}' for kind in ['claude', 'codex'])
                            + '\nprintf "\\033[2J\\033[H"\n')
name = 'graffitty-e2e-loop-' + str(os.getpid())
podman = ['podman', '--connection', 'podman-machine-default']
run(podman + ['run', '-d', '--name', name, '--network=none', '--volume', str(out) + ':/recording',
              'localhost/graffitty-effects:4'], capture_output=True)
try:
    run(podman + ['exec', name, 'sh', '-ec', 'useradd -m demo; chmod 777 /recording'])
    run(podman + ['cp', ROOT / 'apps/server/terminfo/xterm-ghostty.terminfo', name + ':/tmp/ghostty.terminfo'])
    run(podman + ['exec', name, 'tic', '-x', '/tmp/ghostty.terminfo'])
    # The zsh prompt runs in the container; the agents it launches run on the host
    # so their tools can reach the workspace, Chromium and the local app.
    (out / 'launch.py').write_text('import os,sys\n'
                                   "kind=sys.argv[1]\n"
                                   "os.execv(os.environ['GRAFFITTY_BIN'],['gft','dev',kind+'-mock','--config',os.path.join(os.environ['DEMO_RUNTIME'],kind+'.json')])\n")
    shell = out / 'shell.sh'
    shell.write_text('#!/bin/sh\nexport DEMO_KEY=$$\n'
                     + shlex.join(['env', 'XDG_CONFIG_HOME=' + str(Path.home() / '.config'), *podman, 'exec', '-it',
                                   '-e', 'ZDOTDIR=/recording', '-e', 'DEMO_KEY', '-w', '/home/demo', name,
                                   'runuser', '-u', 'demo', '--', '/bin/zsh', '-d', '-i'])
                     + '\nkind=$(cat "$DEMO_RUNTIME/launch-$DEMO_KEY" 2>/dev/null)\n'
                     + 'exec ' + shlex.quote(sys.executable) + ' "$DEMO_RUNTIME/launch.py" "$kind"\n')
    shell.chmod(0o700)
    project = effects.stage_project(out, '2400x1500')
    (project / 'llm-e2e').symlink_to(ROOT / 'tests/llm-e2e', target_is_directory=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'CODEX_', 'SLACK_'))}
    clear_background(env)
    state = Path('/Users/Shared/demo') / ('e2e-loop-' + out.name)
    state.mkdir(parents=True, exist_ok=True)
    env.update(DEMO_RUNTIME=str(out), XDG_CONFIG_HOME=str(out / 'config'), XDG_STATE_HOME=str(state),
               XDG_DATA_HOME=str(out / 'data'), XDG_CACHE_HOME=str(out / 'cache'), GRAFFITTY_FFMPEG=check_encoder(),
               GRAFFITTY_MOVIE_PAUSED='1', GRAFFITTY_AV1_CRF='15', GRAFFITTY_AV1_PRESET='8')
    command = [shutil.which('godot'), *prepare_background(env, out), '--path', str(project), '--language', 'en',
               '--write-movie', str(out / 'footage.mp4'), '--fixed-fps', '60', '--quit-after', '15000',
               '--script', 'res://videos/e2e-loop/recording/LoopDemo.gd', '--', '--record', '--tabs=1',
               '--shell=' + str(shell), '--cwd=' + str(state), '--bg=#4a4d54', '--opacity=1', '--no-focus-skip',
               '--demo-output=' + str(out)]
    (out / 'command.json').write_text(json.dumps(command, indent=2))
    with PrivateServer(env, out, str(shell)):
        with (out / 'godot.log').open('w') as log:
            run(command, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    metadata = json.loads((out / 'capture.json').read_text())
    assert not metadata['failures'], metadata['failures']
    assert not background_failures(out)
    expected = json.loads((out / 'expected.json').read_text())
    for build, passes in expected.items():
        results = json.loads((out / f'results-{build}.json').read_text())
        assert sum(r['passed'] for r in results) == passes, (build, results)
        assert (out / f'sent-{build}.json').exists() == (passes < 6), build
    probe, stream = probe_av1(out / 'footage.mp4')
    (out / 'probe.json').write_text(json.dumps(probe, indent=2))
    print(out / 'footage.mp4')
finally:
    run(podman + ['rm', '-f', name], capture_output=True)
    server.shutdown()
