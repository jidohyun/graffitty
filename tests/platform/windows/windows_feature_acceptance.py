"""Compose focused Windows fixtures; each result keeps its own evidence."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
GROUPS = {
    'launch-policy': [('checkpoint','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/launch-policy-seed.gd','--followup-replay','tests/llm-e2e/suites/godot/integration/replays/launch-policy-fresh.gd','--timeout','120']),
                      ('controls','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/session-limit-controls.gd']),
                      ('powershell-51','windows_private_replay.py',['--shell','powershell-51','--replay','tests/llm-e2e/suites/godot/integration/replays/powershell-semantics.gd'])],
    'workspace-controls': [('drops-monitor','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/workspace-drops-monitor.gd']),
                           ('chromium','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/chromium-monitor.gd']),
                           ('messages-fit','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/font-dialog-fit.gd'])],
    'fonts': [('controls','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/font-controls.gd']),
              ('raster','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/font-raster.gd','--timeout','150']),
              ('metrics','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/font-metrics-ligatures.gd','--timeout','150']),
              ('recovery','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/font-recovery.gd']),
              ('graphemes','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/font-grapheme.gd'])],
    'windows': [('transfer','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/local-window-transfer.gd']),
                ('undo','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/window-layout-undo.gd']),
                ('remote-return','windows_private_replay.py',['--remote-owner','--replay','tests/llm-e2e/suites/godot/integration/replays/remote-window-return.gd'])],
    'tab-windows': [('controls','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/tab-window-controls.gd']),
                    ('remote-return','windows_private_replay.py',['--remote-owner','--replay','tests/llm-e2e/suites/godot/integration/replays/remote-window-return.gd'])],
    'status-strips': [('layout','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/status-strips.gd']),
                      ('lifecycle','windows_private_replay.py',['--replay','tests/llm-e2e/suites/godot/integration/replays/status-lifecycle.gd'])],
    'session-defaults': [('defaults', 'windows_private_replay.py', ['--replay','tests/llm-e2e/suites/godot/integration/replays/session-defaults.gd']),
                         ('fallback', 'windows_private_replay.py', ['--replay','tests/llm-e2e/suites/godot/integration/replays/session-fallback.gd'])],
    'configuration': [('validation', 'windows_config_validation.py', []),
                      ('startup', 'windows_configured_startup.py', []),
                      ('new-tabs', 'windows_configured_startup.py', ['--tabs-only'])],
    'effects': [('controls', 'windows_effects_e2e.py', []),
                ('pixels', 'windows_effects_e2e.py', ['--pixels']),
                ('camera', 'windows_effects_e2e.py', ['--camera']),
                ('isolation', 'windows_effects_e2e.py', ['--isolation'])],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=GROUPS, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--project', type=Path, default=ROOT/'frontends/godot/project')
    args = parser.parse_args()
    directory = args.evidence.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    report = {'status':'BLOCKED', 'cases':{}, 'scope':'Automated Windows assertions; captures require visual review'}
    if os.name != 'nt':
        report['reason'] = 'Windows ConPTY and private window station required'
    else:
        for name, script, flags in GROUPS[args.suite]:
            command = [sys.executable, '-X', 'utf8', str(Path(__file__).resolve().with_name(script)), '--project', str(args.project.resolve()),
                       '--evidence', str(directory/name), *flags]
            with (directory/(name+'.log')).open('wb') as log:
                result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=180)
            path = directory/name/'report.json'
            report['cases'][name] = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {'status':'FAIL','reason':'No fixture report'}
            if result.returncode or report['cases'][name]['status'] != 'PASS': break
        report['unexecuted'] = [name for name, _, _ in GROUPS[args.suite] if name not in report['cases']]
        report['status'] = 'PASS' if not report['unexecuted'] and all(case['status']=='PASS' for case in report['cases'].values()) else 'FAIL'
    (directory/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
    return report['status'] != 'PASS'


if __name__ == '__main__': sys.exit(main())
