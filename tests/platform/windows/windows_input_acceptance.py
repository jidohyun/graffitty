"""Godot Windows input acceptance groups, with separately reviewable captures."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
GROUPS = {
    'input': ['keys', 'wheel', 'wheel-protocol', 'settings', 'mouse-controls'],
    'mouse': ['mouse', 'mouse-protocol', 'mouse-controls', 'mouse-bistro'],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=GROUPS, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--project', type=Path)
    args = parser.parse_args()
    args.evidence = args.evidence.resolve()
    args.evidence.mkdir(parents=True, exist_ok=False)
    report = {'status': 'BLOCKED', 'suite': args.suite, 'cases': {},
              'scope': 'Automated native viewport/PTY assertions; review captures separately. Physical devices are not certified.'}
    if os.name != 'nt':
        report['reason'] = 'This adapter requires Windows ConPTY; other Godot platforms need their native fixture.'
        code = 2
    else:
        code = 0
        for case in GROUPS[args.suite]:
            directory = args.evidence / case
            command = [sys.executable, '-X', 'utf8', str(ROOT/'tests/platform/windows/windows_input_routing_e2e.py'),
                       '--case', case, '--evidence', str(directory)]
            if args.project:
                command += ['--project', str(args.project.resolve())]
            with (args.evidence/(case+'.log')).open('w', encoding='utf-8') as log:
                completed = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            path = directory/'report.json'
            report['cases'][case] = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {'status': 'fail', 'reason': 'Fixture produced no report'}
            if completed.returncode or report['cases'][case]['status'] != 'pass':
                code = 1
                break
        report['status'] = 'PASS' if code == 0 else 'FAIL'
        report['unexecuted'] = [case for case in GROUPS[args.suite] if case not in report['cases']]
    (args.evidence/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
    return code


if __name__ == '__main__':
    sys.exit(main())
