"""Read the actual source transcript reference received by the Claude mock."""
import json
import os
from pathlib import Path

folder = Path(os.environ['XDG_STATE_HOME']) / 'graffitty/recording-sessions'
incoming = []
for path in folder.glob('*.jsonl'):
    for line in path.read_text().splitlines():
        record = json.loads(line)
        if record.get('type') != 'user':
            continue
        for part in record.get('message', {}).get('content', []):
            text = part.get('text', '')
            if '\nPayload (JSON): ' in text:
                event = json.loads(text.split('\nPayload (JSON): ', 1)[1])
                incoming.append(event)
event = max(incoming, key=lambda e: e['created'])
reference = next(s for s in event['sessions'] if s['provider'] == 'codex')
path = Path(reference['path'])
checkpoint = reference['checkpoint']['byte_offset']
records = [json.loads(line) for line in path.read_bytes()[:checkpoint].decode().splitlines()]
assert records, 'Empty source session'
print('Read session file: ' + str(path))
print(f'Completion checkpoint: {checkpoint} bytes; {len(records)} records.')
print('Verified the sender session contains the specification and implementation turn.')
Path(os.environ['DEMO_RUNTIME'], 'received-completion.json').write_text(json.dumps(event, indent=2))
