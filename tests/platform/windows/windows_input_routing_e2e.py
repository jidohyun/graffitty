"""Private Windows raw-PTY configured-key acceptance; wheel/UI coverage is separate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(ROOT / d) for d in ("tests/godot",)]
import test_dashboard as dashboard


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--case", choices=('keys', 'mouse', 'mouse-protocol', 'wheel', 'wheel-protocol', 'settings', 'mouse-controls', 'mouse-bistro'), default='keys')
    parser.add_argument("--project", type=Path, default=dashboard.GODOT_ROOT,
                        help="Godot project, including an isolated extension staging project")
    args = parser.parse_args()
    args.evidence = args.evidence.resolve()
    args.evidence.mkdir(parents=True, exist_ok=False)
    dashboard.GODOT_ROOT = args.project.resolve()
    original = dashboard.configure_owner

    def configure(case, env, directory):
        original(case, env, directory)
        env['GRAFFITTY_INPUT_EVIDENCE'] = str(args.evidence)
        env['GRAFFITTY_INPUT_PYTHON'] = sys.executable

    dashboard.configure_owner = configure
    template = next(c for c in dashboard.cases() if c['suite'] == 'windows' and c['name'] == 'powershell-7')
    name = {'keys': 'input-routing', 'mouse': 'mouse-bindings', 'mouse-protocol': 'mouse-protocol', 'wheel': 'input-wheel', 'wheel-protocol': 'wheel-protocol', 'settings': 'input-settings', 'mouse-controls': 'mouse-controls', 'mouse-bistro': 'mouse-bistro'}[args.case]
    case = dict(template, suite='integration', name=name, timeout_seconds=90,
                replay=ROOT/('tests/llm-e2e/suites/godot/integration/replays/'+name+'.gd'))
    result = dashboard.test_one(case, '', headful=True)
    extension = dashboard.GODOT_ROOT/'addons/graffitty/bin/libgraffitty.windows.x86_64.dll'
    result['extension'] = {'path': str(extension), 'sha256': hashlib.sha256(extension.read_bytes()).hexdigest()}
    (args.evidence/'report.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'pass' else 1


if __name__ == '__main__':
    sys.exit(main())
