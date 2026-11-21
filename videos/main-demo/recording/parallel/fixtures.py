import json,sys
from pathlib import Path
out=Path(sys.argv[1])
# The replay freezes this clock while another prepared session is on camera.
base={'directory':'/home/demo','animation_clock':str(out/'parallel-clock'),'scenario_clock':str(out/'parallel-clock'),'char_ms':10,'tip':'','real_tool_calling':True,'completion':{'elapsed_ms':12000,'completed_at':'2:30 PM'}}
# Workers start several seconds apart; stagger durations so the overview shows
# concurrent work, then successive completions without a long idle wait.
for i,(spec,ms,reply) in enumerate([
 ('A',15000,'Implemented spec A: a compact landing page with clear navigation.'),
 ('B',12000,'Implemented spec B: responsive navigation, accessible controls, and validated forms.'),
 ('C',9000,'Implemented spec C: a visual landing page with animated feature sections.')]):
 config={**base,'turns':[{'prompt':'Implement with spec '+spec,'steps':[{'type':'think','text':'Implementing spec '+spec,'ms':ms},{'type':'edit','path':'src/spec-'+spec+'.tsx','before':'','after':'export default function Spec'+spec+'() {\n  return <main>Implementation '+spec+'</main>;\n}','ms':800}],'response':reply}]}
 if spec=='C':config['model']='GPT-6-Astra medium'
 (out/(spec+'.json')).write_text(json.dumps(config))
prompt='Graffitty will send you combined implementation of three different specs. Once you receive, review which is the best'
(out/'reviewer.json').write_text(json.dumps({**base,'turns':[
 {'prompt':prompt,'steps':[{'type':'think','text':'Preparing comparison','ms':500}],'response':'Ready. I’ll wait for all three implementations before comparing them.'},
 {'steps':[{'type':'tool','name':'Read','input':'All three sessions from the combined payload','command':[sys.executable,str(out/'review_payload.py')],'ms':1400},{'type':'think','text':'Comparing implementations','ms':1000}], 'response':'Spec B is the best implementation.\n\nA: clear and compact, but limited functionality.\nB: strongest completeness, accessibility, and validation.\nC: polished visuals, but fewer practical features.\n\nRecommendation: use B as the foundation.'}]}))
