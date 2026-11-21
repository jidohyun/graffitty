import json,os
from pathlib import Path
folder=Path(os.environ['XDG_STATE_HOME'])/'graffitty/recording-sessions'
events=[]
for path in folder.glob('*.jsonl'):
 for line in path.read_text().splitlines():
  record=json.loads(line)
  if record.get('type')!='user':continue
  for part in record.get('message',{}).get('content',[]):
   text=part.get('text','')
   if '\nPayload (JSON): ' in text:
    event=json.loads(text.split('\nPayload (JSON): ',1)[1])
    if event.get('payload',{}).get('type')=='parallel.completed':events.append(event)
assert len(events)==1, 'Expected exactly one combined delivery'
event=events[0]
assert len(event['payload']['inputs'])==3
assert len(event['sessions'])==3
prompts=[]
for reference in event['sessions']:
 path=Path(reference['path']); end=reference['checkpoint']['byte_offset']
 records=path.read_bytes()[:end].decode()
 assert 'Implement with spec ' in records
 prompts.append(next(spec for spec in 'ABC' if 'Implement with spec '+spec in records))
 print('Read spec '+prompts[-1]+' session: '+str(path))
assert sorted(prompts)==list('ABC')
print('Verified all 3 completed implementations and session checkpoints.')
Path(os.environ['DEMO_RUNTIME'],'received-combined.json').write_text(json.dumps(event,indent=2))
