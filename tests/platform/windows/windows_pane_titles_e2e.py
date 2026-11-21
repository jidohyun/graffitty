"""Exercise visible Godot pane titles under a verified Windows token, in both PowerShell versions."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/godot",)]
import test_dashboard as dashboard

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--elevated', choices=['true', 'false'], required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=False)
    expected = args.elevated == 'true'
    if os.name != 'nt' or bool(ctypes.windll.shell32.IsUserAnAdmin()) != expected:
        (args.evidence / 'report.json').write_text(json.dumps({'status': 'BLOCKED', 'reason': 'Launch from the requested Windows elevation context; this test never elevates itself.'}))
        return 2
    original = dashboard.configure_owner
    def configure(case, env, directory):
        original(case, env, directory)
        env['GRAFFITTY_TEST_EVIDENCE'] = str(directory / 'evidence')
        (directory / 'evidence').mkdir()
        env['GRAFFITTY_TEST_ELEVATED'] = '1' if expected else '0'
        env['GRAFFITTY_TEST_PS_VERSION'] = '5.1' if case['shell'] == 'powershell.exe' else '7.'
    dashboard.configure_owner = configure
    template = next(c for c in dashboard.cases() if c['suite'] == 'windows' and c['name'] == 'powershell-7')
    results = {}
    for shell in ['powershell.exe', 'pwsh.exe']:
        for integration in [False, True]:
            name = shell + ('-hooks' if integration else '-plain')
            case = dict(template, name='pane-titles-' + name, shell=shell,
                        replay=ROOT / 'tests/llm-e2e/suites/godot/windows/replays/pane-titles.gd',
                        server_config='[terminal]\nshell=' + json.dumps([shell, '-NoLogo', '-NoProfile']) + '\nshell_integration=' + str(integration).lower() + '\n')
            results[name] = dashboard.test_one(case, '', headful=True)
            report = {'status': 'PASS' if all(r['status'] == 'pass' for r in results.values()) else 'FAIL', 'elevated': expected, 'results': results}
            (args.evidence / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
            print(name, results[name]['status'], results[name].get('failed', []), flush=True)
    return 0 if report['status'] == 'PASS' else 1

if __name__ == '__main__':
    sys.exit(main())
