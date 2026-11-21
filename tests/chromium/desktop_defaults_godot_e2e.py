"""Godot private Chromium default/temporary/alternate profile acceptance."""
import argparse,json,os,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/godot",)]
import test_dashboard as dashboard

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--evidence',type=Path,required=True)
 args=parser.parse_args();args.evidence=args.evidence.resolve()
 args.evidence.mkdir(parents=True,exist_ok=False)
 original=dashboard.configure_owner
 def configure(case,env,directory):
  original(case,env,directory)
  env['GRAFFITTY_TEST_EVIDENCE']=str(args.evidence)
  if os.environ.get('GRAFFITTY_CHROMIUM_HOST'):env['GRAFFITTY_CHROMIUM_HOST']=os.environ['GRAFFITTY_CHROMIUM_HOST']
 dashboard.configure_owner=configure
 template=next(c for c in dashboard.cases() if c['suite']=='windows' and c['name']=='powershell-7')
 shell='pwsh.exe' if os.name=='nt' else '/bin/sh'
 case=dict(template,suite='integration',name='desktop-defaults',shell=shell,timeout_seconds=300,
  replay=ROOT/'tests/llm-e2e/suites/godot/integration/replays/desktop-defaults.gd',
  server_config='[chromium]\nprofile='+json.dumps(str(args.evidence/'default-profile'))+'\n')
 result=dashboard.test_one(case,'',headful=True)
 (args.evidence/'report.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
 print(json.dumps(result,indent=2));return {'pass':0,'not_applicable':2,'blocked':2}.get(result['status'],1)
if __name__=='__main__':sys.exit(main())
