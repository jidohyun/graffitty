#!/usr/bin/env python3
"""Record Neovim answers into neovim.json (tracked in DVC); cargo test replays it.

Run from any directory: python3 path/to/record.py
The reference disables Matchit's % mapping to exercise the built-in motion.
"""
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
GROUPS = ('motion', 'yank', 'object', 'visual', 'search')


def pack(inputs, version):
    commands, outcomes, buffers = [], [], []
    command_ids, outcome_ids, buffer_ids = {}, {}, {}
    for cases, references in inputs:
        for c, r in zip(cases, references, strict=True):
            assert c['id'] == r['id']
            assert r['err'] is None, (c, r['err'])
            parts = c.get('cmds', [c['keys']])
            copy = any(re.match(r'^\d*[yY]', part) for part in parts)
            command = (c['keys'], copy)
            if command not in command_ids:
                command_ids[command] = len(commands)
                commands.append({'keys': command[0], 'copy': copy})
            if copy:
                result = r['reg']
                if r['regtype'] == 'V' and result.endswith('\n'):
                    result = result[:-1]
                # Terminal copy convention: trim row-end spaces and omit the
                # linewise register's final newline, preserving empty rows.
                result = '\n'.join(line.rstrip(' ') for line in result.split('\n')) or None
            else:
                result = r['cursor']
            encoded = json.dumps(result, ensure_ascii=False)
            if encoded not in outcome_ids:
                outcome_ids[encoded] = len(outcomes)
                outcomes.append(result)
            lines = tuple(c['lines'])
            if lines not in buffer_ids:
                buffer_ids[lines] = len(buffers)
                buffers.append({'lines': c['lines'], 'cases': []})
            buffers[buffer_ids[lines]]['cases'].append([
                *c['cursor'], command_ids[command], outcome_ids[encoded]])
    return {'neovim': version, 'commands': commands, 'outcomes': outcomes, 'buffers': buffers}


def read(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def main():
    version = subprocess.check_output(['nvim', '--version'], text=True).splitlines()[0]
    inputs = []
    with tempfile.TemporaryDirectory(prefix='copy-mode-nvim-') as directory:
        tmp = Path(directory)
        for group in (*GROUPS, 'targeted', 'random'):
            cases, refs = tmp / f'{group}.jsonl', tmp / f'{group}.ref.jsonl'
            if group in GROUPS:
                cases.write_bytes(subprocess.check_output([sys.executable, str(ROOT / 'exhaustive.py'), group]))
            else:
                cases.write_bytes((ROOT / f'{group}.jsonl').read_bytes())
            subprocess.run(['nvim', '--headless', '--clean', '-l', str(ROOT / 'reference.lua'), str(cases), str(refs)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            inputs.append((read(cases), read(refs)))
    destination = ROOT / 'neovim.json'
    destination.write_text(json.dumps(pack(inputs, version), ensure_ascii=False, separators=(',', ':')) + '\n')
    print(f'{destination}: {sum(len(c) for c, _ in inputs)} cases from {version}')


if __name__ == '__main__':
    main()
