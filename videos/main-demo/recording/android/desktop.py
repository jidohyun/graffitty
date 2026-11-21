#!/usr/bin/env python3
"""Record the shared Android UI on macOS, without an Android VM or phone."""
import argparse, importlib.machinery, importlib.util, json, os, shutil, subprocess, sys, tempfile, time
from pathlib import Path
from fixtures import prepare, run
ROOT = Path(__file__).resolve().parents[4]
sys.path[:0] = [str(ROOT/'tools'), str(ROOT/'tests/support'), str(ROOT/'videos/shared')]
from av1 import check_encoder, probe_av1
from e2e_background import prepare_background, clear_background, background_failures
from check_godot import failed
loader = importlib.machinery.SourceFileLoader('record_effects', str(ROOT/'videos/effects/recording/record.py'))
effects = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader)); loader.exec_module(effects)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--through-wiring', action='store_true')
p.add_argument('--manager-only', action='store_true', help='Record saved computers and connect one, reusing the accepted Android scenario afterward')
a = p.parse_args(); out = a.output.resolve(); out.mkdir(parents=True, exist_ok=False)
cli = Path(os.environ.get('GRAFFITTY_TEST_SERVER', ROOT / 'dist/bin/gft')).resolve()
if not cli.is_file(): raise RuntimeError('Build the current server with mise run cli:build before recording')
fixture, container = prepare(out)
runtime = tempfile.TemporaryDirectory(prefix='gft-mobile-', dir='/tmp')
owner = Path(runtime.name)
server = None
other_server = None
try:
    project = effects.stage_project(out, '1968x1968')
    # Match Android's opaque display capability when rendering its UI on macOS.
    project_config = project/'project.godot'
    project_config.write_text(project_config.read_text().replace(
        'window/per_pixel_transparency/allowed=true', 'window/per_pixel_transparency/allowed=false'))
    (project/'llm-e2e').symlink_to(ROOT/'tests/llm-e2e', target_is_directory=True)
    (project/'tests').unlink()
    shutil.copytree(ROOT/'frontends/godot/project/tests', project/'tests')
    for name in ['scenario.gd', 'android_ui.gd']:
        path = project/'tests/client_scenarios'/name
        path.write_text(path.read_text().replace('../../../../../tests/llm-e2e/replay/background.gd', 'res://llm-e2e/replay/background.gd'))
    for name in ['codex', 'claude']:
        path = fixture/(name+'.json'); config = json.loads(path.read_text())
        config.update(animation_clock=str(out/'animation-clock'), scenario_clock=str(out/'animation-clock'))
        path.write_text(json.dumps(config))
    (out/'demo-config.json').write_text(json.dumps({'through_wiring': a.through_wiring, 'manager_only': a.manager_only}))
    if a.manager_only:
        shutil.copy2(ROOT/'videos/main-demo/composition/demo-audio.json', out/'demo-audio.json')
    env = {k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'CODEX_', 'SLACK_'))}
    clear_background(env)
    state = Path('/Users/Shared/demo')/('mobile-'+out.parent.name+'-'+out.name); state.mkdir(parents=True, exist_ok=True)
    env.update(DEMO_RUNTIME=str(fixture), XDG_CONFIG_HOME=str(out/'config'), XDG_STATE_HOME=str(state),
               XDG_DATA_HOME=str(out/'data'), XDG_CACHE_HOME=str(out/'cache'), GRAFFITTY_MOVIE_PAUSED='1',
               GRAFFITTY_FFMPEG=check_encoder(), GRAFFITTY_AV1_CRF='15', GRAFFITTY_AV1_PRESET='8')
    client_config = out/'config/graffitty/client.toml'
    client_config.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(Path(__file__).with_name('client.toml'), client_config)
    with (out/'server.log').open('w') as server_log:
        server = subprocess.Popen([str(cli), 'server', '--listen', '127.0.0.1:0',
            '--connection', str(owner/'server.json'), '--auth-file', str(owner/'auth.json'),
            '--shell', str(fixture/'shell.sh')], env=env, stdout=server_log, stderr=server_log)
        deadline = time.monotonic()+60
        while not (owner/'server.json').exists():
            if server.poll() is not None or time.monotonic()>deadline: raise RuntimeError('Private demo server failed to start')
            time.sleep(.1)
        shutil.copy2(owner/'server.json', out/'server.json')
        # A fresh server starts empty. Prepare the live workspace off camera,
        # as an existing saved computer would have it, through the current CLI.
        subprocess.run([str(cli), 'session', 'new', '-d', '-c', str(fixture)],
            env={**env, 'GRAFFITTY_SERVER_DESCRIPTOR': str(owner/'server.json')}, check=True,
            stdout=server_log, stderr=server_log)
        if a.manager_only:
            other_server = subprocess.Popen([str(cli), 'server', '--listen', '127.0.0.1:0',
                '--connection', str(owner/'laptop-server.json'), '--auth-file', str(owner/'laptop-auth.json'),
                '--shell', str(fixture/'shell.sh')], env={**env, 'XDG_STATE_HOME': str(state/'laptop')},
                stdout=server_log, stderr=server_log)
            deadline = time.monotonic()+60
            while not (owner/'laptop-server.json').exists():
                if other_server.poll() is not None or time.monotonic()>deadline: raise RuntimeError('Second private demo server failed to start')
                time.sleep(.1)
            shutil.copy2(owner/'laptop-server.json', out/'laptop-server.json')
            subprocess.run([str(cli), 'session', 'new', '-d', '-c', str(fixture)],
                env={**env, 'GRAFFITTY_SERVER_DESCRIPTOR': str(owner/'laptop-server.json')}, check=True,
                stdout=server_log, stderr=server_log)
            choices = []
            for filename, label in [('server.json', 'Workstation'), ('laptop-server.json', 'Laptop')]:
                choices.append({**json.loads((out/filename).read_text()), 'name': label, 'remember': False})
            (out/'manager-settings.json').write_text(json.dumps(choices))
        for script in ['DesktopDemo.gd', 'ManagerDemo.gd'] if a.manager_only else ['DesktopDemo.gd']:
            checked = subprocess.run([shutil.which('godot'), '--headless', '--path', str(project), '--check-only',
                '--script', 'res://videos/main-demo/recording/android/'+script], env=env, capture_output=True, text=True)
            (out/(script+'.check.log')).write_text((checked.stdout+checked.stderr).replace(str(out), '<take>').replace(str(ROOT), '<repo>'))
            if failed(checked.returncode, checked.stdout+checked.stderr): raise RuntimeError('Recorder syntax check failed: '+script)
        command = [shutil.which('godot'), *prepare_background(env,out), '--path', str(project), '--language', 'en',
            '--write-movie', str(out/'device-raw.mp4'), '--fixed-fps', '60', '--quit-after', '18000',
            '--script', 'res://videos/main-demo/recording/android/DesktopDemo.gd', '--', '--touch-controls',
            '--demo-output='+str(out)]
        with (out/'godot.log').open('w') as log:
            result = subprocess.run(command, env=env, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        log = (out/'godot.log').read_text().replace(str(out), '<take>').replace(str(ROOT), '<repo>')
        (out/'godot.log').write_text(log)
        if failed(result.returncode,log) or 'DESKTOP_MOBILE_DEMO_PASS' not in log: raise RuntimeError('Desktop mobile demo failed; inspect godot.log')
        capture = json.loads((out/'capture.json').read_text())
        assert not capture['failures'] and not background_failures(out)
        probe, stream = probe_av1(out/'device-raw.mp4')
        assert [stream['width'],stream['height']]==[1968,1968]
        probe['format']['filename'] = 'device-raw.mp4'
        (out/'probe.json').write_text(json.dumps(probe,indent=2))
        (out/'screen-crop.json').write_text(json.dumps({'source_display':[1968,2184], 'app_rect':[0,90,1968,1968],
            'system_bars_removed':False, 'capture_backend':'desktop-mobile', 'system_bars_simulated':True},indent=2))
        print(out/'device-raw.mp4')
finally:
    if other_server is not None:
        other_server.terminate()
        try: other_server.wait(timeout=10)
        except subprocess.TimeoutExpired: other_server.kill(); other_server.wait()
    if server is not None:
        server.terminate()
        try: server.wait(timeout=10)
        except subprocess.TimeoutExpired: server.kill(); server.wait()
    subprocess.run(['podman','--connection','podman-machine-default','rm','-f',container],capture_output=True)
    runtime.cleanup()
