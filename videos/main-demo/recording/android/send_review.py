import json, os, subprocess
b=os.environ['GRAFFITTY_BIN']
def rpc(m,p):
 r=json.loads(subprocess.check_output([b,'rpc',m,'--params',json.dumps(p)]));return r.get('result',r)
g=rpc('graph.list',{})
nodes=g['nodes']
if isinstance(nodes,dict): nodes=[dict(v,node=k) for k,v in nodes.items()]
target=next(n.get('node',n.get('pane')) for n in nodes if n.get('manifest',{}).get('name')=='Slack Send')
text='Review: 3 spec requirements are missing.\n1. Responsive mobile navigation\n2. Contact form validation\n3. Keyboard-accessible focus states\nPlease complete these before shipping.'
r=rpc('graph.send',{'to':target,'text':text})
if 'error' in r: raise RuntimeError(r)
# Queue acknowledgment is not delivery; AndroidDemo records the notification
# cue after the DELIVERED log is visible in the terminal.
from pathlib import Path
clock = Path(os.environ['DEMO_RUNTIME']).parent / 'animation-clock'
if clock.exists():
    (clock.parent / 'slack-queued.json').write_text(json.dumps({'capture_seconds': int(clock.read_text()) / 1000}))
print('Queued review for Slack: 3 missing requirements.')
