"""Missing final-session routes against the production auto-started Windows owner."""
import argparse, ctypes, hashlib, json, os
from pathlib import Path
import subprocess, sys, time
sys.path[:0] = [str(Path(__file__).resolve().parents[3] / d) for d in ("tests/server",)]
from windows_relaunch_e2e import ProcessHandle
from windows_protocol_actions_e2e import private_station
import windows_private_desktop
ROOT=Path(__file__).resolve().parents[3]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence',type=Path,required=True)
    parser.add_argument('--project',type=Path,default=ROOT/'frontends/godot/project')
    parser.add_argument('--route',choices=['pane-menu','pane-shortcut','shell-exit','shell-eof','tab-control','window-close','detached-exit'],required=True)
    parser.add_argument('--relaunch',action='store_true')
    parser.add_argument('--observer',action='store_true')
    parser.add_argument('--shell',choices=['pwsh.exe','powershell.exe'],default='pwsh.exe')
    parser.add_argument('--worker',action='store_true')
    args=parser.parse_args(); directory=args.evidence.resolve()
    if not args.worker:
        directory.mkdir(parents=True,exist_ok=False)
        result=windows_private_desktop.run([sys.executable,'-X','utf8',__file__,*sys.argv[1:],'--worker'],env=dict(os.environ),cwd=ROOT,log=directory/'worker.log',timeout=65)
        (directory/'isolation.json').write_text(json.dumps(result,indent=2))
        return result['exit_code']
    private_station()
    binary=Path(os.environ['GRAFFITTY_TEST_SERVER']).resolve()
    env={k:v for k,v in os.environ.items() if not k.startswith(('GRAFFITTY_', 'CODEX_', 'CLAUDE_'))}
    for kind in ('CONFIG','STATE','CACHE','DATA'):env['XDG_'+kind+'_HOME']=str(directory/kind.lower())
    descriptor=directory/'state/graffitty/server.json'
    env.update(GRAFFITTY_SERVER=str(binary),GRAFFITTY_SERVER_DESCRIPTOR=str(descriptor),GRAFFITTY_MULTISESSION_EVIDENCE=str(directory),GRAFFITTY_MULTISESSION_ROUTE=args.route,GRAFFITTY_MULTISESSION_TABS='0' if args.route=='tab-control' else '1')
    config=directory/'config/graffitty/server.toml'; config.parent.mkdir(parents=True)
    config.write_text('[terminal]\nshell='+json.dumps([args.shell,'-NoLogo','-NoProfile'])+'\nshell_integration=true\n')
    report={'status':'FAIL','route':args.route,'shell':args.shell,'owner_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
    handles=[]; frontend=None; owner=None; observer=None
    try:
        with (directory/'godot.log').open('wb') as log:
            frontend=subprocess.Popen([os.environ['GODOT'],'--path',str(args.project.resolve()),'--script','res://tests/windows_multisession_smoke.gd'],env=env,stdout=log,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+30
            while not (directory/'ready.json').exists():
                if owner is None and descriptor.exists():
                    identity=json.loads(descriptor.read_text()); owner=ProcessHandle(identity['pid']); handles.append(owner)
                assert frontend.poll() is None and time.monotonic()<deadline,'Production startup failed'
                time.sleep(.03)
            if owner is None:
                identity=json.loads(descriptor.read_text()); owner=ProcessHandle(identity['pid']); handles.append(owner)
            ready=json.loads((directory/'ready.json').read_text())
            shells=[ProcessHandle(p['pid']) for p in ready['panes']]; handles.extend(shells)
            inventory=subprocess.run([str(binary),'session', 'list','--json'],env=env,capture_output=True,text=True,encoding='utf-8',check=True,timeout=5)
            report['inventory']=json.loads(inventory.stdout)
            assert [s['name'] for s in report['inventory']]==['A']
            if args.observer:
                from test_session_transfer import Peer
                observer=Peer(identity['local'],'A')
            started=time.monotonic(); (directory/'close').touch()
            if args.route in ['pane-menu','pane-shortcut','shell-exit','shell-eof']:
                deadline=time.monotonic()+15
                while not (directory/'intermediate.json').exists():
                    assert frontend.poll() is None and time.monotonic()<deadline,'Intermediate pane close failed'
                    time.sleep(.03)
                assert sum(p.exited() for p in shells)==len(shells)-1 and not owner.exited()
                started=time.monotonic(); (directory/'continue').touch()
            assert frontend.wait(timeout=5)==0,'Frontend did not quit normally'
            assert owner.exited(5000) and all(p.exited() for p in shells),'Last session did not reap its owner and shells'
            report['graceful_seconds']=time.monotonic()-started
            assert report['graceful_seconds']<5
            code=ctypes.c_ulong(); assert owner.api.GetExitCodeProcess(owner.handle,ctypes.byref(code)) and code.value==0
            assert not descriptor.exists()
            time.sleep(5)
            assert not descriptor.exists(),'Closed owner was recreated'
            text=(directory/'godot.log').read_text(encoding='utf-8',errors='replace')
            assert not any(line.startswith(('ERROR:','SCRIPT ERROR:','WARNING:')) for line in text.splitlines()),text
            report.update(status='PASS',owner={'pid':owner.pid,'birth':owner.birth},shells=[{'pid':p.pid,'birth':p.birth} for p in shells],natural_shutdown=True)
            report['observer_attached_at_shutdown']=args.observer
            if observer is not None:observer.socket.close(); observer=None
            if args.relaunch:
                output=directory/'relaunch'; output.mkdir()
                env.update(GRAFFITTY_RELAUNCH_EVIDENCE=str(output),GRAFFITTY_RELAUNCH_CYCLE='fresh')
                with (output/'godot.log').open('wb') as again_log:
                    frontend=subprocess.Popen([os.environ['GODOT'],'--path',str(args.project.resolve()),'--script','res://tests/windows_relaunch_smoke.gd'],env=env,stdout=again_log,stderr=subprocess.STDOUT)
                    deadline=time.monotonic()+25
                    while not (output/'ready.json').exists():
                        assert frontend.poll() is None and time.monotonic()<deadline,'Fresh relaunch did not create a usable frontend'
                        time.sleep(.03)
                    fresh=json.loads((output/'ready.json').read_text())
                    new_identity=json.loads(descriptor.read_text()); new_owner=ProcessHandle(new_identity['pid']); handles.append(new_owner)
                    new_shell=ProcessHandle(fresh['shell_pid']); handles.append(new_shell)
                    assert (new_owner.pid,new_owner.birth)!=(owner.pid,owner.birth)
                    assert all((new_shell.pid,new_shell.birth)!=(p.pid,p.birth) for p in shells)
                    owner=new_owner
                    started=time.monotonic(); (output/'close').touch()
                    assert frontend.wait(timeout=5)==0 and new_owner.exited(5000) and new_shell.exited()
                    assert time.monotonic()-started<5 and not descriptor.exists()
                    report['relaunch']={**fresh,'owner_pid':new_owner.pid,'owner_birth':new_owner.birth,'shell_birth':new_shell.birth,'natural_shutdown':True}
    except Exception as error:report['error']=str(error)
    finally:
        if observer is not None:observer.socket.close()
        if frontend is not None and frontend.poll() is None:frontend.kill(); frontend.wait(timeout=5)
        if owner is not None and not owner.exited():subprocess.run(['taskkill.exe','/PID',str(owner.pid),'/T','/F'],capture_output=True,timeout=10)
        for handle in reversed(handles):handle.cleanup()
        (directory/'report.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2)); return report['status']!='PASS'
if __name__=='__main__':sys.exit(main())
