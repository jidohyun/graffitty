"""A test owns one explicit private session server; frontends only attach to it."""
from __future__ import annotations
import json, os, pathlib, shutil, subprocess, tempfile, time
from e2e_background import clear_background
ROOT = pathlib.Path(__file__).resolve().parents[2]
class PrivateServer:
    def __init__(self, env: dict[str, str], directory: pathlib.Path, shell: str | None, startup_timeout: float = 15):
        self.startup_timeout = startup_timeout
        self.env, self.directory, self.shell = env, pathlib.Path(directory).resolve()/'session-owner', shell
        self.process = None; self.log = None; self.short = None; self.linked = False
    def __enter__(self):
        if os.name == 'nt':
            # XDG_DATA_HOME isolates app state, not the installed mise tools
            # used by a real PowerShell profile. Otherwise profile activation
            # downloads another toolchain into every disposable test home.
            self.env.setdefault('MISE_DATA_DIR', os.environ.get('MISE_DATA_DIR',
                str(pathlib.Path(os.environ['LOCALAPPDATA']) / 'mise')))
        # Holder sockets sit beside the descriptor (`server.holder.<8
        # hex>.sock`), and a Unix socket path is limited to 104 bytes on macOS
        # and 108 on Linux and Windows. The product keeps that layout and
        # reports a state directory that is too deep.
        #
        # A deep test directory therefore runs the server from a short private
        # directory, linked from its place, and moves it back there on exit.
        if len(os.fsencode(self.directory/'server.holder.00000000.sock')) >= 104:
            self.short = pathlib.Path(tempfile.mkdtemp(prefix='gft-e2e-', dir=None if os.name == 'nt' else '/tmp')).resolve()
            if len(os.fsencode(self.short/'server.holder.00000000.sock')) >= 104:
                self.short.rmdir()
                raise RuntimeError(f'The temporary directory is too deep for a holder socket: {self.short}')
            self.directory.parent.mkdir(parents=True, exist_ok=True)
            if os.name == 'nt':
                # A junction needs no privilege; a symbolic link does.
                import _winapi
                _winapi.CreateJunction(str(self.short), str(self.directory))
            else:
                self.directory.symlink_to(self.short, target_is_directory=True)
            self.linked = True
            self.descriptor = self.short/'server.json'
        else:
            self.directory.mkdir(parents=True, exist_ok=False)
            self.descriptor = self.directory/'server.json'
        explicit = os.environ.get('GRAFFITTY_TEST_SERVER')
        suffix = '.exe' if os.name == 'nt' else ''
        candidates = [pathlib.Path(explicit)] if explicit else [ROOT/'target/debug'/('gft'+suffix), ROOT/'target/release'/('gft'+suffix)]
        self.binary = next((p.resolve() for p in candidates if p.is_file()), None)
        if self.binary is None: raise RuntimeError('Build gft before running frontend E2E tests')
        self.env.update(GRAFFITTY_SERVER=str(self.binary), GRAFFITTY_SERVER_DESCRIPTOR=str(self.descriptor))
        self.log = (self.directory/'server.log').open('wb')
        try:
            # The guard belongs to the Godot frontend. Inheriting it in the
            # owner also injects it into PTY programs, including Apple binaries
            # whose arm64e architecture cannot load the arm64 test library.
            owner_env = self.env.copy()
            clear_background(owner_env)
            command = [str(self.binary),"server", '--connection',str(self.descriptor),
                       '--auth-file',str(self.directory/'auth.json')]
            if self.shell is not None: command += ['--shell', self.shell]
            self.process = subprocess.Popen(command,
                env=owner_env,stdin=subprocess.DEVNULL,stdout=self.log,stderr=subprocess.STDOUT)
            deadline=time.monotonic()+self.startup_timeout
            while time.monotonic()<deadline:
                if self.process.poll() is not None: raise RuntimeError('Private E2E server exited; inspect '+str(self.directory/'server.log'))
                if self.descriptor.exists():
                    try:
                        descriptor=json.loads(self.descriptor.read_text())
                        if int(descriptor['pid'])==self.process.pid and descriptor.get('local',{}).get('url'):
                            self.identity={'pid':self.process.pid,'binary':str(self.binary),'descriptor':str(self.descriptor)}
                            (self.directory/'owner.json').write_text(json.dumps(self.identity,indent=2)+'\n')
                            return self
                    except (ValueError, KeyError): pass
                time.sleep(.02)
            raise RuntimeError('Private E2E session descriptor did not become ready')
        except BaseException:
            self.__exit__(None,None,None)
            raise
    def __exit__(self, *_):
        # Popen retains the actual owned child handle, avoiding PID-reuse and
        # descriptor-discovery races. Never stop a server found in ambient state.
        if self.process is not None:
            if self.process.poll() is None:
                if os.name == 'nt':
                    # TerminateProcess on only the server skips PTY teardown
                    # and leaves its shells/providers holding the private home.
                    subprocess.run(['taskkill.exe', '/PID', str(self.process.pid), '/T', '/F'],
                                   capture_output=True, timeout=15)
                else:
                    self.process.terminate()
                try:self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill();self.process.wait(timeout=5)
            (self.directory/'cleanup.json').write_text(json.dumps({'owned_pid':self.process.pid,
                'exit_code':self.process.returncode,'stopped':True},indent=2)+'\n')
        if self.log is not None:self.log.close()
        if self.short is not None and self.linked:
            # Removes the link, not what it points to.
            if os.name == 'nt': self.directory.rmdir()
            else: self.directory.unlink()
            shutil.move(str(self.short), str(self.directory))
