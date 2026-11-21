#!/usr/bin/env python3
"""Record an email CLI fixture, real watcher, and real GGP delivery to Claude."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[4]
sys.path[:0] = [str(ROOT / 'tools'), str(ROOT / 'tests/support'), str(ROOT / 'videos/shared')]
from av1 import check_encoder, probe_av1
from e2e_background import prepare_background, clear_background, background_failures
from e2e_bistro import installed_bistro, link_bistro
from e2e_server import PrivateServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    spec = importlib.util.spec_from_file_location('effects', ROOT / 'videos/effects/recording/record.py')
    effects = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(effects)
    shutil.copy2(ROOT / 'examples/uppercase-node/node.py', out / 'node.py')
    shutil.copy2(ROOT / 'examples/watcher-node/node.py', out / 'watcher.py')
    shutil.copy2(Path(__file__).with_name('launch.py'), out / 'launch.py')
    subprocess.run([sys.executable, ROOT / 'videos/main-demo/recording/systemone/fixtures.py', out], check=True)
    shutil.copy2(ROOT / 'videos/main-demo/recording/parallel/review_payload.py', out / 'review_payload.py')
    subprocess.run([sys.executable, ROOT / 'videos/main-demo/recording/parallel/fixtures.py', out], check=True)
    subprocess.run([sys.executable, Path(__file__).with_name('fixtures.py'), out], check=True)
    shutil.copy2(ROOT / 'videos/main-demo/composition/demo-audio.json', out / 'demo-audio.json')
    (out / 'animation-clock').write_text('0')
    (out / 'pyproject.toml').write_text('[project]\nname="watcher-demo"\nversion="0.1.0"\nrequires-python=">=3.11"\ndependencies=["graffitty-graph-protocol"]\n[tool.uv.sources]\ngraffitty-graph-protocol={path=' + json.dumps(str(ROOT / 'python/libs/graffitty-graph-protocol')) + ',editable=true}\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'CODEX_', 'SLACK_'))}
    clear_background(env)
    env.update(XDG_CONFIG_HOME=str(out / 'config'), XDG_STATE_HOME=str(out / 'state'),
               XDG_DATA_HOME=str(out / 'data'), XDG_CACHE_HOME=str(out / 'cache'),
               ZDOTDIR=str(out), UV_PROJECT_ENVIRONMENT=str(out / 'venv'),
               GRAFFITTY_FFMPEG=check_encoder(), GRAFFITTY_MOVIE_PAUSED='1',
               GRAFFITTY_AV1_CRF='15', GRAFFITTY_AV1_PRESET='8')
    # Bistro is an installed world; expose it in the isolated data folder.
    link_bistro(out / 'data', installed_bistro())
    subprocess.run(['uv', 'sync', '--project', str(out)], env=env, check=True, capture_output=True)
    cli = Path(os.environ.get('GRAFFITTY_TEST_SERVER', ROOT / 'dist/bin/gft')).resolve()
    if not cli.is_file(): raise RuntimeError('Build the current server with mise run cli:build before recording')
    env['PATH'] = os.pathsep.join([str(out / 'bin'), str(cli.parent), env['PATH']])
    env.update(DEMO_RUNTIME=str(out), GRAFFITTY_BIN=str(cli))
    (out / '.zshrc').write_text('HISTFILE=/dev/null\nPROMPT="demo $ "\nRPROMPT=""\nPROMPT_EOL_MARK=""\nunsetopt PROMPT_SP\nbat() { command ' + shlex.quote(shutil.which('bat') or 'bat') + ' --style=plain --paging=never --color=always --theme=TwoDark "$@"; }\nprintf "\\033[2J\\033[H"\n')
    with (out / '.zshrc').open('a') as rc:
        launcher = shlex.join([sys.executable, str(out / 'launch.py')])
        rc.write(f'claude() {{ {launcher} claude; }}\ncodex() {{ {launcher} codex; }}\n')
        rc.write(f'gft() {{ if [[ $1 == node && $2 == systemone ]]; then {launcher} systemone; else command gft "$@"; fi; }}\n')
    shell = out / 'shell.sh'
    shell.write_text('#!/bin/sh\ncd ' + shlex.quote(str(out)) + '\nexec /bin/zsh -d -i\n')
    shell.chmod(0o700)
    project = effects.stage_project(out, '2400x1500')
    (project / 'llm-e2e').symlink_to(ROOT / 'tests/llm-e2e', target_is_directory=True)
    command = [shutil.which('godot'), *prepare_background(env, out), '--path', str(project),
               '--language', 'en', '--write-movie', str(out / 'footage.mp4'), '--fixed-fps', '60',
               '--quit-after', '36000', '--script', 'res://videos/main-demo/recording/watcher/WatcherDemo.gd',
               '--', '--record', '--node-sessions', '--tabs=1', '--shell=' + str(shell), '--cwd=' + str(out),
               '--plugin=bistro', '--world=3d',
               '--bg=#4a4d54', '--opacity=1', '--no-focus-skip', '--demo-output=' + str(out)]
    # Holder socket paths derive from the descriptor: keep them below macOS's
    # 104-byte limit even when the requested take directory is deeply nested.
    with tempfile.TemporaryDirectory(prefix='gft-watch-', dir='/tmp') as owner:
        # The inspector shows real fixture transcript paths on camera. Keep
        # those paths portable and free of the recording machine's username.
        env['XDG_STATE_HOME'] = str(Path(owner) / 'state')
        try:
            with PrivateServer(env, Path(owner), str(shell)):
                with (out / 'godot.log').open('w') as log:
                    subprocess.run(command, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                   check=True, timeout=1800)
        finally:
            shutil.copytree(Path(owner) / 'session-owner', out / 'session-owner',
                            ignore=shutil.ignore_patterns('*.sock'))
    capture = json.loads((out / 'capture.json').read_text())
    assert not capture['failures'], capture['failures']
    assert not background_failures(out), background_failures(out)
    evidence = json.loads((out / 'watcher-evidence.json').read_text())
    assert evidence['delivered'] and evidence['silent_before_email'] and evidence['claude_prepared']
    assert evidence['messages'] == 1
    assert evidence['podcast_created'] and json.loads((out / 'received-email.json').read_text())['duration'] > 3
    assert (out / 'node.py').read_bytes() == (ROOT / 'examples/watcher-node/node.py').read_bytes()
    probe, _ = probe_av1(out / 'footage.mp4')
    probe['format']['filename'] = 'footage.mp4'
    (out / 'probe.json').write_text(json.dumps(probe, indent=2) + '\n')
    log_path = out / 'godot.log'
    log_path.write_text(log_path.read_text().replace(str(out), '<take>').replace(str(ROOT), '<repo>'))
    # Keep the preceding reconstruction as internal evidence. Only the click on
    # the prepared Watcher session and the watcher chapter enter the accepted film.
    first = next(b['frame'] for b in capture['beats'] if b['action'] == 'Watcher: session click')
    chapter = out / 'watcher'
    chapter.mkdir()
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{first / 60:.9f}', '-i', str(out / 'footage.mp4'),
                    '-vf', 'setpts=PTS-STARTPTS',
                    '-frames:v', str(capture['frames'] - first), '-an', '-c:v', 'libx264',
                    '-crf', '15', '-preset', 'veryfast', str(chapter / 'footage.mp4')], check=True)
    sys.path.insert(0, str(ROOT / "videos/main-demo/composition"))
    from edit_decisions import session_navigation_span
    trimmed = {**capture, "session_navigation": session_navigation_span(capture, first, capture["frames"], -first), 'frames': capture['frames'] - first, 'source_frames': [first, capture['frames']],
               'beats': [{**b, 'frame': b['frame'] - first, 'seconds': (b['frame'] - first) / 60}
                         for b in capture['beats'] if b['frame'] >= first]}
    (chapter / 'capture.json').write_text(json.dumps(trimmed, indent=2) + '\n')
    for key in ['released_frame', 'received_frame', 'session_click_frame']:
        evidence[key] -= first
    (chapter / 'watcher-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    shutil.copy2(out / 'node.py', chapter / 'node.py')
    for name in ['received-email.json', 'inbox-podcast.wav', 'email.txt']:
        shutil.copy2(out / name, chapter / name)
    shutil.copy2(out / 'godot.log', chapter / 'godot.log')
    print(chapter / 'footage.mp4')


if __name__ == '__main__':
    main()
