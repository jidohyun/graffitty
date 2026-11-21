#!/usr/bin/env python3
"""Run a native Godot checkpoint phase against an explicitly owned server."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import shutil
import uuid
import time
import psutil


def run(args):
    out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
    binaries=[args.cli,args.godot,*args.project.glob('addons/graffitty/bin/*')]
    if args.godot.stem.endswith('_console'):
        binaries.append(args.godot.with_name(args.godot.name.replace('_console.exe','.exe')))
    (out/'artifacts.json').write_text(json.dumps({str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in binaries if p.is_file()},indent=2))
    env={k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_','CODEX_','CLAUDE_'))}
    for kind in ['CONFIG','STATE','DATA','CACHE']:env['XDG_'+kind+'_HOME']=str(out/kind.lower())
    env.update(GRAFFITTY_BIN=str(args.cli),GRAFFITTY_SERVER='nonexistent-checkpoint-owner',
        GRAFFITTY_SERVER_DESCRIPTOR=str(args.descriptor),GRAFFITTY_CHECKPOINT_DIR=str(out/'history'),
        GRAFFITTY_SERVER__CHECKPOINTS__ENABLED='false',CHECKPOINT_SITE=args.site,CHECKPOINT_WINDOWS=str(args.windows),CHECKPOINT_PROFILES=args.profiles or '',
        CHECKPOINT_WAIT_FOR_CRASH='1' if args.phase=='capture' else '0',CHECKPOINT_DOCUMENT=str(out/'captured.json'),CHECKPOINT_RESTORED=str(out/'restored.json'))
    def cli(*values):
        p=subprocess.run([str(args.cli),*values],env=env,capture_output=True,text=True,timeout=40)
        assert p.returncode==0,p.stdout+p.stderr
        return json.loads(p.stdout)
    def save_native(document):
        saved=cli('checkpoint','save','--input',str(document))
        (out/'native-save.json').write_text(json.dumps(saved,indent=2))
        (out/'native-document.json').write_bytes(Path(saved['path']).read_bytes())
    extra=[]
    if args.phase=='restore':
        prepared=cli('checkpoint','restore','--prepare-only','--checkpoint',str(args.checkpoint))
        (out/'prepare.json').write_text(json.dumps(prepared,indent=2))
        extra=['--restore-checkpoint='+prepared['prepared']]
    script='chromium_checkpoint_'+('save' if args.phase=='capture' else 'restore')+'.gd'
    override=args.project/'override.cfg'
    assert not override.exists() and not override.is_symlink(), 'Use a private project without an existing override.cfg'
    tag='graffitty-checkpoint-'+uuid.uuid4().hex
    override.write_text('[application]\nconfig/use_custom_user_dir=true\n'+''.join('config/custom_user_dir_name'+suffix+'="'+tag+'"\n' for suffix in ['', '.linux', '.bsd']))
    try:
        with (out/'godot.log').open('w') as log:
            p=subprocess.Popen([str(args.godot),'--headless','--path',str(args.project),'--script','tests/'+script,'--log-file',str(out/'engine.log'),'--',*extra,'--cwd='+str(out)],env=env,stdout=log,stderr=subprocess.STDOUT)
            try:
                if args.phase=='capture':
                    deadline=time.monotonic()+120
                    while 'CHROMIUM_CHECKPOINT_SAVE_PASS' not in (out/'godot.log').read_text(errors='replace'):
                        assert p.poll() is None, 'Frontend exited before capture completed'
                        assert time.monotonic()<deadline, 'Frontend capture timed out'
                        time.sleep(.1)
                    save_native(out/'captured.json')
                    assert p.poll() is None, 'Frontend exited before owned server crash'
                    (args.descriptor.parent/'crash').touch()
                p.wait(timeout=150)
            finally:
                if p.poll() is None:
                    try:
                        children=psutil.Process(p.pid).children(recursive=True)
                    except psutil.NoSuchProcess: children=[]
                    for child in children:
                        try: child.kill()
                        except psutil.NoSuchProcess: pass
                    p.kill();p.wait(timeout=10)
                    psutil.wait_procs(children,timeout=10)

    finally:
        override.unlink()
        directories=[json.loads(line.split('CHECKPOINT_USER_DIRECTORY ',1)[1]) for line in (out/'godot.log').read_text(errors='replace').splitlines() if line.startswith('CHECKPOINT_USER_DIRECTORY ')]
        for directory in directories:
            path=Path(directory)
            assert path.name==tag and not path.is_symlink(), 'Unexpected Godot user directory'
            if path.exists():shutil.rmtree(path)
        (out/'userdata-cleanup.json').write_text(json.dumps({'observed':bool(directories),'removed':directories},indent=2))
    text=(out/'godot.log').read_text(errors='replace')
    marker='CHROMIUM_CHECKPOINT_SAVE_PASS' if args.phase=='capture' else 'CHECKPOINT RESTORE SMOKE: PASS'
    assert p.returncode==0 and marker in text and 'ERROR:' not in text,text[-12000:]
    assert directories, 'Frontend did not report its private user directory'
    document=out/('captured.json' if args.phase=='capture' else 'restored.json')
    value=json.loads(document.read_text())
    assert len(value['windows'])==args.windows,value
    for index,window in enumerate(value['windows']):
        suffix='?window='+str(index) if args.windows>1 else ''
        assert len(window['chromiums'])==1,window
        expected_profile=(args.profiles+'/'+str(index)) if args.profiles else ''
        assert window['chromiums'][0]['profile'].replace('\\','/')==expected_profile.replace('\\','/'),window
        assert window['chromiums'][0]['urls']==[args.site+'/second.html'+suffix,args.site+'/first.html'+suffix],window
    if args.phase=='restore':save_native(document)
    native=(out/'native-document.json').read_bytes()
    assert [w['chromiums'] for w in json.loads(native)['windows']]==[w['chromiums'] for w in value['windows']]
    (out/'result.json').write_text(json.dumps({'status':'pass','phase':args.phase,'platform':sys.platform,'document':str(out/'native-document.json')},indent=2))


def main():
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['godot','project','cli','descriptor','output']:p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--site',required=True);p.add_argument('--phase',choices=['capture','restore'],required=True)
    p.add_argument('--checkpoint',type=Path)
    p.add_argument('--profiles')
    p.add_argument('--windows',type=int,choices=[1,2],default=1)
    args=p.parse_args()
    if args.phase=='restore' and not args.checkpoint:p.error('Restore requires --checkpoint')
    run(args)

if __name__=='__main__':main()
