"""Unit tests for cgroup attribution and endurance failure evidence; no browser."""
import argparse
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from linux_chromium_stress_e2e import memory
import linux_chromium_endurance_e2e as endurance


class MemoryTest(unittest.TestCase):
    def test_breakdown_keeps_total_charge_and_does_not_add_shared_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); proc = root / 'proc'; cg = root / 'cgroup'
            (proc / '10/fd').mkdir(parents=True)
            (proc / '10/status').write_text('VmRSS:\t20 kB\n')
            (proc / '11').mkdir()
            (proc / '11/cgroup').write_text('0::/godot-terminal-10-1\n')
            (proc / '11/stat').write_text('11 (browser) ' + ' '.join(['0'] * 19 + ['123']))
            (proc / '11/cmdline').write_bytes(b'host\0')
            (proc / '11/smaps_rollup').write_text('Rss: 60 kB\nPss: 30 kB\nPss_Anon: 12 kB\nPss_File: 18 kB\n')
            group = cg / 'godot-terminal-10-1'; group.mkdir(parents=True)
            (group / 'memory.current').write_text('999999')
            (group / 'memory.stat').write_text('anon 12000\nfile 987999\nshmem 5000\n')
            (group / 'memory.events').write_text('oom 0\noom_kill 0\n')
            (group / 'cgroup.procs').write_text('11\n12\n') # Child 12 exited.
            result = memory(10, 11, proc_root=proc, cgroup_root=cg)
            self.assertEqual(result['browser_cgroup'], 999999)
            self.assertEqual(result['server_rss'], 20480)
            self.assertEqual(result['browser_memory_stat']['file'], 987999)
            self.assertEqual(len(result['browser_process_memory']), 1)
            self.assertEqual(result['browser_process_memory'][0]['smaps_bytes']['Pss_File'], 18432)
            (proc / '11/cgroup').write_text('0::/another-fixture\n')
            with self.assertRaisesRegex(AssertionError, 'fixture-owned'):
                memory(10, 11, proc_root=proc, cgroup_root=cg)


class EnduranceTest(unittest.TestCase):
    def test_profile_components_are_attributed_without_following_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); profile = root/'profile'; component = profile/'component_crx_cache'
            component.mkdir(parents=True)
            (component/'data').write_bytes(b'abc')
            (root/'outside').write_bytes(b'not a profile file')
            (profile/'link').symlink_to(root/'outside')
            report = endurance.profile_storage(profile)
            self.assertEqual(report['components']['component_crx_cache']['bytes'], 3)
            self.assertNotIn('link', report['components'])

    def test_growth_failure_still_decodes_all_fixtures_and_checks_gpu_cleanup(self):
        fixtures = []; decoded = []
        clock = SimpleNamespace(now=0.)
        clock.monotonic = lambda: clock.now
        clock.sleep = lambda seconds: setattr(clock, 'now', clock.now + seconds)
        class Stream:
            sample = [b'x'] * 60
            latest = True
            def __init__(self, fixture): self.fixture = fixture; fixture.streams += 1
            def close(self): self.fixture.streams -= 1
            def reset_sample(self): pass
            def stats(self, _): return {'fps': 15, 'longest_gap_s': .1}
        class Fixture:
            def __init__(self, args):
                self.out = args.output; self.out.mkdir()
                self.name = args.platform + '-' + args.backend
                self.server = SimpleNamespace(pid=len(fixtures) + 1)
                self.rpc = self.name; self.clients = []; self.streams = 0; self.active = True
                fixtures.append(self)
            def __enter__(self): return self
            def __exit__(self, *_): self.active = False; self.streams = 0
            def page(self, _):
                profile = self.out/'profile'; profile.mkdir()
                self.owner = SimpleNamespace(topology={'chromiums': [{'id': self.server.pid, 'state': {'profile': str(profile)}}]})
                return self.name, self.server.pid, self.server.pid
            def stream(self, *_args, **_kwargs):
                stream = Stream(self); self.clients.append(stream); return stream
        def gpu(_):
            return {'fixtures': {f.name: {'server_host_pid': f.server.pid if f.active else None,
                'gpu_memory': 0, 'encoder_sessions': f.streams} for f in fixtures}}
        def sample_memory(server, host):
            growth = 300 * 1024**2 if host == 4 and clock.now > 400 else 0
            return {'server_rss': 10, 'browser_cgroup': 100 + growth, 'server_fds': 4}
        def eventually(predicate, message, **_):
            value = predicate()
            assert value, message
            return value
        def decode(_stream, out, phase, _channel):
            decoded.append((out.name, phase)); return {'decoded_frames': 60}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); binary = root / 'binary'; binary.write_bytes(b'test')
            args = argparse.Namespace(output=root/'evidence', server=binary, host=binary, seconds=1800, smoke=False)
            with patch.multiple(endurance, Fixture=Fixture, gpu=gpu, memory=sample_memory,
                                time=clock, eventually=eventually, decode_color=decode,
                                evaluate=lambda rpc, *_: rpc):
                with self.assertRaises(AssertionError): endurance.run(args)
            result = json.loads((args.output/'results.json').read_text())
            self.assertEqual(result['status'], 'fail')
            self.assertTrue(result.get('gpu_reclaimed'), result)
            self.assertEqual(len([d for d in decoded if d[1] == 'final']), 4)
            self.assertEqual(result['failures'][0]['fixture'], 'x11-alloy')
            self.assertEqual(result['failures'][0]['check'], 'browser_cgroup')
            self.assertEqual(result['failures'][0]['allowance'], 256 * 1024**2)
            self.assertTrue((args.output/'gpu-stop').exists())


if __name__ == '__main__': unittest.main()
