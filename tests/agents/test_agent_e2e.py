#!/usr/bin/env python3
# /// script
# dependencies = ["Pillow>=12,<13", "pydantic>=2.10,<3"]
# ///
"""Real-provider graph E2E runner. Uses installed CLIs; never mocks model responses."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
GODOT_ROOT = REPO / "frontends/godot/project"
WINDOWS = os.name == 'nt'
CASES = ('graph', 'codex-daemon', 'claude', 'cross', 'codex-local')
# Graph-link geometry now lives in the unit suite run by run.gd.
GRAPH = ('graph_editing_smoke.gd', 'run.gd', 'graph_link_animation_smoke.gd', 'agent_graph_smoke.gd')
sys.path[:0] = [str(Path(__file__).resolve().parents[2] / d) for d in ("tests/support",)]
from e2e_server import PrivateServer


def shell_command(command):
    """Quote argv for the native replay shell, including spaces and apostrophes."""
    return ("& " + ' '.join("'" + str(arg).replace("'", "''") + "'" for arg in command)
            if WINDOWS else shlex.join(command))


def private_json(path, data):
    path.write_text(json.dumps(data))
    path.chmod(0o600)


def preflight(directory, require_daemon=False):
    """Report environmental blockers before copying credentials or spending tokens."""
    errors = []
    if WINDOWS and require_daemon:
        import ctypes
        if ctypes.windll.shell32.IsUserAnAdmin():
            errors.append('Codex daemon refuses elevated Windows launches; run in a non-elevated interactive desktop terminal')
    try:
        command = (['tasklist.exe', '/FI', f'PID eq {os.getpid()}', '/NH'] if WINDOWS
                   else ['ps', '-p', str(os.getpid()), '-o', 'pid='])
        result = subprocess.run(command, capture_output=True, timeout=5)
        if result.returncode:
            errors.append('OS process inspection is denied (ps); PID discovery cannot run')
    except (OSError, subprocess.TimeoutExpired) as exc:
        errors.append(f'OS process inspection unavailable: {exc}')
    probes = [(socket.AF_INET, ('127.0.0.1', 0))]
    if not WINDOWS:
        probes.insert(0, (socket.AF_UNIX, str(directory / 'probe.sock')))
    for family, address in probes:
        try:
            with socket.socket(family) as probe:
                probe.bind(address)
        except OSError as exc:
            errors.append(f'{"Unix" if family != socket.AF_INET else "Loopback TCP"} socket unavailable: {exc}')
    (directory / 'probe.sock').unlink(missing_ok=True)
    return errors


def seed_auth(env, codex_home, claude_home, original):
    """Copy only auth, never personal agent settings, projects, or transcripts."""
    secrets = []
    codex_source = Path(original.get('CODEX_HOME', str(Path.home() / '.codex')))
    if (codex_source / 'auth.json').is_file():
        dst = codex_home / 'auth.json'
        shutil.copyfile(codex_source / 'auth.json', dst)
        dst.chmod(0o600)
        secrets.append(dst)
    # Install a private daemon package from the CLI under test. The install
    # runs offline. `live_case()` deletes it after the test.
    #
    # Keep the real home's `packages` directory separate. Even without an
    # update, the daemon rewrites `packages/app-server-daemon/current` to an
    # absolute path under the temporary home. Sharing the directory would
    # break the real account's daemon when that temporary path is removed.
    if (codex_source / 'models_cache.json').is_file():
        shutil.copyfile(codex_source / 'models_cache.json', codex_home / 'models_cache.json')
    claude_source = Path(original.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude')))
    if not (env.get('ANTHROPIC_API_KEY') or env.get('CLAUDE_CODE_OAUTH_TOKEN')):
        # On macOS Claude Code keeps the login it refreshes in the Keychain, one
        # item per config directory. A .credentials.json beside it is only as
        # fresh as whatever last copied it there, so the Keychain comes first.
        if sys.platform == 'darwin':
            service = 'Claude Code-credentials'
            if original.get('CLAUDE_CONFIG_DIR'):
                service += '-' + hashlib.sha256(str(claude_source).encode()).hexdigest()[:8]
            result = subprocess.run(['security', 'find-generic-password', '-s', service, '-w'], capture_output=True, timeout=10)
            if result.returncode == 0:
                try:
                    token = json.loads(result.stdout).get('claudeAiOauth', {}).get('accessToken')
                except ValueError:
                    token = None
                if token:
                    env['CLAUDE_CODE_OAUTH_TOKEN'] = token  # never written to artifacts
        credential = claude_source / '.credentials.json'
        if not env.get('CLAUDE_CODE_OAUTH_TOKEN') and credential.is_file():
            dst = claude_home / '.credentials.json'
            shutil.copyfile(credential, dst)
            dst.chmod(0o600)
            secrets.append(dst)
    return secrets


def execute(command, env, logfile, timeout):
    started = time.monotonic()
    with logfile.open('w') as log:
        process = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as interrupted:
            if WINDOWS:
                subprocess.run(['taskkill.exe', '/PID', str(process.pid), '/T', '/F'],
                               capture_output=True, timeout=10)
            else:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if WINDOWS:
                    process.kill()
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            if isinstance(interrupted, KeyboardInterrupt):
                raise
            return {'status': 'FAIL', 'reason': 'Timed out', 'log': str(logfile)}
    return {'status': 'PASS' if code == 0 else 'FAIL', 'exit_code': code,
            'seconds': round(time.monotonic() - started, 2), 'log': str(logfile)}


def execute_godot(command, env, logfile, timeout, shell):
    """The replay owns its server and state even when the GUI exits early."""
    # Drop the caller's session, keep what this runner set for the replay.
    env = {key: value for key, value in env.items()
           if not key.startswith('GRAFFITTY_')
           or key in ('GRAFFITTY_E2E_MANIFEST', 'GRAFFITTY_TEST_SERVER')}
    directory = logfile.parent / (logfile.stem + '-runtime')
    directory.mkdir(mode=0o700)
    if WINDOWS and env.get('LOCALAPPDATA'):
        # Isolate application state without making profile activation reinstall
        # the user's toolchain under the test's XDG_DATA_HOME.
        env.setdefault('MISE_DATA_DIR', str(Path(env['LOCALAPPDATA']) / 'mise'))
    for kind in ('CONFIG', 'STATE', 'CACHE', 'DATA'):
        env['XDG_' + kind + '_HOME'] = str(directory / kind.lower())
    with PrivateServer(env, directory, shell):
        return execute(command, env, logfile, timeout)


def stop_private_codex_helpers(codex_home):
    """The daemon's detached PID updater can outlive `daemon stop`."""
    if WINDOWS:
        result = subprocess.run(
            ['powershell.exe', '-NoProfile', '-Command',
             "Get-CimInstance Win32_Process -Filter \"Name = 'codex.exe'\" | Select-Object ProcessId,ExecutablePath,CommandLine | ConvertTo-Json -Compress"],
            capture_output=True, text=True, check=True, timeout=15)
        rows = json.loads(result.stdout or '[]')
        if isinstance(rows, dict):
            rows = [rows]
        packages = (codex_home / 'packages').resolve()
        for row in rows:
            executable = row.get('ExecutablePath')
            command = row.get('CommandLine') or ''
            if not executable or not command.endswith(' app-server daemon pid-update-loop'):
                continue
            if not Path(executable.removeprefix('\\\\?\\')).resolve().is_relative_to(packages):
                continue
            subprocess.run(['taskkill.exe', '/PID', str(row['ProcessId']), '/F'],
                           capture_output=True, check=False, timeout=10)
        return
    try:
        result = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True,
                                text=True, check=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return
    prefix = str(codex_home / 'packages') + '/'
    for row in result.stdout.splitlines():
        fields = row.strip().split(None, 1)
        if len(fields) != 2:
            continue
        pid, command = fields
        if command.startswith(prefix) and command.endswith('codex app-server daemon pid-update-loop'):
            try:
                os.kill(int(pid), signal.SIGTERM)
            except ProcessLookupError:
                pass


