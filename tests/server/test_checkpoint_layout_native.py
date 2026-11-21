#!/usr/bin/env python3
"""Native CLI/frontend restore of two windows, five tabs, graph and browser pages."""
import argparse
import contextlib
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import psutil

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / d) for d in ("tests/support",)]
from e2e_server import PrivateServer


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['cli', 'frontend', 'godot', 'project', 'host', 'shell']:
        p.add_argument('--' + name, required=True)
    p.add_argument('--backend', choices=['chrome', 'alloy'], required=True)
    p.add_argument('--artifacts', type=Path, required=True)
    args = p.parse_args(); out = args.artifacts.resolve(); out.mkdir(parents=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith('GRAFFITTY_')}
    env.update(GRAFFITTY_BIN=args.cli, GRAFFITTY_TEST_GODOT=args.godot,
               GRAFFITTY_TEST_PROJECT=args.project, GRAFFITTY_CHROMIUM_HOST=args.host,
               GRAFFITTY_SERVER__CHROMIUM__BACKEND=args.backend,
               GRAFFITTY_CHECKPOINT_DIR=str(out / 'history'),
               CHECKPOINT_TEST_LOG=str(out / 'godot.log'), CHECKPOINT_TEST_PID=str(out / 'frontend.pid'))
    for kind in ['CONFIG', 'STATE', 'DATA', 'CACHE']:
        env['XDG_' + kind + '_HOME'] = str(out / kind.lower())
    os.environ['GRAFFITTY_TEST_SERVER'] = args.cli
    fixture = json.loads((ROOT / 'tests/fixtures/checkpoint-layout.json').read_text())
    for window in fixture['windows']:
        # Freeze simulation so geometry assertions measure restoration itself.
        for tab in window['tabs']:
            tab['tree']['physics'] = False
            tab['tree']['tiling_gap'] = 8.0
            tab['graph_visual'] = {'reroutes':{},'routes':{},'serial':0}
        for pane in window['panes']:
            pane['cwd'] = str(out); pane['font_size'] = 19
    ports = {'inputs':[{'id':'in'}], 'outputs':[{'id':'out','mode':'send'}]}
    fixture['windows'][1]['graph'] = {
        'nodes':[{'node':'%' + str(i),'manifest':ports} for i in [10,11]],
        'edges':[{'from':'%10','to':'%11','from_port':'out','to_port':'in',
                  'muted':True,'contains':'keep','outcome':'success','stop_at':4102444800}],
        'run_messages':42}
    fixture['windows'][1]['tabs'][0]['graph_visual'] = {
        'reroutes':{'r1':{'position':{'vec2':[650,120]}}}, 'routes':{'%10/out>%11/in':['r1']}}
    pages = out / 'pages'; pages.mkdir()
    for name in ['first','second','third']:
        (pages / (name + '.html')).write_text('<title>' + name + '</title>' + name)
    handler = type('Quiet', (http.server.SimpleHTTPRequestHandler,), {'log_message':lambda *_:None})
    with contextlib.ExitStack() as stack:
        web = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(handler,directory=str(pages)))
        threading.Thread(target=web.serve_forever,daemon=True).start()
        stack.callback(web.server_close); stack.callback(web.shutdown)
        base = 'http://127.0.0.1:' + str(web.server_port)
        template = out / 'profile template'; (template / 'Default').mkdir(parents=True)
        for index, (browser, owner, urls) in enumerate([(20,fixture['windows'][0]['panes'][0]['id'],['second','first']),(21,None,['third'])]):
            window = fixture['windows'][index]
            window['chromiums'] = [{'id':browser,'owner':owner,'title':'Docs' if index == 0 else '',
                **({'profile':''} if index == 0 else {'profile_template':str(template)}),
                'urls':[base + '/' + name + '.html' for name in urls]}]
            leaf = {'pane':'%' + str(browser),'shown':True,'rect':{'rect2':[920,80,420,500]}}
            if index == 0:
                window['tabs'][0]['tree']['windows'].append(leaf)
            else:
                window['tabs'].append({'id':browser,'focused':'%' + str(browser),
                    'tree':{'windows':[leaf],'physics':False,'tiling_gap':8.0},
                    'graph_visual':{'reroutes':{},'routes':{},'serial':0}})
        checkpoint = out / 'input.json'; checkpoint.write_text(json.dumps(fixture))
        stack.enter_context(PrivateServer(env, out, args.shell))
        def cleanup():
            pidfile = out / 'frontend.pid'
            if pidfile.exists():
                try:
                    proc = psutil.Process(int(pidfile.read_text()))
                    owned = proc.children(recursive=True) + [proc]
                    for item in owned:
                        with contextlib.suppress(psutil.NoSuchProcess): item.terminate()
                    _, alive = psutil.wait_procs(owned,timeout=5)
                    for item in alive:
                        with contextlib.suppress(psutil.NoSuchProcess): item.kill()
                except psutil.NoSuchProcess: pass
        stack.callback(cleanup)
        result = subprocess.run([args.cli,'checkpoint','restore','--frontend',args.frontend,
            '--checkpoint',str(checkpoint)],env=env,capture_output=True,text=True,encoding='utf-8',timeout=75)
        (out / 'restore.json').write_text(json.dumps({'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr}))
        assert result.returncode == 0, result.stderr
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            log = (out / 'godot.log').read_text(encoding='utf-8',errors='replace')
            if 'CHECKPOINT RESTORE SMOKE:' in log: break
            time.sleep(.1)
        assert 'CHECKPOINT RESTORE SMOKE: PASS' in log and 'SCRIPT ERROR' not in log, log
    (out / 'result.json').write_text(json.dumps({'status':'pass','platform':sys.platform,
        'backend':args.backend,'windows':2,'tabs':5,'panes':6,'chromiums':2,
        'cli_sha256':hashlib.sha256(Path(args.cli).read_bytes()).hexdigest()},indent=2))
    print(sys.platform,args.backend,'complex native checkpoint passed')


if __name__ == '__main__': main()
