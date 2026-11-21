#!/usr/bin/env python3
"""Record production node UIs with scripted SystemOne and agent decisions."""
import argparse,importlib.machinery,importlib.util,json,os,shlex,shutil,subprocess,sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
if os.name == "nt":
 sys.path.insert(0, str(ROOT / "videos/main-demo/recording/parallel"))
 from windows_live import main
 main(default_chapter="systemone")
 raise SystemExit(0)
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/support")]
sys.path.insert(0, str(ROOT / "videos/shared"))
from av1 import check_encoder,probe_av1
from e2e_background import prepare_background,clear_background,background_failures
from e2e_server import PrivateServer
from fixtures import PROMPT, PROTOCOL_PROMPT

# Fail before launching a capture if edited prompts lack human typing timings.
typing_phrases = json.loads((ROOT / 'videos/shared/typing/timings.json').read_text())['phrases']
missing_phrases = {PROMPT, PROTOCOL_PROMPT} - typing_phrases.keys()
assert not missing_phrases, f'Add to videos/shared/typing/phrases.json and run build.py: {sorted(missing_phrases)}'
loader=importlib.machinery.SourceFileLoader('record_effects',str(ROOT/'videos/effects/recording/record.py'))
effects=importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name,loader));loader.exec_module(effects)
p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);p.add_argument('--chapter',choices=['systemone','protocol','node-sessions'],default='systemone');a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
def run(cmd,**kw):return subprocess.run([str(x) for x in cmd],check=True,**kw)
state=Path('/Users/Shared/demo')/(a.chapter+'-'+out.name)
state.mkdir(parents=True,exist_ok=True)
shutil.copy2(ROOT/'videos/main-demo/composition/demo-audio.json',out/'demo-audio.json')
(out/'animation-clock').write_text('0')
run([sys.executable,ROOT/'videos/main-demo/recording/systemone/fixtures.py',out])
if a.chapter=='node-sessions':
 shutil.copy2(ROOT/'videos/main-demo/recording/parallel/review_payload.py',out/'review_payload.py')
 run([sys.executable,ROOT/'videos/main-demo/recording/parallel/fixtures.py',out])
if a.chapter in ['protocol','node-sessions']:
 shutil.copy2(ROOT/'examples/uppercase-node/node.py',out/'node.py')
 (out/'pyproject.toml').write_text('[project]\nname="graph-protocol-demo"\nversion="0.1.0"\nrequires-python=">=3.11"\ndependencies=["graffitty-graph-protocol"]\n[tool.uv.sources]\ngraffitty-graph-protocol={path='+json.dumps(str(ROOT/'python/libs/graffitty-graph-protocol'))+',editable=true}\n')
 run(['uv','sync','--project',out],env={**os.environ,'UV_PROJECT_ENVIRONMENT':str(state/'venv')},capture_output=True)
 # Keep the agent's movie-clock timing: its prompt and streamed completion
 # are recorded beside the connected inspector, before the Python example.
shutil.copy2(ROOT/'apps/server/shell-integration/integration.sh',out/'integration.sh')
(out/'.zshrc').write_text('HISTFILE=/dev/null\nPROMPT="%~ $ "\nRPROMPT=""\nPROMPT_EOL_MARK=""\nunsetopt PROMPT_SP\nsource /recording/integration.sh\n'+
 '\n'.join(f'{kind}() {{ print {kind} > /recording/launch-$DEMO_KEY; exit; }}' for kind in ['claude','codex'])+'\ngft() { [[ $1 == node && $2 == (manual-prompt|systemone|payload-inspector|parallel) ]] && { print $2 > /recording/launch-$DEMO_KEY; exit; }; }\nbat() { command batcat --style=plain --paging=never --color=always --theme=TwoDark "$@"; }\nuv() { [[ $1 == run && $2 == node.py ]] && { print protocol > /recording/launch-$DEMO_KEY; exit; }; }\nprintf "\\033[2J\\033[H"\n')
