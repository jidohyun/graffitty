"""Frozen agent replies and Decisions responses; UI and graph transport stay real."""
import json
from pathlib import Path
import sys

# SystemOne routes one question. The Protocol chapter reuses Claude for its own prompt.
PROMPT = 'What does HTTP 429 mean?'
ROUTE = 'claude'
PROTOCOL_PROMPT = 'What is HTTP?'
QUESTION = 'Route by task: questions to Claude, code changes to Codex.'
OUTPUTS = [
    {'id': 'claude', 'name': 'Claude', 'description': 'Questions', 'color': '#89ddbd'},
    {'id': 'codex', 'name': 'Codex', 'description': 'Code changes', 'color': '#bda9ff'},
]

def write(out):
    base = {'directory': '/home/demo', 'animation_clock': str(out/'animation-clock'),
            'scenario_clock': str(out/'animation-clock'), 'char_ms': 12, 'tip': '',
            'completion': {'elapsed_ms': 3000, 'completed_at': '2:30 PM'}}
    think = {'type': 'think', 'text': 'Answering the question', 'ms': 1200}
    agents = {
        'claude': {'model': 'Claude Sonnet', 'title': 'Claude', 'turns': [
            {'prompt': PROMPT, 'steps': [think],
             'response': 'HTTP 429 means Too Many Requests. Wait before retrying.'},
            {'prompt': PROTOCOL_PROMPT, 'steps': [think],
             'response': 'HTTP is the protocol chromiums use to request web pages.'}]},
        # Codex is the route JEV does not choose; it stays idle on camera.
        'codex': {'model': 'GPT-6-Astra', 'title': 'Codex', 'turns': []},
    }
    for key, agent in agents.items():
        (out/f'{key}.json').write_text(json.dumps({**base, **agent}, indent=2)+'\n')
    (out/'decisions.json').write_text(json.dumps({'delay_ms':750,'animation_clock':str(out/'animation-clock'),
        'decisions':[{'prompt':PROMPT,'answer':{'type':'choice','choice':ROUTE}}]},indent=2)+'\n')
    # The node starts from saved settings, already applied with its two output ports.
    (out/'systemone-settings.json').write_text(json.dumps({'provider':'openrouter','model':'~typesafe/jev-latest',
        'name':'SystemOne JEV','icon':'⚖','question':QUESTION,'mode':'choice','outputs':OUTPUTS,
        'threshold':0.5,'endpoint':'','input':'.text'},indent=2,ensure_ascii=False)+'\n')
    (out/'routing.json').write_text(json.dumps({'prompt':PROMPT,'route':ROUTE,'outputs':OUTPUTS},indent=2)+'\n')

if __name__ == '__main__': write(Path(sys.argv[1]).resolve())