def restrict_windows_directory(directory):
    if not WINDOWS:
        return
    identity = subprocess.run(['whoami.exe', '/user', '/fo', 'csv', '/nh'],
                              capture_output=True, text=True, check=True, timeout=10)
    import csv
    sid = next(csv.reader(identity.stdout.splitlines()))[-1]
    if not sid.startswith('S-1-') or not all(c.isdigit() or c == '-' for c in sid[4:]):
        raise ValueError('Invalid current-user SID')
    subprocess.run(['icacls.exe', str(directory), '/inheritance:r', '/grant:r', f'*{sid}:(OI)(CI)F'],
                   capture_output=True, check=True, timeout=10)


def live_case(case, args, directory):
    # Provider sockets have a much shorter path limit than evidence files.
    # Shared catalog output is deeply nested; keep private homes independent.
    # Windows AF_UNIX has the same short limit; protect the short runtime itself.
    runtime_parent = REPO / '.cache' if WINDOWS else Path('/tmp')
    runtime_parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ga-', dir=runtime_parent) as runtime:
        runtime = Path(runtime).resolve()
        restrict_windows_directory(runtime)
        blockers = preflight(runtime, require_daemon=case in ('codex-daemon', 'cross'))
        for binary in ('codex', 'claude'):
            if not shutil.which(binary):
                blockers.append(f'{binary} is not installed')
        if blockers:
            return {'status': 'BLOCKED', 'reasons': blockers}
        return run_live_case(case, args, directory, runtime)