name='graffitty-systemone-'+str(os.getpid());podman=['podman','--connection','podman-machine-default']
run(podman+['run','-d','--name',name,'--network=none','--volume',str(out)+':/recording','localhost/graffitty-effects:4'],capture_output=True)
try:
 run(podman+['exec',name,'sh','-ec','useradd -m demo; chmod 777 /recording'])
 if a.chapter in ['protocol','node-sessions']:run(podman+['cp',out/'node.py',name+':/home/demo/node.py'])
 run(podman+['cp',ROOT/'apps/server/terminfo/xterm-ghostty.terminfo',name+':/tmp/ghostty.terminfo'])
 run(podman+['exec',name,'tic','-x','/tmp/ghostty.terminfo'])
 (out/'launch.py').write_text("""import os,sys
from pathlib import Path
p=Path(os.environ['DEMO_RUNTIME'])
kind=sys.argv[1]
cli=os.environ['GRAFFITTY_BIN']
if kind=='parallel':os.execv(cli,['gft','node','parallel'])
if (p/'launch-chapter').exists() and (p/'launch-chapter').read_text()=='parallel' and kind in ['claude','codex']:
 if kind=='claude':
  count=p/'claude-count'; n=int(count.read_text()) if count.exists() else 0; count.write_text(str(n+1)); config=['A','B','reviewer'][n]
 else:config='C'
 os.execv(cli,['gft','dev',kind+'-mock','--config',str(p/(config+'.json'))])
if kind=='manual-prompt':os.execv(cli,['gft','node','manual-prompt'])
if kind=='payload-inspector':os.execv(cli,['gft','node','payload-inspector'])
if kind=='protocol':
 os.chdir(p)
 os.execv(os.environ['DEMO_UV'],['uv','run','node.py'])
if kind=='systemone':os.execv(cli,['gft','dev','systemone-mock','--scenario',str(p/'decisions.json'),'--config',str(p/'systemone-settings.json')])
os.execv(cli,['gft','dev',kind+'-mock','--config',str(p/(kind+'.json'))])
""")
 shell=out/'shell.sh'
 shell.write_text('#!/bin/sh\nexport DEMO_KEY=$$\n'+shlex.join(['env','XDG_CONFIG_HOME='+str(Path.home()/'.config'),*podman,'exec','-it','-e','ZDOTDIR=/recording','-e','DEMO_KEY','-w','/home/demo',name,'runuser','-u','demo','--','/bin/zsh','-d','-i'])+'\nkind=$(cat "$DEMO_RUNTIME/launch-$DEMO_KEY" 2>/dev/null)\nexec '+shlex.quote(sys.executable)+' "$DEMO_RUNTIME/launch.py" "$kind"\n');shell.chmod(0o700)
 project=effects.stage_project(out,'2400x1500')
 (project/'llm-e2e').symlink_to(ROOT/'tests/llm-e2e',target_is_directory=True)
 env={k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_','CODEX_','SLACK_'))}
 clear_background(env)
 env.update(DEMO_RUNTIME=str(out),XDG_CONFIG_HOME=str(out/'config'),XDG_STATE_HOME=str(state),XDG_DATA_HOME=str(out/'data'),XDG_CACHE_HOME=str(out/'cache'),GRAFFITTY_FFMPEG=check_encoder(),GRAFFITTY_MOVIE_PAUSED='1',GRAFFITTY_AV1_CRF='15',GRAFFITTY_AV1_PRESET='8')
 if a.chapter in ['protocol','node-sessions']:env.update(DEMO_UV=shutil.which('uv'),UV_PROJECT_ENVIRONMENT=str(state/'venv'))
 if a.chapter=='node-sessions':
  from e2e_bistro import installed_bistro, link_bistro
  link_bistro(out/'data', installed_bistro())  # Bistro is an installed world
 replay={'protocol':'protocol/ProtocolDemo.gd','systemone':'systemone/SystemoneDemo.gd','node-sessions':'node-sessions/NodeSessionsDemo.gd'}[a.chapter]
 command=[shutil.which('godot'),*prepare_background(env,out),'--path',str(project),'--language','en','--write-movie',str(out/'footage.mp4'),'--fixed-fps','60','--quit-after','24000','--script','res://videos/main-demo/recording/'+replay,'--','--record','--tabs=1','--shell='+str(shell),'--cwd='+str(state),'--bg=#4a4d54','--opacity=1','--no-focus-skip','--demo-output='+str(out)]
 if a.chapter=='node-sessions':command.append('--node-sessions')
 (out/'command.json').write_text(json.dumps(command,indent=2))
 with PrivateServer(env,out,str(shell)):
  with (out/'godot.log').open('w') as log:run(command,env=env,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=1800)
 metadata=json.loads((out/'capture.json').read_text())
 assert not metadata['failures'],metadata['failures']
 assert not background_failures(out)
 if a.chapter in ['protocol','node-sessions']:
  evidence=json.loads((out/'graph-evidence.json').read_text())
  assert evidence['command']=='uv run node.py' and evidence['result']=='HELLO GRAPH'
  assert evidence['original_session_reference'] and evidence['delivered']
  intro=evidence['live_agent_intro']
  assert 0 <= intro['connected_frame'] < intro['prompt_start_frame'] < intro['submitted_frame'] < intro['response_started_frame'] < intro['received_frame'] < metadata['frames']
  assert (out/'node.py').read_bytes()==(ROOT/'examples/uppercase-node/node.py').read_bytes()
 else:
  from verify import verify
  verify(out)
 probe,stream=probe_av1(out/'footage.mp4');(out/'probe.json').write_text(json.dumps(probe,indent=2))
 print(out/'footage.mp4')
finally:run(podman+['rm','-f',name],capture_output=True)
