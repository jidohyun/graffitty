"""Reuse the existing node-demo fixtures while rebuilding its live workspace."""
import os
from pathlib import Path
import sys

root = Path(os.environ['DEMO_RUNTIME'])
kind = sys.argv[1]
cli = os.environ['GRAFFITTY_BIN']
chapter = (root / 'launch-chapter').read_text()
if kind == 'systemone':
    args = ['dev', 'systemone-mock', '--scenario', str(root / 'decisions.json'),
            '--config', str(root / 'systemone-settings.json')]
else:
    config = kind
    if chapter == 'watcher':
        config = 'watcher-' + kind
    if chapter == 'parallel':
        if kind == 'claude':
            counter = root / 'claude-count'
            n = int(counter.read_text()) if counter.exists() else 0
            counter.write_text(str(n + 1))
            config = ['A', 'B', 'reviewer'][n]
        else:
            config = 'C'
    args = ['dev', kind + '-mock', '--config', str(root / (config + '.json'))]
os.execv(cli, [cli, *args])
