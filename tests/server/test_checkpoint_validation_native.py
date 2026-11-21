#!/usr/bin/env python3
"""Native CLI rejection of damaged checkpoints using a real captured document.

All reads/writes use a fresh private output directory. No frontend is launched.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cli', type=Path, required=True)
    p.add_argument('--seed', type=Path, required=True)
    p.add_argument('--artifacts', type=Path, required=True)
    args = p.parse_args(); out = args.artifacts.resolve(); out.mkdir(parents=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'CODEX_', 'CLAUDE_'))}
    history = out / 'history'
    env['GRAFFITTY_CHECKPOINT_DIR'] = str(history)
    for kind in ['CONFIG', 'STATE', 'DATA', 'CACHE']:
        env['XDG_' + kind + '_HOME'] = str(out / kind.lower())
    seed = args.seed.read_bytes(); document = json.loads(seed)
    valid = out / 'valid.json'; valid.write_bytes(seed)
    def call(*values):
        return subprocess.run([str(args.cli.resolve()), 'checkpoint', *values], env=env, capture_output=True, text=True, timeout=30)
    def prepare():
        result = call('restore', '--prepare-only', '--checkpoint', str(valid))
        assert result.returncode == 0, result.stderr
        prepared = Path(json.loads(result.stdout)['prepared'])
        assert json.loads(prepared.read_text())['windows'][0]['chromiums'] == document['windows'][0]['chromiums']
        return prepared
    prepared = prepare()
    baseline = {str(f.relative_to(history)):hashlib.sha256(f.read_bytes()).hexdigest() for f in history.rglob('*') if f.is_file()}
    cases = [('truncated', '{"version":1,', 'EOF')]
    def case(name, mutate, diagnostic):
        value = copy.deepcopy(document); mutate(value)
        cases.append((name, json.dumps(value), diagnostic))
    case('unsupported_version', lambda d:d.update(version=999), 'unsupported checkpoint version')
    case('empty_windows', lambda d:d.update(windows=[]), 'invalid windows')
    case('invalid_geometry', lambda d:d['windows'][0].update(size=[0, 700]), 'geometry')
    case('duplicate_id', lambda d:d['windows'][0]['chromiums'][0].update(id=d['windows'][0]['panes'][0]['id']), 'duplicate pane ID')
    case('missing_owner', lambda d:d['windows'][0]['chromiums'][0].update(owner=999999), 'chromium owner')
    case('invalid_url', lambda d:d['windows'][0]['chromiums'][0].update(urls=['javascript:alert(1)']), 'chromium pages')
    case('empty_pages', lambda d:d['windows'][0]['chromiums'][0].update(urls=[]), 'chromium pages')
    results = []
    for name, content, diagnostic in cases:
        path = out / (name + '.json'); path.write_text(content)
        for command in [('restore', '--prepare-only', '--checkpoint'), ('save', '--input')]:
            result = call(*command, str(path))
            record = {'case':name, 'operation':command[0], 'exit':result.returncode, 'stderr':result.stderr}
            results.append(record)
            (out / 'checks.json').write_text(json.dumps(results, indent=2))
            assert result.returncode != 0 and diagnostic.lower() in result.stderr.lower(), record
            assert valid.read_bytes() == seed
            current = {str(f.relative_to(history)):hashlib.sha256(f.read_bytes()).hexdigest() for f in history.rglob('*') if f.is_file()}
            assert current == baseline, 'Rejected checkpoint modified recovery history'
    assert prepared.exists()
    prepare()
    (out / 'result.json').write_text(json.dumps({'status':'pass', 'platform':sys.platform, 'rejections':len(results), 'valid_restore_before_and_after':True, 'cli_sha256':hashlib.sha256(args.cli.read_bytes()).hexdigest(), 'seed_sha256':hashlib.sha256(seed).hexdigest()}, indent=2))
    print(sys.platform, len(results), 'rejections passed; valid recovery preserved')


if __name__ == '__main__':
    main()
