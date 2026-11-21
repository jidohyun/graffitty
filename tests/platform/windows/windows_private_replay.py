"""Run one real-owner Godot replay on an isolated Windows window station."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from contextlib import contextmanager
from windows_protocol_actions_e2e import ROOT, dashboard, private_station
import windows_private_desktop


@contextmanager
def remote_owner(env, directory, binary, enabled):
    if not enabled:
        yield
        return
    scratch = directory/'remote-owner'
    scratch.mkdir()
    descriptor = scratch/'server.json'
    with (scratch/'server.log').open('wb') as log:
        process = subprocess.Popen([str(binary), 'server', '--listen', '127.0.0.1:0',
                                    '--connection', str(descriptor), '--auth-file', str(scratch/'auth.json')],
                                   env=env, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        try:
            deadline = time.monotonic()+15
            while not descriptor.exists() and process.poll() is None and time.monotonic()<deadline:
                time.sleep(.03)
            if not descriptor.exists(): raise RuntimeError('Private remote owner did not start')
            env['GRAFFITTY_REMOTE_DESCRIPTOR'] = str(descriptor)
            yield
        finally:
            if process.poll() is None:
                subprocess.run(['taskkill.exe','/PID',str(process.pid),'/T','/F'],capture_output=True,timeout=15)
            process.wait(timeout=5)
            (scratch/'cleanup.json').write_text(json.dumps({'pid':process.pid,'exit_code':process.returncode}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--replay', type=Path, required=True)
    parser.add_argument('--project', type=Path, default=dashboard.GODOT_ROOT)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--timeout', type=int, default=90)
    parser.add_argument('--remote-owner', action='store_true')
    parser.add_argument('--shell', choices=['powershell-51','powershell-7'], default='powershell-7')
    parser.add_argument('--followup-replay', type=Path, help='Launch a fresh frontend against the same live private owner after the first replay')
    args = parser.parse_args()
    directory = args.evidence.resolve()
    replay = args.replay.resolve()
    stages = [replay] + ([args.followup_replay.resolve()] if args.followup_replay else [])
    if args.worker:
        private_station()
        env = dict(os.environ)
        env['GRAFFITTY_INPUT_EVIDENCE'] = str(directory)
        env['GRAFFITTY_INPUT_PYTHON'] = sys.executable
        env['GRAFFITTY_REPLAY_SHARED_EVIDENCE'] = str(directory)
        template = next(c for c in dashboard.cases() if c['suite']=='windows' and c['name']==args.shell)
        template = dict(template)
        template['server_config'] = '[terminal]\nshell=' + json.dumps([template['shell'], '-NoLogo', '-NoProfile']) + '\nlogin_shell=false\nshell_integration=true\n'
        dashboard.configure_owner(template, env, directory)
        with dashboard.PrivateServer(env, directory, None) as owner, remote_owner(env, directory, owner.binary, args.remote_owner):
            for index, stage in enumerate(stages):
                stage_directory = directory if index == 0 else directory/'fresh-frontend'
                stage_directory.mkdir(exist_ok=True)
                env['GRAFFITTY_INPUT_EVIDENCE'] = str(stage_directory)
                with (stage_directory/'replay.log').open('wb') as log:
                    # configure_owner supplies the shell and -NoProfile arguments.
                    result = subprocess.run([dashboard.GODOT, '--path', str(args.project.resolve()), '--script', str(stage)],
                        env=env, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
                if result.returncode: break
            (directory/'owner-build.json').write_text(json.dumps({'path':str(owner.binary),'sha256':hashlib.sha256(owner.binary.read_bytes()).hexdigest()}))
        return result.returncode
    directory.mkdir(parents=True, exist_ok=False)
    keep = {'GRAFFITTY_TEST_SERVER','GRAFFITTY_TEST_GODOT','GRAFFITTY_GODOT','GRAFFITTY_CHROMIUM_HOST'}
    env = {k:v for k,v in os.environ.items() if not k.startswith(('CODEX_','CLAUDE_')) and (not k.startswith('GRAFFITTY_') or k in keep)}
    for kind in ('CONFIG','STATE','CACHE','DATA'): env['XDG_'+kind+'_HOME']=str(directory/kind.lower())
    report = {'status':'FAIL','replay':str(replay),'scope':'Native projected events and private raw PTY; inspect captures separately'}
    try:
        command = [sys.executable,'-X','utf8',__file__,'--worker','--project',str(args.project.resolve()),'--replay',str(replay),'--evidence',str(directory),'--timeout',str(args.timeout)]
        if args.remote_owner: command.append('--remote-owner')
        command.extend(['--shell',args.shell])
        if args.followup_replay: command.extend(['--followup-replay',str(args.followup_replay.resolve())])
        report['isolation'] = windows_private_desktop.run(command,env=env,cwd=ROOT,log=directory/'worker.log',timeout=args.timeout*len(stages)+15)
        report['checks'] = []
        report['stages'] = []
        for index, stage in enumerate(stages):
            stage_directory = directory if index == 0 else directory/'fresh-frontend'
            log = (stage_directory/'replay.log').read_text(encoding='utf-8',errors='replace')
            report['checks'].extend(dashboard.CHECK.findall(log))
            marker = stage.stem.upper().replace('-', '_') + '_REPLAY_PASS'
            assert report['isolation']['exit_code']==0 and marker in log, log[-4000:]
            assert not any(line.lstrip().startswith(('ERROR:','SCRIPT ERROR:','WARNING:','Unicode parsing error')) for line in log.splitlines()), log
            report['stages'].append({'replay':str(stage),'sha256':hashlib.sha256(stage.read_bytes()).hexdigest(),'evidence':str(stage_directory)})
        report['status']='PASS'
    except Exception as error: report['error']=str(error)
    extension=args.project.resolve()/'addons/graffitty/bin/libgraffitty.windows.x86_64.dll'
    report['extension']={'path':str(extension),'sha256':hashlib.sha256(extension.read_bytes()).hexdigest()}
    report['replay_sha256']=hashlib.sha256(replay.read_bytes()).hexdigest()
    (directory/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
    return report['status']!='PASS'


if __name__ == '__main__': sys.exit(main())
