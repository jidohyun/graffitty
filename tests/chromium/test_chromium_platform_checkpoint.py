#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Native frontend/CLI save, owned server crash, replacement and workspace restore.

Windows server fixtures use an interactive task. The native Godot frontend runs
headless on the server OS; this checks restoration, not desktop window interaction.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback
from urllib.parse import urlsplit
from test_desktop_chromium import Matrix, quote
from test_chromium_platform_isolation import Workspace
from test_chromium_platform_stress import connection, evaluate, eventually, sample


def seed_profiles(matrix, out, site, directory):
    with connection(matrix, out) as descriptor:
        owner=Workspace(descriptor, 'checkpoint-profile-seed')
        try:
            for index in range(matrix.args.windows):
                profile=directory+'/profiles/'+str(index)
                result=owner.rpc('chromium.create',url=site+'/first.html',profile=profile)
                browser=result['chromium'];sid=int(browser[1:])
                owner.client.until(lambda:any(b['id']==sid and b['state'].get('chromiumId',-1)>0 for b in owner.client.topology.get('chromiums',[])))
                pid=next(b['state']['pid'] for b in owner.client.topology['chromiums'] if b['id']==sid)
                eventually(lambda:evaluate(owner.rpc,browser,'document.title')=='first','Seed profile origin did not load')
                assert evaluate(owner.rpc,browser,"localStorage.setItem('checkpoint-window',"+json.dumps(str(index))+");true")
                owner.rpc('chromium.close',chromium=browser)
                eventually(lambda:all(p['pid']!=pid for p in sample(matrix,out)['descendants']),'Seed browser did not finish flushing and close')
        finally:
            owner.close()


def exercise(matrix,backend):
    args=matrix.args;windows=args.platform=='windows';root=matrix.out
    helper=Path(__file__).with_name('chromium_checkpoint_frontend.py')
    if windows:matrix.copy(helper,matrix.remote+'/checkpoint.py')
    checkpoint=None;previous=None;records={};profiles=None
    for phase in ['capture','restore']:
        out=root/(args.platform+'-'+backend+'-'+phase);out.mkdir()
        with matrix.fixture(out,backend):
            directory=matrix.remote+'/'+out.name if windows else str(out/'owner')
            if windows:
                matrix.copy(out/'live-fixture.json',directory+'/fixture.json',download=True)
                state=json.loads((out/'live-fixture.json').read_text())
            else:state=json.loads(Path(directory,'fixture.json').read_text())
            if previous:assert state['identity']!=previous,'Replacement reused server identity'
            site=state['origin_url'].rstrip('/')
            args.origin_port=urlsplit(site).port
            output=directory+'/frontend'
            if args.persistent_profiles and phase=='capture':
                seed_profiles(matrix,out,site,directory)
                profiles=directory+'/profiles'
            command=['--godot',args.godot,'--project',args.project,'--cli',args.server,
                '--descriptor',directory+'/connection.json','--site',site,'--phase',phase,'--output',output,'--windows',str(args.windows)]
            if profiles:command+=['--profiles',profiles]
            if checkpoint:command+=['--checkpoint',checkpoint]
            try:
                if windows:
                    script='& '+quote(args.python)+' '+quote(matrix.remote+'/checkpoint.py')+' '+' '.join(quote(x) for x in command)
                    script+="\nif ($LASTEXITCODE -ne 0) {throw 'Native checkpoint phase failed'}"
                    result=matrix.ps(script,timeout=300)
                else:
                    proc=subprocess.run([sys.executable,str(helper),*command],capture_output=True,text=True,timeout=300)
                    result=proc.stdout+proc.stderr
                    assert proc.returncode==0,result
                (out/'phase-launcher.log').write_text(result)
            finally:
                for name in ['godot.log','result.json','artifacts.json','userdata-cleanup.json','native-save.json','native-document.json','captured.json','restored.json','prepare.json']:
                    try:
                        if windows:matrix.copy(out/name,output+'/'+name,download=True)
                        elif Path(output,name).exists():(out/name).write_bytes(Path(output,name).read_bytes())
                    except subprocess.CalledProcessError:pass
            records[phase]=json.loads((out/'result.json').read_text())
            assert records[phase]['platform']=={'macos':'darwin','windows':'win32','linux':'linux'}[args.platform], 'Frontend did not run on the requested native OS'
            if phase=='capture':
                checkpoint=records[phase]['document'];previous=state['identity']
                # The native phase injected the kill while its frontend was alive.
                # Wait for it to be handled before fixture cleanup
                # requests a normal stop. Cleanup must observe the actual crash.
                deadline=time.monotonic()+35
                while True:
                    ready=matrix.ps('Test-Path '+quote(directory+'/cleanup.json'))=='True' if windows else Path(directory,'cleanup.json').exists()
                    if ready:break
                    assert time.monotonic()<deadline,'Crash cleanup timed out'
                    time.sleep(.2)
        cleanup=json.loads((out/'cleanup.json').read_text())
        assert cleanup['crashed']==(phase=='capture'),cleanup
        records[phase]['cleanup']=cleanup
        print(out.name,'pass',flush=True)
    return records


def main():
    os.umask(0o077)
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--platform',choices=['macos','windows','linux'],required=True)
    for name in ['server','host','shell','godot','project']:p.add_argument('--'+name,required=True)
    for name in ['ssh','remote-dir','python','principal-task']:p.add_argument('--'+name)
    p.add_argument('--ozone',choices=['wayland','x11'])
    p.add_argument('--persistent-profiles',action='store_true')
    p.add_argument('--windows',type=int,choices=[1,2],default=1)
    p.add_argument('--backend',choices=['chrome','alloy'],action='append')
    p.add_argument('--artifacts',type=Path,required=True)
    args=p.parse_args()
    if args.platform!='windows' and sys.platform!={'macos':'darwin','linux':'linux'}[args.platform]:p.error('Unix fixtures must run on the requested OS')
    if args.platform=='windows' and not all([args.ssh,args.remote_dir,args.python,args.principal_task]):p.error('Windows requires SSH, remote directory, Python and interactive principal task')
    if args.platform=='linux' and not args.ozone:p.error('Linux requires --ozone')
    args.listen='127.0.0.1:0';args.url=None;args.adb='unused';args.test_origin='checkpoint';args.origin_port=0
    matrix=Matrix(args);results={}
    sources=[Path(__file__),Path(__file__).with_name('chromium_checkpoint_frontend.py'),matrix.helper]
    (matrix.out/'source-hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},indent=2))
    for backend in args.backend or ['chrome','alloy']:
        args.origin_port=0
        try:results[backend]={'status':'pass','phases':exercise(matrix,backend)}
        except Exception as error:
            (matrix.out/(backend+'-failure.txt')).write_text(traceback.format_exc());results[backend]={'status':'fail','reason':str(error)}
        (matrix.out/'results.json').write_text(json.dumps(results,indent=2))
        print(backend,results[backend]['status'],flush=True)
    return int(any(v['status']!='pass' for v in results.values()))

if __name__=='__main__':raise SystemExit(main())
