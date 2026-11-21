#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Record real Fold7 pixels, simulated touch and local agent graph fixtures."""
import argparse, json, os, re, shlex, tempfile, shutil, subprocess, sys, time
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path[:0] = [str(ROOT / "tools"), str(ROOT / "tests/android")]
sys.path.insert(0, str(ROOT / "videos/shared"))
from urllib.parse import urlparse
import test_android_runtime as android
import android_capture_privacy as privacy
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--skip-export',action='store_true');p.add_argument('--through-wiring',action='store_true');a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
package='com.graffitty.demo';android.PACKAGE=package
adb=['adb','-s','RFKL106JVBP']
def run(cmd,**kw):return subprocess.run([str(x) for x in cmd],check=True,**kw)
def private(name,value):
 run(adb+['shell','run-as',package,'sh','-c',f"'cat > files/{name}'"],input=value,text=True,capture_output=True)
def read(name):
 r=subprocess.run(adb+['shell','run-as',package,'cat','files/'+name],capture_output=True,text=True)
 return r.stdout if r.returncode==0 else ''
from fixtures import prepare
fixture,container=prepare(out)
podman=['podman','--connection','podman-machine-default']
stage=ROOT/'build/android/project'
(stage/'tests/client_scenarios').mkdir(parents=True,exist_ok=True)
shutil.copy2(ROOT/'videos/main-demo/recording/android/loader.gd',stage/'tests/client_scenarios/android_demo.gd')
if not a.skip_export:
 preset=stage/'export_presets.cfg';old=preset.read_text();preset.write_text(old.replace('screen/immersive_mode=true','screen/immersive_mode=false'))
 try:android.export_smoke(out)
 finally:preset.write_text(old)
 run(adb+['install','-r','--no-incremental',out/'runtime-test.apk'],capture_output=True)
run(adb+['shell','am','force-stop',package],capture_output=True)
run(adb+['shell','run-as',package,'mkdir','-p','files'],capture_output=True)
run(adb+['shell','run-as',package,'rm','-f','files/demo-go','files/demo-ready','files/demo-done','files/runtime-launch-count','files/runtime-state.json','files/demo-debug.json','files/demo-beats.json'],capture_output=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_','CODEX_','SLACK_'))}
demo_state=Path('/Users/Shared/demo')/('android-'+out.name)
demo_state.mkdir(parents=True,exist_ok=True)
env.update(DEMO_RUNTIME=str(fixture),XDG_CONFIG_HOME=str(out/'config'),XDG_STATE_HOME=str(demo_state),XDG_DATA_HOME=str(out/'data'),XDG_CACHE_HOME=str(out/'cache'))
server_log=(out/'server.log').open('w');descriptor=out/'server.json';descriptor.unlink(missing_ok=True)
server=subprocess.Popen([str(ROOT/'target/debug/gft'),'server','--listen','127.0.0.1:0','--connection',str(descriptor),'--auth-file',str(out/'auth.json'),'--shell',str(fixture/'shell.sh')],env=env,stdout=server_log,stderr=server_log)
rec=None;pid='';port=None
try:
 for _ in range(200):
  if descriptor.exists():break
  if server.poll() is not None:raise RuntimeError('Server failed')
  time.sleep(.1)
 settings=json.loads(descriptor.read_text());port=urlparse(settings['url']).port
 run(adb+['reverse',f'tcp:{port}',f'tcp:{port}'],capture_output=True)
 private('human_typing.gd',(ROOT/'videos/shared/typing/HumanTyping.gd').read_text())
 private('typing-timings.json',(ROOT/'videos/shared/typing/timings.json').read_text())
 private('android_demo.gd',(ROOT/'videos/main-demo/recording/android/AndroidDemo.gd').read_text())
 private('demo-config.json',json.dumps({'through_wiring':a.through_wiring}))
 private('runtime-config.json',json.dumps({'scenario':'android_demo','connection':settings}))
 run(adb+['shell','input','keyevent','KEYCODE_WAKEUP'],capture_output=True)
 run(adb+['shell','am','start','-W','--user','0','-n',package+'/com.godot.game.GodotAppLauncher'],capture_output=True)
 for _ in range(300):
  if read('demo-ready'):break
  state=read('runtime-state.json')
  if state:
   (out/'last-state.json').write_text(state)
   s=json.loads(state)
   if s.get('errors') or s.get('failures'):raise RuntimeError(state)
  time.sleep(.3)
 else:raise RuntimeError('Android readiness timeout')
 privacy.capture_screen(adb,out/'ready.png')
 privacy.metadata(out)
 display_size=run(adb+['shell','wm','size'],capture_output=True,text=True).stdout
 (out/'display-size.txt').write_text(display_size)
 capture_size=re.findall(r'(\d+x\d+)',display_size)[-1]
 remote='/sdcard/graffitty-android-demo.mp4'
 rec=subprocess.Popen(adb+['shell',f'screenrecord --size {capture_size} --bit-rate 40M --time-limit 180 {remote} >/dev/null 2>&1 & echo $!; wait $!'],stdout=subprocess.PIPE,text=True)
 pid=rec.stdout.readline().strip();time.sleep(1)
 private('demo-go','go')
 print('Recording started',flush=True)
 deadline=time.monotonic()+175
 while time.monotonic()<deadline:
  state=read('runtime-state.json')
  if state:
   (out/'last-state.json').write_text(state);s=json.loads(state)
   if s.get('errors') or s.get('failures'):raise RuntimeError(state)
  if read('demo-done'):break
  time.sleep(.5)
 else:raise RuntimeError('Demo timeout')
 (out/'capture.json').write_text(read('demo-done'));(out/'beats.json').write_text(read('demo-beats.json'))
 terms={kind:(fixture/('term-'+kind)).read_text().strip() for kind in ['codex','claude','slack-send-demo']}
 (out/'agent-terms.json').write_text(json.dumps(terms,indent=2)+'\n')
 if any(term!='xterm-ghostty' for term in terms.values()):raise RuntimeError('Demo agent TERM mismatch: '+str(terms))
 privacy.capture_screen(adb,out/'final.png')
finally:
 for filename in ["demo-debug.json", "demo-beats.json"]:
  value=read(filename)
  if value:(out/filename).write_text(value)
 if rec and pid.isdigit():
  subprocess.run(adb+['shell','kill','-2',pid],capture_output=True);rec.wait(timeout=20)
  with tempfile.TemporaryDirectory(prefix='graffitty-private-',dir='/tmp') as temp:
   private_video=Path(temp)/'device.mp4'
   run(adb+['pull','/sdcard/graffitty-android-demo.mp4',private_video],capture_output=True)
   privacy.crop_video(private_video,out/'device-raw.mp4')
  run(adb+['shell','rm','-f',remote],capture_output=True)
 subprocess.run(adb+['logcat','-d','-t','1500'],stdout=(out/'android.log').open('w'))
 run(adb+['shell','am','force-stop',package],capture_output=True)
 if port:subprocess.run(adb+['reverse','--remove',f'tcp:{port}'],capture_output=True)
 server.terminate();server.wait(timeout=10);server_log.close()
 subprocess.run(podman+['rm','-f',container],capture_output=True)
probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=width,height','-of','json',str(out/'device-raw.mp4')]))['streams'][0]
assert [probe['width'],probe['height']]==privacy.APP_RECT[2:], 'Expected application-only capture'
print(out/'device-raw.mp4')
