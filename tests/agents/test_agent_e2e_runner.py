"""Runner checks only; these never stand in for real-provider E2E results."""
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import socket
import tempfile
import unittest
from unittest.mock import patch, MagicMock

spec = importlib.util.spec_from_file_location('agent_e2e', Path(__file__).resolve().parents[2] / 'tests/agents/test_agent_e2e.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class RunnerTests(unittest.TestCase):
    def test_live_runner_uses_the_frozen_server_and_private_provider_homes(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory).resolve()
            evidence=root/'evidence';evidence.mkdir()
            runtime=root/'runtime';runtime.mkdir()
            args=SimpleNamespace(godot='godot',shell='/bin/sh',server_binary=root/'frozen-gft',
                                 codex_model='requested-codex',claude_model='requested-claude',
                                 turn_timeout=90,case_timeout=480)
            def execute_godot(command,env,logfile,timeout,shell):
                self.assertTrue(command[-3].endswith('live-agents.gd'))
                self.assertEqual(env['GRAFFITTY_TEST_SERVER'],str(args.server_binary))
                self.assertNotIn('GRAFFITTY_SESSION',env)
                self.assertNotIn('GRAFFITTY_SERVER',env)
                self.assertEqual(env['CODEX_HOME'],str(runtime/'codex'))
                self.assertEqual(env['CLAUDE_CONFIG_DIR'],str(runtime/'claude'))
                manifest=json.loads(Path(env['GRAFFITTY_E2E_MANIFEST']).read_text())
                self.assertEqual(manifest['work'],(runtime/'work').as_posix())
                self.assertIn('agent_source_node.py',manifest['source_command'])
                self.assertNotIn(' adapter ',manifest['source_command'])
                if runner.WINDOWS:
                    for provider in ('codex', 'claude'):
                        self.assertTrue(manifest[provider + '_command'].startswith(
                            "$env:PATH = '" + str(args.server_binary.parent).replace("'", "''") + ";' + $env:PATH; & "))
                Path(manifest['evidence']).write_text('{"failures":[]}')
                return {'status':'PASS'}
            with patch.dict(os.environ,{'GRAFFITTY_SERVER':'personal-server','GRAFFITTY_SESSION':'personal-session'}), \
                 patch.object(runner,'seed_auth',return_value=[]), \
                 patch.object(runner.shutil,'which',side_effect=lambda name:'/provider/'+name), \
                 patch.object(runner.subprocess,'run',return_value=MagicMock(returncode=0,stdout='')) as run, \
                 patch.object(runner,'stop_private_codex_helpers'), \
                 patch.object(runner,'execute') as execute, \
                 patch.object(runner,'execute_godot',side_effect=execute_godot):
                result=runner.run_live_case('cross',args,evidence,runtime)
            self.assertEqual(result['status'],'PASS')
            execute.assert_not_called()
            self.assertEqual([call.args[0][0] for call in run.call_args_list],[str(args.server_binary)]*2)

    def test_agents_do_not_inherit_the_session_that_launched_the_runner(self):
        env=runner.live_environment({
            'PATH':'/usr/bin','HOME':'/home/user','CODEX_HOME':'/accounts/work','CLAUDE_CONFIG_DIR':'/accounts/claude',
            'CLAUDE_CODE_OAUTH_TOKEN':'token','CLAUDE_CODE_USE_BEDROCK':'1',
            'CLAUDECODE':'1','CLAUDE_PID':'7','CLAUDE_EFFORT':'low',
            'CLAUDE_CODE_CHILD_SESSION':'1','CLAUDE_CODE_SESSION_ID':'abc','CLAUDE_CODE_MESSAGING_SOCKET':'/tmp/s',
            'CODEX_THREAD_ID':'thread','GRAFFITTY_SESSION':'$1'})
        self.assertEqual(sorted(env),['CLAUDE_CODE_OAUTH_TOKEN','CLAUDE_CODE_USE_BEDROCK','CLAUDE_CONFIG_DIR','CODEX_HOME','HOME','PATH'])

    def test_cleanup_only_stops_the_private_daemon_pid_updater(self):
        result = MagicMock(stdout='101 /tmp/fixture/codex/packages/release/bin/codex app-server daemon pid-update-loop\n102 /tmp/other/codex/packages/release/bin/codex app-server daemon pid-update-loop\n103 /tmp/fixture/codex/packages/release/bin/codex app-server daemon run\n')
        with patch.object(runner, 'WINDOWS', False), patch.object(runner.subprocess, 'run', return_value=result), patch.object(runner.os, 'kill') as kill:
            runner.stop_private_codex_helpers(PurePosixPath('/tmp/fixture/codex'))
        kill.assert_called_once_with(101, runner.signal.SIGTERM)

    def test_source_node_command_preserves_native_shell_arguments(self):
        import shlex
        import shutil
        import subprocess
        import sys
        values = ["path with spaces", "O'Brien", "$literal; & stays literal"]
        command = [sys.executable, '-c', 'import json,sys; print(json.dumps(sys.argv[1:]))', *values]
        with patch.object(runner, 'WINDOWS', False):
            self.assertEqual(shlex.split(runner.shell_command(command)), command)
        if runner.WINDOWS:
            shell = shutil.which('pwsh.exe') or shutil.which('powershell.exe')
            result = subprocess.run([shell, '-NoProfile', '-NonInteractive', '-Command', runner.shell_command(command)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), values)

    @unittest.skipUnless(os.name == 'nt', 'Windows process paths')
    def test_windows_cleanup_keeps_other_homes_and_non_helper_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory).resolve() / 'codex'
            own = str(home / 'packages/release/bin/codex.exe')
            rows = [
                {'ProcessId': 101, 'ExecutablePath': '\\\\?\\' + own, 'CommandLine': 'codex app-server daemon pid-update-loop'},
                {'ProcessId': 102, 'ExecutablePath': str(home.parent / 'other/codex.exe'), 'CommandLine': 'codex app-server daemon pid-update-loop'},
                {'ProcessId': 103, 'ExecutablePath': own, 'CommandLine': 'codex app-server daemon run'},
            ]
            with patch.object(runner.subprocess, 'run', return_value=MagicMock(stdout=json.dumps(rows))) as run:
                runner.stop_private_codex_helpers(home)
            self.assertEqual(len(run.call_args_list), 2)
            self.assertEqual(run.call_args_list[-1].args[0], ['taskkill.exe', '/PID', '101', '/F'])

    def test_denied_process_and_socket_operations_are_reported_not_raised(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.subprocess, 'run', side_effect=PermissionError('ps denied')), patch.object(runner.socket, 'socket', side_effect=PermissionError('socket denied')):
            errors = runner.preflight(Path(directory))
        self.assertEqual(len(errors), 2 if runner.WINDOWS else 3)
        self.assertIn('process inspection unavailable', errors[0])

    def test_live_preflight_does_not_copy_credentials_or_launch_models_when_blocked(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(runner, 'preflight', return_value=['socket denied']), patch.object(runner, 'seed_auth') as auth, patch.object(runner, 'execute') as execute:
            result = runner.live_case('cross', None, Path(directory))
        self.assertEqual(result['status'], 'BLOCKED')
        auth.assert_not_called()
        execute.assert_not_called()

    def test_isolated_home_shares_nothing_with_the_real_codex_home(self):
        # Keep the isolated home's daemon packages separate. The updater writes
        # an absolute path under that home to `packages/app-server-daemon/current`.
        # Sharing the directory would leave the real account pointing to a
        # deleted path after cleanup.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source, codex_home, claude_home = root / 'source', root / 'codex', root / 'claude'
            (source / 'packages/app-server-daemon/releases/9.9.9-test').mkdir(parents=True)
            (source / 'packages/app-server-daemon/current').write_text('selected')
            (source / 'auth.json').write_text('{}')
            (source / 'models_cache.json').write_text('{}')
            codex_home.mkdir()
            claude_home.mkdir()
            # An API key keeps seed_auth away from the Claude credential file and keychain.
            runner.seed_auth({'ANTHROPIC_API_KEY': 'test'}, codex_home, claude_home,
                             {'CODEX_HOME': str(source), 'CLAUDE_CONFIG_DIR': str(root / 'claude-source')})
            self.assertTrue((codex_home / 'auth.json').is_file())
            for path in codex_home.rglob('*'):
                resolved = path.resolve()
                self.assertNotIn(source, (resolved, *resolved.parents), f'{path} reaches the real Codex home')
            self.assertFalse(os.path.lexists(codex_home / 'packages'))

    def test_nested_evidence_uses_short_private_provider_paths(self):
        homes = []
        def run_case(case, args, evidence, runtime):
            homes.append(runtime)
            self.assertTrue(runtime.is_dir())
            if not runner.WINDOWS:
                self.assertLess(len(os.fsencode(runtime / 'codex/app-server-control/app-server-control.sock')), 104)
            return {'status': 'PASS'}
        with tempfile.TemporaryDirectory() as directory, patch.object(runner, 'preflight', return_value=[]), patch.object(runner.shutil, 'which', return_value='/test/provider'), patch.object(runner, 'run_live_case', side_effect=run_case):
            evidence = Path(directory) / ('deep-' * 30)
            self.assertEqual(runner.live_case('cross', None, evidence)['status'], 'PASS')
        self.assertFalse(homes[0].exists())

    def test_reports_are_private_and_machine_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            runner.private_json(path, {'status': 'BLOCKED'})
            if not runner.WINDOWS:  # Windows privacy is the enclosing test root ACL.
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text())['status'], 'BLOCKED')

    def test_timeout_terminates_only_the_test_process_group(self):
        process = MagicMock(pid=424242)
        process.wait.side_effect = [runner.subprocess.TimeoutExpired('fixture', 1), 0]
        with tempfile.TemporaryDirectory() as directory, patch.object(runner.subprocess, 'Popen', return_value=process) as launch, patch.object(runner.os, 'killpg', create=True) as kill, patch.object(runner.subprocess, 'run') as taskkill:
            result = runner.execute(['fixture'], {}, Path(directory) / 'run.log', 1)
        self.assertEqual(result['status'], 'FAIL')
        if runner.WINDOWS:
            taskkill.assert_called_once_with(['taskkill.exe', '/PID', '424242', '/T', '/F'], capture_output=True, timeout=10)
            kill.assert_not_called()
        else:
            kill.assert_called_once_with(424242, runner.signal.SIGTERM)
        self.assertTrue(launch.call_args.kwargs['start_new_session'])

if __name__ == '__main__':
    unittest.main()
