#!/usr/bin/env python3
"""Godot Chromium pixels, resize and reconnect over shared GPU or video."""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, platform, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer
from e2e_background import prepare_background, background_failures


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=pathlib.Path, required=True)
    parser.add_argument('--server', type=pathlib.Path, default=ROOT/'target/debug/gft')
    parser.add_argument('--godot', default=os.environ.get('GRAFFITTY_TEST_GODOT', 'godot'))
    parser.add_argument('--headful', action='store_true')
    parser.add_argument('--transport', choices=['native-gpu','video'], default='native-gpu')
    parser.add_argument('--scenario', choices=['presentation','input'], default='presentation',
                        help='Input uses synthetic events in the actual frontend, never desktop-wide input or the OS clipboard')
    parser.add_argument('--window-lifecycle', action='store_true')
    parser.add_argument('--display-movement', action='store_true')
    parser.add_argument('--float-test-windows', action='store_true',
                        help='Opt in to fixture-only AeroSpace floating and monitor/workspace moves')
    parser.add_argument('--chromium-host', type=pathlib.Path)
    parser.add_argument('--project',type=pathlib.Path,default=ROOT/'frontends/godot/project')
    parser.add_argument('--backend',choices=['chrome','alloy'],default='chrome')
    parser.add_argument('--ozone',choices=['wayland','x11'])
    args=parser.parse_args(); out=args.evidence.resolve()
    if args.float_test_windows and (sys.platform != 'darwin' or not args.headful):
        parser.error('--float-test-windows requires headful macOS and AeroSpace')
    if sys.platform in ('win32','linux') and not args.headful:
        parser.error('Windows/Linux frontend acceptance requires --headful')
    if sys.platform == 'linux' and not args.ozone:
        parser.error('Linux frontend acceptance requires an explicit --ozone')
    if sys.platform == 'linux' and args.transport == 'native-gpu':
        parser.error('Linux Chromium has no shared GPU channel; use --transport video')
    if args.transport == 'video' and sys.platform != 'linux':
        parser.error('Video-only frontend acceptance currently targets Linux; use native-gpu for GPU/fallback acceptance')
    if args.scenario == 'input' and (args.transport != 'native-gpu' or args.window_lifecycle or args.display_movement):
        parser.error('Input scenario requires native-gpu without window/display lifecycle options')
    if args.transport == 'video' and (args.window_lifecycle or args.display_movement):
        parser.error('Window/display lifecycle options currently require --transport native-gpu')
    out.mkdir(parents=True, exist_ok=False)
    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            body=b"<!doctype html><style>html,body{margin:0;height:100%;overflow:hidden}body{display:flex}div{width:50%;height:100%}#a{background:#f020c0}#b{background:#20e0e0}</style><div id=a></div><div id=b></div><script>window.paint=(a,b)=>{document.getElementById('a').style.background=a;document.getElementById('b').style.background=b;return true}</script>"
            self.send_response(200);self.send_header('Content-Type','text/html');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def log_message(self,*args): pass
    http=ThreadingHTTPServer(('127.0.0.1',0),Page)
    threading.Thread(target=http.serve_forever,daemon=True).start()
    env={k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'DYLD_'))}
    for kind in ('CONFIG','STATE','CACHE','DATA'):env['XDG_'+kind+'_HOME']=str(out/kind.lower())
    env['GRAFFITTY_SERVER__CHROMIUM__BACKEND']=args.backend
    if args.ozone: env['GRAFFITTY_CHROMIUM_OZONE_PLATFORM']=args.ozone
    if args.ozone == 'wayland': env.pop('DISPLAY', None)
    if args.window_lifecycle: env['GRAFFITTY_TEST_WINDOW_LIFECYCLE']='1'
    if args.display_movement: env['GRAFFITTY_TEST_DISPLAY_MOVEMENT']='1'
    if args.float_test_windows:
        env['GRAFFITTY_TEST_WINDOW_PYTHON']=sys.executable
        env['GRAFFITTY_TEST_WINDOW_HELPER']=str(ROOT/'tests/support/e2e_macos_windows.py')
    env.update(GRAFFITTY_GPU_EVIDENCE=str(out), GRAFFITTY_GPU_URL=f'http://127.0.0.1:{http.server_port}/')
    if args.chromium_host: env['GRAFFITTY_CHROMIUM_HOST']=str(args.chromium_host.resolve())
    server=args.server.resolve()
    os.environ['GRAFFITTY_TEST_SERVER']=str(server)
    architecture={'x86_64':'x86_64','aarch64':'arm64'}.get(platform.machine().lower())
    library={'win32':'libgraffitty.windows.x86_64.dll','darwin':'libgraffitty.macos.dylib','linux':f'libgraffitty.linux.{architecture}.so'}[sys.platform]
    extension=args.project.resolve()/'addons/graffitty/bin'/library
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    initial=sha(extension)
    script=('tests/chromium_desktop_input.gd' if args.scenario == 'input' else
            'tests/shared_chromium_gpu.gd' if args.transport == 'native-gpu' else 'tests/chromium_video_frontend.gd')
    report={'scenario':args.scenario,'input_injection':'Godot InputEvent' if args.scenario == 'input' else None,'status':'RUNNING','checks':[],'extension_sha256':initial,'server_sha256':sha(server),'desktop_input':False,'backend':args.backend,'ozone':args.ozone,'transport':args.transport}
    report.update(window_lifecycle=args.window_lifecycle, display_movement=args.display_movement)
    if args.float_test_windows:
        report['window_adapter_sha256']=sha(ROOT/'tests/support/e2e_macos_windows.py')
    if args.chromium_host: report['host_sha256']=sha(args.chromium_host.resolve())
    report['source_sha256']={name:sha(args.project.resolve()/name) for name in {
        script, 'tests/shared_chromium_gpu.gd', 'scenes/TerminalHost.gd',
        'scenes/WorkspacePane.gd', 'scenes/WorkspaceView.gd', 'scenes/remote/RemoteChromiumSession.gd',
        'scenes/remote/RemoteConnection.gd', 'scenes/ChromiumSession.gd',
        'scenes/GraphWorkspaceTools.gd', 'scenes/WorkspacePrefix.gd',
    }}
    try:
        shell='pwsh.exe' if os.name=='nt' else '/bin/sh'
        with PrivateServer(env,out,shell):
            flags=[] if args.headful else prepare_background(env,out/'guard')
            if args.ozone: flags += ['--display-driver',args.ozone]
            command=[args.godot,'--path',str(args.project.resolve()),*flags,'--script',script,'--','--shell='+shell,'--no-plugin']
            with (out/'godot.log').open('w',encoding='utf-8') as log:
                with subprocess.Popen(command,env=env,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT) as result:
                    try:
                        result.wait(timeout=180)
                    finally:
                        if result.poll() is None:
                            result.terminate()
                            try: result.wait(timeout=5)
                            except subprocess.TimeoutExpired: result.kill(); result.wait()
            text=(out/'godot.log').read_text(encoding='utf-8')
            report['checks']=[line.removeprefix('[replay] PASS ') for line in text.splitlines() if line.startswith('[replay] PASS ')]
            report['guard_failures']=[] if args.headful else background_failures(out/'guard')
            assert result.returncode==0, f'Godot failed: {result.returncode}; see godot.log'
            if args.float_test_windows:
                report['window_isolation']=json.loads((out/'window-move-initial.json').read_text())['isolation']
            assert 'REPLAY_PASS' in text and 'SCRIPT ERROR' not in text, 'Replay did not complete successfully'
            assert not report['guard_failures'],report['guard_failures']
            assert sha(extension)==initial,'Loaded extension changed during test'
            report['status']='PASS'
    except BaseException as error:
        report.update(status='FAIL',error=str(error));raise
    finally:
        http.shutdown();http.server_close();(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
