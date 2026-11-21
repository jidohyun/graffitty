#!/usr/bin/env python3
"""Fresh desktop session; real parallel join and existing agent demo fixtures."""
import argparse,importlib.machinery,importlib.util,json,os,shlex,shutil,subprocess,sys
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
if os.name == "nt":
 from windows_live import main
 main()
 raise SystemExit(0)
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/support")]
sys.path.insert(0, str(ROOT / "videos/shared"))
from av1 import check_encoder,probe_av1
from e2e_background import prepare_background,clear_background,background_failures
from e2e_server import PrivateServer
loader=importlib.machinery.SourceFileLoader('record_effects',str(ROOT/'videos/effects/recording/record.py'))
effects=importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name,loader));loader.exec_module(effects)
p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);p.add_argument('--through-wiring',action='store_true');a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
def run(cmd,**kw):return subprocess.run([str(x) for x in cmd],check=True,**kw)
shutil.copy2(ROOT/'videos/main-demo/recording/parallel/review_payload.py',out/'review_payload.py')
run([sys.executable,ROOT/'videos/main-demo/recording/parallel/fixtures.py',out])
shutil.copy2(ROOT/'apps/server/shell-integration/integration.sh',out/'integration.sh')
(out/'.zshrc').write_text('HISTFILE=/dev/null\nPROMPT="%~ $ "\nRPROMPT=""\nPROMPT_EOL_MARK=""\nunsetopt PROMPT_SP\nsource /recording/integration.sh\n'+
 '\n'.join(f'{kind}() {{ print {kind} > /recording/launch-$DEMO_KEY; exit; }}' for kind in ['claude','codex'])+'\ngft() { [[ $1 == node && $2 == parallel ]] && { print parallel > /recording/launch-$DEMO_KEY; exit; }; }\nprintf "\\033[2J\\033[H"\n')
name='graffitty-parallel-'+str(os.getpid());podman=['podman','--connection','podman-machine-default']
run(podman+['run','-d','--name',name,'--network=none','--volume',str(out)+':/recording','localhost/graffitty-effects:4'],capture_output=True)
try:
 run(podman+['exec',name,'sh','-ec','useradd -m demo; chmod 777 /recording'])
 run(podman+['cp',ROOT/'apps/server/terminfo/xterm-ghostty.terminfo',name+':/tmp/ghostty.terminfo'])
 run(podman+['exec',name,'tic','-x','/tmp/ghostty.terminfo'])
 (out/'launch.py').write_text('''import os,sys\nfrom pathlib import Path\np=Path(os.environ['DEMO_RUNTIME'])\nkind=sys.argv[1]\nif kind=='parallel':os.execv(os.environ['GRAFFITTY_BIN'],['gft','node','parallel'])\nif kind=='claude':\n count=p/'claude-count'; n=int(count.read_text()) if count.exists() else 0; count.write_text(str(n+1)); config=['A','B','reviewer'][n]\nelse:config='C'\nos.execv(os.environ['GRAFFITTY_BIN'],['gft','dev',kind+'-mock','--config',str(p/(config+'.json'))])\n''')
 shell=out/'shell.sh'
 shell.write_text('#!/bin/sh\nexport DEMO_KEY=$$\n'+shlex.join(['env','XDG_CONFIG_HOME='+str(Path.home()/'.config'),*podman,'exec','-it','-e','ZDOTDIR=/recording','-e','DEMO_KEY','-w','/home/demo',name,'runuser','-u','demo','--','/bin/zsh','-d','-i'])+'\nkind=$(cat "$DEMO_RUNTIME/launch-$DEMO_KEY" 2>/dev/null)\nexec '+shlex.quote(sys.executable)+' "$DEMO_RUNTIME/launch.py" "$kind"\n');shell.chmod(0o700)
 project=effects.stage_project(out,'2400x1500')
 (project/'llm-e2e').symlink_to(ROOT/'tests/llm-e2e',target_is_directory=True)
 env={k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_','CODEX_','SLACK_'))}
 clear_background(env)
 state=Path('/Users/Shared/demo')/('parallel-'+out.name)
 state.mkdir(parents=True,exist_ok=True)
 env.update(DEMO_RUNTIME=str(out),XDG_CONFIG_HOME=str(out/'config'),XDG_STATE_HOME=str(state),XDG_DATA_HOME=str(out/'data'),XDG_CACHE_HOME=str(out/'cache'),GRAFFITTY_FFMPEG=check_encoder(),GRAFFITTY_MOVIE_PAUSED='1',GRAFFITTY_AV1_CRF='15',GRAFFITTY_AV1_PRESET='8')
 command=[shutil.which('godot'),*prepare_background(env,out),'--path',str(project),'--language','en','--write-movie',str(out/'footage.mp4'),'--fixed-fps','60','--quit-after','12000','--script','res://videos/main-demo/recording/parallel/ParallelDemo.gd','--','--record','--tabs=1','--shell='+str(shell),'--cwd='+str(state),'--bg=#4a4d54','--opacity=1','--no-focus-skip','--demo-output='+str(out)]
 if a.through_wiring:command.append('--through-wiring')
 (out/'command.json').write_text(json.dumps(command,indent=2))
 with PrivateServer(env,out,str(shell)):
  with (out/'godot.log').open('w') as log:run(command,env=env,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
 metadata=json.loads((out/'capture.json').read_text())
 assert not metadata['failures'],metadata['failures']
 assert not background_failures(out)
 if not a.through_wiring:assert (out/'received-combined.json').exists()
 probe,stream=probe_av1(out/'footage.mp4');(out/'probe.json').write_text(json.dumps(probe,indent=2))
 print(out/'footage.mp4')
finally:run(podman+['rm','-f',name],capture_output=True)
