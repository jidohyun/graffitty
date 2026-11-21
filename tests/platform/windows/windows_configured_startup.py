"""Rendered configured Godot startup on a private Windows desktop."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from windows_protocol_actions_e2e import ROOT, dashboard, private_station
import windows_private_desktop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--tabs-only', action='store_true')
    args = parser.parse_args()
    directory = args.evidence.resolve()
    if args.worker:
        private_station()
        env = dict(os.environ)
        env['GRAFFITTY_INPUT_EVIDENCE'] = str(directory)
        env['GRAFFITTY_REPLAY_FRESH_SESSION'] = '1'
        if args.tabs_only: env['GRAFFITTY_CONFIG_TABS_ONLY'] = '1'
        with dashboard.PrivateServer(env, directory, None) as owner:
            with (directory/'replay.log').open('wb') as log:
                result = subprocess.run([dashboard.GODOT, '--path', str(args.project.resolve()), '--script',
                    str(ROOT/'tests/llm-e2e/suites/godot/integration/replays/configured-startup.gd'), '--',
                    '--config='+str(directory/'first.toml'), '--config='+str(directory/'second.toml'),
                    '--cwd='+str(directory/'configured cwd')], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=60)
            (directory/'owner-build.json').write_text(json.dumps({'path':str(owner.binary),'sha256':hashlib.sha256(owner.binary.read_bytes()).hexdigest()}))
        return result.returncode
    directory.mkdir(parents=True, exist_ok=False)
    (directory/'configured cwd').mkdir()
    config = directory/'config/graffitty'
    config.mkdir(parents=True)
    (config/'client.toml').write_text('[window]\nmax_fps = 73\n[terminal]\nfont_size = 17\n[tiling]\ngap = 31.0\n[world]\npath = "bistro"\n',encoding='utf-8')
    (directory/'first.toml').write_text('[window]\ninactive_max_fps = 19\n[terminal]\nfont_size = 21\n',encoding='utf-8')
    (directory/'second.toml').write_text('[terminal]\nfont_size = 23\n',encoding='utf-8')
    (config/'server.toml').write_text('[terminal]\nshell=["pwsh.exe", "-NoLogo", "-NoProfile"]\nlogin_shell=false\nshell_integration=false\n[terminal.font]\nsize=23\n[terminal.environment]\nACCEPTANCE_LITERAL_CONFIG="$(Write-Output MUST_NOT_EXECUTE); café 한글"\n',encoding='utf-8')
    sources = list(config.iterdir()) + [directory/'first.toml',directory/'second.toml']
    hashes = {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    env = {k:v for k,v in os.environ.items() if not k.startswith(('CODEX_','CLAUDE_'))}
    for kind in ('CONFIG','STATE','CACHE','DATA'): env['XDG_'+kind+'_HOME']=str(directory/kind.lower())
    report = {'status':'FAIL'}
    try:
        command = [sys.executable,'-X','utf8',__file__,'--worker','--project',str(args.project.resolve()),'--evidence',str(directory)]
        if args.tabs_only: command.append('--tabs-only')
        report['scope'] = 'new-tab-gap' if args.tabs_only else 'configured-startup'
        report['isolation'] = windows_private_desktop.run(command,env=env,cwd=ROOT,log=directory/'worker.log',timeout=75)
        log = (directory/'replay.log').read_text(encoding='utf-8',errors='replace')
        report['checks'] = dashboard.CHECK.findall(log)
        assert report['isolation']['exit_code']==0 and 'CONFIGURED_STARTUP_REPLAY_PASS' in log, log[-4000:]
        assert not any(line.lstrip().startswith(('ERROR:','SCRIPT ERROR:','WARNING:')) for line in log.splitlines()), log
        assert hashes == {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        report.update(status='PASS',unchanged_sources=hashes)
    except Exception as error: report['error']=str(error)
    extension=args.project.resolve()/'addons/graffitty/bin/libgraffitty.windows.x86_64.dll'
    report['extension']={'path':str(extension),'sha256':hashlib.sha256(extension.read_bytes()).hexdigest()}
    (directory/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report,indent=2))
    return report['status']!='PASS'


if __name__ == '__main__': sys.exit(main())