# What a Claude Code child process may inherit: how it authenticates and which
# provider it calls. Everything else named CLAUDE_CODE_* describes the session
# that launched this runner.
CLAUDE_CODE_KEPT = ('CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX')


def live_environment(original):
    """The agents' environment, without the session an agent runner was started from.

    A runner started by a coding agent inherits that agent's session markers.
    Claude Code then treats the test's Claude as a child of that session and
    saves no transcript, which is where the assertions read replies from.
    """
    def inherited(key):
        if key.startswith('CLAUDE_CODE_'):
            return key in CLAUDE_CODE_KEPT
        return not (key.startswith('GRAFFITTY_') or key in (
            'CLAUDECODE', 'CLAUDE_PID', 'CLAUDE_EFFORT', 'CODEX_THREAD_ID', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE'))
    return {key: value for key, value in original.items() if inherited(key)}


def run_live_case(case, args, directory, runtime):
    env = live_environment(os.environ)
    codex_home, claude_home, work = [runtime / n for n in ('codex', 'claude', 'work')]
    for path in (codex_home, claude_home, work):
        path.mkdir(mode=0o700)
    env.update(CODEX_HOME=str(codex_home), CLAUDE_CONFIG_DIR=str(claude_home),
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1',
               CLAUDE_CODE_MAX_OUTPUT_TOKENS='512', MAX_THINKING_TOKENS='0')
    secrets = []
    try:
        server = Path(getattr(args, 'server_binary', None) or os.environ.get('GRAFFITTY_TEST_SERVER')
                      or REPO / ('dist/bin/gft.exe' if WINDOWS else 'dist/bin/gft')).resolve()
        env['GRAFFITTY_TEST_SERVER'] = str(server)
        # Installed provider hooks resolve gft through PATH. Use the same
        # frozen executable for those hooks and the Godot owner.
        env['PATH'] = str(server.parent) + os.pathsep + env.get('PATH', '')
        secrets = seed_auth(env, codex_home, claude_home, os.environ)
        (codex_home / 'config.toml').write_text(
            f'model = {json.dumps(args.codex_model)}\nmodel_reasoning_effort = "low"\n'
            'check_for_update_on_startup = false\napproval_policy = "never"\nsandbox_mode = "read-only"\n'
            f'[projects.{json.dumps(str(work))}]\ntrust_level = "trusted"\n')
        private_json(claude_home / '.claude.json', {'hasCompletedOnboarding': True,
                     'projects': {work.as_posix(): {'hasTrustDialogAccepted': True}}})
        private_json(claude_home / 'settings.json', {'model': args.claude_model, 'fallbackModel': [],
                     'availableModels': [args.claude_model], 'enforceAvailableModels': True})
        for provider in ('codex', 'claude'):
            result = subprocess.run([str(server), 'integrate', provider, '--apply'],
                                    cwd=work, env=env, capture_output=True, timeout=20)
            if result.returncode:
                return {'status': 'FAIL', 'reason': f'{provider} isolated integration setup failed'}
        manifest = {'case': case, 'work': work.as_posix(), 'timeout': args.turn_timeout,
                    'codex_model': args.codex_model, 'claude_model': args.claude_model,
                    'nonce': os.urandom(6).hex(), 'evidence': str(directory / 'evidence.json')}
        manifest['source_command'] = shell_command([
            sys.executable,
            str(REPO / 'tests/fixtures/agent_source_node.py'),
        ])
        private_json(claude_home / 'mcp-empty.json', {'mcpServers': {}})
        for provider, command in {
            'codex': [shutil.which('codex'), '-m', args.codex_model],
            'claude': [shutil.which('claude'), '--model', args.claude_model, '--effort', 'low',
                       '--permission-mode', 'dontAsk', '--tools', '', '--strict-mcp-config', '--mcp-config', str(claude_home / 'mcp-empty.json'), '--'],
        }.items():
            if provider == 'codex' and case == 'codex-local':
                command += ['--no-daemon']
            command[0] = Path(command[0]).as_posix()
            manifest[provider + '_command'] = shell_command(command)
            if WINDOWS:
                # Interactive PowerShell profiles (including mise activation)
                # can replace inherited PATH. Restore the frozen CLI after
                # startup so real installed hooks resolve this fixture's build.
                prefix = str(server.parent).replace("'", "''")
                manifest[provider + '_command'] = (
                    "$env:PATH = '" + prefix + ";' + $env:PATH; "
                    + manifest[provider + '_command'])
        private_json(directory / 'manifest.json', manifest)
        env['GRAFFITTY_E2E_MANIFEST'] = str(directory / 'manifest.json')
        result = execute_godot([args.godot, *([] if WINDOWS else ['--headless']), '--path', str(GODOT_ROOT), '--script',
                          str(REPO / 'tests/llm-e2e/suites/godot/agent-graph/replays/live-agents.gd'), '--', '--shell=' + args.shell],
                         env, directory / 'replay.log', args.case_timeout, args.shell)
        if result['status'] == 'PASS' and not Path(manifest['evidence']).is_file():
            result.update(status='FAIL', reason='Replay exited without completion evidence')
        if Path(manifest['evidence']).is_file():
            evidence = json.loads(Path(manifest['evidence']).read_text(encoding='utf-8'))
            blocker = evidence.get('provider_blocker')
            # Never hide an application assertion failure behind an account limit.
            if blocker and evidence.get('failures') == [blocker]:
                result.update(status='BLOCKED', reason=blocker)
        return result
    finally:
        # Only this test's daemon: CODEX_HOME is isolated; never touch the user daemon.
        if (codex_home / 'app-server-control/app-server-control.sock').exists():
            try:
                subprocess.run([shutil.which('codex'), 'app-server', 'daemon', 'stop'], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            except subprocess.TimeoutExpired:
                pass
        # The private daemon package is a ~300 MB copy of the CLI; keep only logs and evidence.
        stop_private_codex_helpers(codex_home)
        shutil.rmtree(codex_home / 'packages', ignore_errors=True)
        for path in secrets + [claude_home / '.credentials.json', claude_home / '.claude.json', codex_home / 'auth.json']:
            path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=(*CASES, 'all'), default='all')
    parser.add_argument('--codex-model', default='gpt-6-luna')
    parser.add_argument('--claude-model', default='claude-haiku-4-5-20251001')
    parser.add_argument('--godot', default=shutil.which('godot') or 'godot')
    parser.add_argument('--server-binary', type=Path,
                        help='Use this server/CLI for isolated integration test sessions')
    parser.add_argument('--shell', default=(shutil.which('pwsh.exe') or shutil.which('powershell.exe') or 'powershell.exe') if WINDOWS else '/bin/sh')
    parser.add_argument('--turn-timeout', type=int, default=90)
    parser.add_argument('--case-timeout', type=int, default=480)
    parser.add_argument('--output', '--evidence', dest='output', type=Path)
    args = parser.parse_args()
    if WINDOWS and args.godot.endswith("_console.exe"):
        # Godot's console wrapper can outlive the GUI while detached provider
        # daemons retain its output handles. Wait on the actual engine process.
        engine = Path(args.godot.removesuffix("_console.exe") + ".exe")
        if engine.is_file():
            args.godot = str(engine)
    root = args.output or Path(tempfile.mkdtemp(prefix='graffitty-live-e2e-'))
    root = root.resolve()  # Canonical cwd is required by provider trust.
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    restrict_windows_directory(root)
    cases = CASES if args.case == 'all' else (args.case,)
    results = {}
    for case in cases:
        directory = root / case
        directory.mkdir(mode=0o700, exist_ok=False)
        if case == 'graph':
            for script in GRAPH:
                blockers = preflight(directory) if script == 'agent_graph_smoke.gd' else []
                result = ({'status': 'BLOCKED', 'reasons': blockers} if blockers else
                          execute_godot([args.godot, '--headless', '--path', str(GODOT_ROOT), '--script', 'tests/' + script, '--', '--shell=' + args.shell],
                                  {key: value for key, value in os.environ.items() if not key.startswith(('GRAFFITTY_', 'CODEX_THREAD', 'CODEX_SESSION'))},
                                  directory / (script + '.log'), 90, args.shell))
                results[script] = result
                print(script, result['status'], flush=True)
        else:
            try:
                results[case] = live_case(case, args, directory)
            except (OSError, ValueError, subprocess.SubprocessError) as exc:
                results[case] = {'status': 'FAIL', 'reason': f'{type(exc).__name__}: {exc}'}
            print(case, results[case]['status'], flush=True)
    report = {'models': {'codex': args.codex_model, 'effort': 'low', 'claude': args.claude_model}, 'results': results}
    private_json(root / 'report.json', report)
    print('Report:', root / 'report.json')
    statuses = {r['status'] for r in results.values()}
    return 1 if 'FAIL' in statuses else 2 if 'BLOCKED' in statuses else 0

if __name__ == '__main__':
    raise SystemExit(main())
