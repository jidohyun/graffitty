#!/usr/bin/env python3
# /// script
# dependencies = ["uiautomator2==3.7.0", "websocket-client>=1.8,<2", "psutil>=7,<8"]
# ///
"""Test Android Chromium against local macOS or a Windows host over SSH.

Use development binaries, private profiles, and a disposable Android app.

On Windows, --python must have psutil. Supply an existing interactive task
whose account can launch the desktop fixture. The test leaves that task alone.
"""
import argparse
import base64
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import traceback
import uuid
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/android",)]
import test_android_runtime as android

ROOT = Path(__file__).resolve().parents[2]
CASES = ['hardware-backend','navigation','touch','scroll-stability','resume','crash-recovery','url','clipboard']


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class Matrix:
    def __init__(self, args):
        self.args = args
        self.out = args.artifacts.resolve(); self.out.mkdir(parents=True, exist_ok=False)
        self.adb = ['adb','-s',args.adb]
        self.run_id = uuid.uuid4().hex
        self.uploaded = None
        self.device_apk = '/data/local/tmp/graffitty-desktop-e2e-' + self.run_id + '.apk'
        self.results = {}
        self.helper = ROOT / 'tests/chromium/desktop_chromium_fixture.py'
        if args.platform == 'windows':
            self.remote = args.remote_dir.rstrip('/') + '/' + self.run_id
            self.ps('New-Item -ItemType Directory -Path ' + quote(self.remote) + ' | Out-Null')
            self.copy(self.helper, self.remote + '/fixture.py')

    def ps(self, script, timeout=45):
        code = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8\n$ProgressPreference='SilentlyContinue'\n$ErrorActionPreference='Stop'\n" + script
        encoded = base64.b64encode(code.encode('utf-16le')).decode()
        result = subprocess.run(['ssh','-o','ConnectTimeout=15',self.args.ssh,
            'powershell -NoProfile -EncodedCommand ' + encoded], capture_output=True, timeout=timeout)
        if result.returncode: raise RuntimeError((result.stdout + result.stderr).decode('utf8','replace'))
        return result.stdout.decode('utf8','replace').strip()

    def copy(self, local, remote, download=False):
        pair = [self.args.ssh + ':' + remote, str(local)] if download else [str(local), self.args.ssh + ':' + remote]
        subprocess.run(['scp', *pair], check=True, capture_output=True, timeout=60)

    def install(self, adb, apk):
        stat = apk.stat(); identity = (stat.st_ino,stat.st_size,stat.st_mtime_ns)
        if identity != self.uploaded:
            android.run(adb + ['push','-Z',str(apk),self.device_apk], capture_output=True, timeout=android.INSTALL_TIMEOUT)
            self.uploaded = identity
        result = android.run(adb + ['shell','pm','install','-r',self.device_apk],capture_output=True,timeout=android.INSTALL_TIMEOUT)
        assert b'Success' in result.stdout, result.stdout

    @contextmanager
    def fixture(self, out, backend):
        windows = self.args.platform == 'windows'
        directory = self.remote + '/' + out.name if windows else str(out / 'owner')
        config = dict(directory=directory, server=self.args.server, host=self.args.host,
            backend=backend, listen=self.args.listen, shell=self.args.shell)
        if getattr(self.args, 'ozone', None): config['ozone'] = self.args.ozone
        if getattr(self.args, 'test_origin', False): config['test_origin'] = self.args.test_origin
        if getattr(self.args, 'origin_port', 0): config['origin_port'] = self.args.origin_port
        config_file = out / 'fixture-config.json'; config_file.write_text(json.dumps(config))
        task = 'GraffittyDesktopE2E-' + self.run_id + '-' + out.name
        process = None; log = None; registered = False
        try:
            if windows:
                remote_config = self.remote + '/' + out.name + '.json'
                self.copy(config_file, remote_config)
                command = '& ' + quote(self.args.python) + ' ' + quote(self.remote + '/fixture.py') + ' serve --config ' + quote(remote_config)
                command += '\nif ($LASTEXITCODE -ne 0) {exit $LASTEXITCODE}'
                encoded = base64.b64encode(command.encode('utf-16le')).decode()
                self.ps('$principal=(Get-ScheduledTask -TaskName ' + quote(self.args.principal_task) + ').Principal\n'
                    + "if ([string]$principal.LogonType -ne 'Interactive') {throw 'Interactive desktop principal required'}\n"
                    + '$action=New-ScheduledTaskAction -Execute powershell.exe -Argument ' + quote('-NoProfile -EncodedCommand ' + encoded) + '\n'
                    + 'Register-ScheduledTask -TaskName ' + quote(task) + ' -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 35)) | Out-Null')
                registered = True
                self.ps('Start-ScheduledTask -TaskName ' + quote(task))
            else:
                log = (out / 'launcher.log').open('wb')
                process = subprocess.Popen([sys.executable,str(self.helper),'serve','--config',str(config_file)],stdout=log,stderr=log)
            deadline = time.monotonic() + 60
            while True:
                ready = self.ps('Test-Path ' + quote(directory + '/connection.json')) == 'True' if windows else Path(directory,'connection.json').exists()
                if ready: break
                assert time.monotonic() < deadline, 'Fixture startup timed out'
                if process: assert process.poll() is None, 'Fixture exited during startup'
                time.sleep(.3)
            if windows: self.copy(out / 'connection.json', directory + '/connection.json', download=True)
            else: (out / 'connection.json').write_bytes(Path(directory,'connection.json').read_bytes())
            descriptor = json.loads((out / 'connection.json').read_text())
            connection = descriptor['remote']
            if self.args.url: connection['url'] = self.args.url
            def kill(host, kind):
                if windows:
                    result = self.ps('& ' + quote(self.args.python) + ' ' + quote(self.remote + '/fixture.py') + ' kill --directory ' + quote(directory)
                        + ' --host-pid ' + str(int(host)) + ' --kind ' + quote(kind) + "\nif ($LASTEXITCODE -ne 0) {throw 'Owned crash injection failed'}")
                else:
                    result = subprocess.run([sys.executable,str(self.helper),'kill','--directory',directory,'--host-pid',str(host),'--kind',kind],check=True,capture_output=True,text=True,timeout=15).stdout
                with (out / 'crash-actions.jsonl').open('a') as actions: actions.write(result + '\n')
            yield connection, kill
        finally:
            try:
                if windows and registered:
                    self.ps('if(Test-Path ' + quote(directory) + '){New-Item -ItemType File -Force ' + quote(directory + '/stop') + ' | Out-Null}')
                    deadline = time.monotonic() + 45
                    while self.ps('(Get-ScheduledTask -TaskName ' + quote(task) + ').State') == 'Running':
                        assert time.monotonic() < deadline, 'Fixture cleanup timed out'
                        time.sleep(.5)
                elif process:
                    Path(directory,'stop').touch() if Path(directory).exists() else process.terminate()
                    process.wait(timeout=45)
                for name in ('server.log','fixture.json','cleanup.json'):
                    if windows: self.copy(out / name, directory + '/' + name, download=True)
                    elif Path(directory,name).exists(): (out / name).write_bytes(Path(directory,name).read_bytes())
            finally:
                if windows and registered: self.ps('Unregister-ScheduledTask -TaskName ' + quote(task) + ' -Confirm:$false')
                if process and process.poll() is None: process.terminate(); process.wait(timeout=20)
                if log: log.close()
            cleanup = json.loads((out / 'cleanup.json').read_text())
            if cleanup['crashed']:
                if windows: self.copy(out / 'crash.json', directory + '/crash.json', download=True)
                else: (out / 'crash.json').write_bytes(Path(directory, 'crash.json').read_bytes())
            assert not cleanup['leaked_processes'], cleanup
            if not windows: assert cleanup['exit'] == (-9 if cleanup['crashed'] else 0), cleanup

    def run(self):
        try:
            for backend in self.args.backend:
                for case in self.args.case:
                    name = self.args.platform + '-' + backend + '-' + case
                    out = self.out / name; out.mkdir()
                    try:
                        with self.fixture(out, backend) as (connection, kill):
                            android.smoke(self.adb,out,config={'connection':connection,'scenario':'workspace','case':'chromium-'+case},record=False,stop_chromium=kill,install_apk=self.install)
                        self.results[name] = {'status':'pass'}
                    except Exception as error:
                        (out/'failure.txt').write_text(traceback.format_exc())
                        self.results[name] = {'status':'fail','reason':str(error)}
                    (self.out/'results.json').write_text(json.dumps(self.results,indent=2))
                    print(name,self.results[name]['status'],flush=True)
        finally:
            subprocess.run(self.adb+['uninstall',android.PACKAGE],capture_output=True,timeout=30)
            subprocess.run(self.adb+['shell','rm','-f',self.device_apk],capture_output=True,timeout=30)
        return int(any(r['status'] != 'pass' for r in self.results.values()))


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--platform',choices=['macos','windows'],required=True)
    for name in ('server','host','shell','listen','adb'): p.add_argument('--'+name,required=True)
    p.add_argument('--url',help='Optional advertised WebSocket URL override')
    for name in ('ssh','remote-dir','python','principal-task'): p.add_argument('--'+name)
    p.add_argument('--backend',action='append',choices=['chrome','alloy'])
    p.add_argument('--case',action='append',choices=CASES)
    p.add_argument('--artifacts',type=Path,required=True)
    args=p.parse_args(); args.backend=args.backend or ['chrome','alloy']; args.case=args.case or CASES
    if args.platform=='windows' and not all((args.ssh,args.remote_dir,args.python,args.principal_task)): p.error('Windows requires --ssh, --remote-dir, --python and --principal-task')
    if args.platform=='macos' and sys.platform!='darwin': p.error('macOS fixtures must run locally on macOS')
    raise SystemExit(Matrix(args).run())

if __name__=='__main__': main()
