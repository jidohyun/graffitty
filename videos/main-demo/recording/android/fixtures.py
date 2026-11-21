"""Shared offline shell and agent fixtures for device and desktop mobile captures."""
import json, os, shlex, shutil, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[4]
def run(cmd, **kw): return subprocess.run([str(x) for x in cmd], check=True, **kw)

def prepare(out):
 fixture=out/'fixture';fixture.mkdir(exist_ok=True)
 for f in ['send_review.py','review_payload.py']:shutil.copy2(ROOT/'videos/main-demo/recording/android'/f,fixture/f)
 shutil.copy2(ROOT/'apps/server/shell-integration/integration.sh',fixture/'integration.sh')
 (fixture/'spec.txt').write_text('Website specification\n- Landing hero and feature sections\n- Responsive mobile navigation\n- Contact form validation\n- Keyboard-accessible focus states\n')
 base={'directory':'/home/demo','char_ms':18,'tip':'','completion':{'elapsed_ms':4000,'completed_at':'2:30 PM'}}
 (fixture/'codex.json').write_text(json.dumps({**base,'model':'GPT-6-Astra medium','turns':[{'prompt':'Implement a website following the spec','steps':[{'type':'think','ms':300},{'type':'message','text':'I’ll build the landing page from spec.txt.'},{'type':'tool','name':'exec_command','input':'cat spec.txt','output':(fixture/'spec.txt').read_text(),'ms':400},{'type':'edit','path':'src/App.tsx','before':'','after':'export default function App() {\n  return <main><Hero /><Features /></main>;\n}','ms':400}],'response':'Implemented the website with a hero and feature sections. Ready for review.'}]}))
 (fixture/'claude.json').write_text(json.dumps({**base,'real_tool_calling':True,'turns':[{'prompt':"Graffitty will send turn completed payload. Review if it's done right. If not, send me on Slack.",'steps':[{'type':'think','text':'Preparing review','ms':250}],'response':'Ready. I’ll review the completion payload against the spec.'},{'steps':[{'type':'tool','name':'Read','input':'Codex session from completion payload','command':[sys.executable,str(fixture/'review_payload.py')],'ms':1500},{'type':'think','text':'Reviewing','ms':300},{'type':'message','text':'The implementation is missing 3 points from the spec:\n1. Responsive mobile navigation\n2. Contact form validation\n3. Keyboard-accessible focus states'},{'type':'think','ms':400},{'type':'tool','name':'Bash','input':'python3 send_review.py','command':[sys.executable,str(fixture/'send_review.py')],'ms':350}],'response':'Sent the three missing requirements to Slack for follow-up.'}]}))
 # The visible shells live in the same offline Podman image as the desktop demo.
 container='graffitty-android-'+str(os.getpid())
 podman=['podman','--connection','podman-machine-default']
 run(podman+['run','-d','--name',container,'--network=none','--volume',str(fixture)+':/recording','localhost/graffitty-effects:4'],capture_output=True)
 run(podman+['exec',container,'sh','-ec','useradd -m demo; chmod 777 /recording'],capture_output=True)
 run(podman+['cp',ROOT/'apps/server/terminfo/xterm-ghostty.terminfo',container+':/tmp/xterm-ghostty.terminfo'])
 run(podman+['exec',container,'tic','-x','/tmp/xterm-ghostty.terminfo'])
 run(podman+['exec',container,'runuser','-u','demo','--','sh','-ec',
  'cd /home/demo; git init -q; git config user.name Demo; git config user.email demo@example.invalid; cp /recording/spec.txt .; echo ".*" > .gitignore; git add -f .gitignore spec.txt; git commit -qm "Add website specification"; echo "- Clear call to action" >> spec.txt'],capture_output=True)
 (fixture/'.zshrc').write_text('export TERM=xterm-ghostty\nHISTFILE=/dev/null\nPROMPT="%~ $ "\nRPROMPT=""\nPROMPT_EOL_MARK=""\nunsetopt PROMPT_SP\nexport GIT_PAGER=cat\n'+
  'source /opt/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh\nsource /recording/integration.sh\n'+
  '\n'.join(f'{provider}() {{ print {provider} > /recording/launch-$DEMO_KEY; exit; }}' for provider in ['codex','claude'])+'\ngft() { [[ $1 == node && $2 == slack-send ]] && { print slack-send-demo > /recording/launch-$DEMO_KEY; exit; }; }\nprintf "\\033[2J\\033[H"\n')
 (fixture/'shell.sh').write_text("""#!/bin/sh
 export DEMO_KEY=$$
 env XDG_CONFIG_HOME="""+shlex.quote(str(Path.home()/'.config'))+""" podman --connection podman-machine-default exec -it -e ZDOTDIR=/recording -e DEMO_KEY -w /home/demo """+container+""" runuser -u demo -- /bin/zsh -d -i
 kind=$(cat "$DEMO_RUNTIME/launch-$DEMO_KEY" 2>/dev/null)
 case "$kind" in
  codex|claude|slack-send-demo) printf '%s\\n' "$TERM" > "$DEMO_RUNTIME/term-$kind" ;;
 esac
 case "$kind" in
  codex|claude) exec "$GRAFFITTY_BIN" dev "$kind-mock" --config "$DEMO_RUNTIME/$kind.json" ;;
  slack-send-demo) exec "$GRAFFITTY_BIN" dev slack-send-demo ;;
 esac
 """);(fixture/'shell.sh').chmod(0o700)
 return fixture, container
