"""Verify actual GGP receipt and create the demo's playable podcast artifact."""
import json
import os
from pathlib import Path
import subprocess
import wave

root = Path(os.environ['DEMO_RUNTIME'])
events = []
for path in (Path(os.environ['XDG_STATE_HOME']) / 'graffitty/recording-sessions').glob('*.jsonl'):
    for line in path.read_text().splitlines():
        record = json.loads(line)
        if record.get('type') != 'user':
            continue
        for part in record.get('message', {}).get('content', []):
            text = part.get('text', '')
            if '\nPayload (JSON): ' in text:
                event = json.loads(text.split('\nPayload (JSON): ', 1)[1])
                if event.get('text') == (root / 'email.txt').read_text():
                    events.append(event)
assert len(events) == 1, 'Expected one real email message from the watcher'
script = ("Here is your inbox briefing. Product Team confirmed the launch for Friday at ten A M. "
          "Your action item is to review the release notes by Thursday. That's your quick update.")
subprocess.run(['say', '-o', str(root / 'podcast.aiff'), script], check=True)
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(root / 'podcast.aiff'),
                '-ar', '24000', '-ac', '1', str(root / 'inbox-podcast.wav')], check=True)
with wave.open(str(root / 'inbox-podcast.wav')) as audio:
    duration = audio.getnframes() / audio.getframerate()
assert duration > 3
(root / 'received-email.json').write_text(json.dumps({'event': events[0], 'podcast': 'inbox-podcast.wav',
    'duration': duration}, indent=2) + '\n')
print('Created inbox-podcast.wav from the new email.')
