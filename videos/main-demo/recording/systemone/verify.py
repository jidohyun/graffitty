#!/usr/bin/env python3
"""Check the recorded graph and actual mock transcript; freeze portable evidence."""
import argparse
import json
from pathlib import Path
import shutil

from fixtures import OUTPUTS, PROMPT, ROUTE


def verify(take):
    capture = json.loads((take/'capture.json').read_text())
    assert not capture['failures'], capture['failures']
    evidence = json.loads((take/'graph-evidence.json').read_text())
    route = evidence['route']
    assert route['output'] == ROUTE and route['prompt'] == PROMPT
    assert evidence['jev_title'] == 'SystemOne JEV'
    edges = evidence['edges']
    assert len(edges) == 3 and not any(e.get('read') for e in edges)
    settings = json.loads((take/'systemone-settings.json').read_text())
    assert settings['mode'] == 'choice' and settings['input'] == '.text'
    assert settings['model'] == '~typesafe/jev-latest' and settings['name'] == 'SystemOne JEV'
    assert [o['id'] for o in settings['outputs']] == [o['id'] for o in OUTPUTS]
    state = Path('/Users/Shared/demo')/('systemone-'+take.name)/'graffitty/recording-sessions'
    saved = take/'sessions'
    saved.mkdir(exist_ok=True)
    archived = saved/f'{ROUTE}.jsonl'
    if not archived.exists():
        node = evidence['nodes'][route['node']]
        transcript = Path(node.get('transcript_path', state/(node['session_id']+'.jsonl')))
        assert transcript.resolve().is_relative_to(state.resolve())
        shutil.copyfile(transcript, archived)
    rows = [json.loads(line) for line in archived.read_text().splitlines()]
    messages = [r.get('message',r.get('payload',{})) for r in rows]
    users = ['\n'.join(c.get('text','') for c in m.get('content',[])) for m in messages if m.get('role') == 'user']
    answers = ['\n'.join(c.get('text','') for c in m.get('content',[])) for m in messages if m.get('role') == 'assistant']
    assert len(users) == 1 and PROMPT in users[0], users
    assert any(answers), answers
    report = {'frames':capture['frames'], 'routing_edges':len(edges),
              'route':{'output':ROUTE, 'node':route['node'], 'prompt':PROMPT,
                       'transcript':str(archived.relative_to(take)), 'assistant_messages':len(answers)}}
    (take/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('take',type=Path)
    print(json.dumps(verify(parser.parse_args().take.resolve()),indent=2))
