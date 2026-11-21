#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2", "nvidia-ml-py>=13,<14"]
# ///
"""Multi-hour Chrome/Alloy x Wayland/X11 soak with owned-process GPU accounting.

Run linux_chromium_gpu_telemetry.py on the host against this run's manifest and
shared gpu.json. The 15 fps renditions leave encoder capacity for regular churn.
"""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import signal
import statistics
import sys
import time

sys.path[:0] = [str(Path(__file__).resolve().parents[3] / d) for d in ("tests/chromium",)]
from chromium_video_e2e import evaluate
from linux_chromium_lifecycle_e2e import Fixture, decode_color
from linux_chromium_stress_e2e import eventually, memory


def gpu(out):
    try:
        value = json.loads((out / 'gpu.json').read_text())
    except (OSError, json.JSONDecodeError):
        return None
    assert time.time() - value['at'] < 30, 'GPU telemetry stopped updating'
    return value


def profile_storage(profile):
    """Attribute optional component downloads without reading their contents."""
    components = {}
    raced_files = 0
    for directory, _, files in os.walk(profile):
        for name in files:
            path = Path(directory) / name
            if path.is_symlink():
                continue
            try:
                stat = path.stat()
            except FileNotFoundError:
                raced_files += 1
                continue
            component = path.relative_to(profile).parts[0]
            row = components.setdefault(component, {'bytes': 0, 'allocated_bytes': 0, 'files': 0})
            row['bytes'] += stat.st_size
            row['allocated_bytes'] += stat.st_blocks * 512
            row['files'] += 1
    return {'components': components, 'raced_files': raced_files}


def run(args):
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    runs, samples = {}, []
    results = {'status': 'running', 'failures': []}
    started = None
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    binaries = {'server': args.server.resolve(), 'host': args.host.resolve()}
    results['binary_sha256'] = {name: digest(path) for name, path in binaries.items()}
    results['source_sha256'] = {name: digest(Path(__file__).with_name(name)) for name in (
        'linux_chromium_endurance_e2e.py', 'linux_chromium_stress_e2e.py',
        'linux_chromium_lifecycle_e2e.py', 'linux_chromium_gpu_telemetry.py',
    )}
    try:
        with ExitStack() as cleanup:
            for platform in ('wayland', 'x11'):
                for backend in ('chrome', 'alloy'):
                    name = platform + '-' + backend
                    settings = argparse.Namespace(**vars(args))
                    settings.platform, settings.backend, settings.output = platform, backend, out / name
                    fixture = cleanup.enter_context(Fixture(settings))
                    page, sid, host = fixture.page(name)
                    quality = {'max_height': 360, 'fps': 15, 'bitrate_kbps': 1500}
                    fast = fixture.stream(sid, quality=quality)
                    eventually(lambda: len(fast.sample) >= 60, f'{name} did not start decoding')
                    fast.reset_sample()  # Exclude the browser's initial blank paint.
                    eventually(lambda: len(fast.sample) >= 60, f'{name} did not provide a settled sample')
                    decode_color(fast, fixture.out, 'initial', 0)
                    profile = Path(next(b['state']['profile'] for b in fixture.owner.topology['chromiums'] if b['id'] == sid))
                    runs[name] = (fixture, page, sid, host, fast, quality, profile)
            manifest = {name: {'server': f.server.pid, 'connection_path': str(f.out / 'connection.json')}
                        for name, (f, *_) in runs.items()}
            temp = out / 'manifest.tmp'
            temp.write_text(json.dumps(manifest))
            temp.replace(out / 'manifest.json')
            eventually(lambda: gpu(out), 'Host GPU telemetry did not start', timeout=45)
            eventually(lambda: all(v['server_host_pid'] and v['encoder_sessions'] == 1 for v in gpu(out)['fixtures'].values()),
                       'GPU telemetry did not find exactly one encoder per fixture')
            time.sleep(20)  # Every viewer needs a complete first measurement window.
            started = time.monotonic()
            iteration = 0
            with (out / 'samples.jsonl').open('w') as log:
                while time.monotonic() - started < args.seconds:
                    if (out / 'stop').exists():
                        raise InterruptedError('Endurance run was stopped before completion')
                    point = {'elapsed': time.monotonic() - started, 'fixtures': {}}
                    telemetry = gpu(out)
                    for name, (f, page, sid, host, fast, quality, profile) in runs.items():
                        assert evaluate(f.rpc, page, 'window.testIdentity') == name
                        live = fast.stats(time.monotonic() - 20)
                        assert live['fps'] >= 8 and live['longest_gap_s'] < 2, (name, live)
                        graphics = telemetry['fixtures'][name]
                        assert graphics['encoder_sessions'] == 1, (name, graphics)
                        point['fixtures'][name] = {**memory(f.server.pid, host), **graphics, 'video': live,
                                                   'profile_storage': profile_storage(profile)}
                    samples.append(point)
                    log.write(json.dumps(point) + '\n')
                    log.flush()
                    (out / 'progress.json').write_text(json.dumps({'elapsed': point['elapsed'], 'target': args.seconds, 'samples': len(samples)}))
                    # Exercise allocation and retirement in one fixture at a
                    # time, avoiding intentional exhaustion during endurance.
                    name = list(runs)[iteration % len(runs)]
                    f, page, sid, host, fast, quality, _ = runs[name]
                    late = f.stream(sid, quality=quality, ack_delay=.65)
                    try:
                        eventually(lambda: late.latest, 'Churn viewer failed to join')
                        eventually(lambda: gpu(out)['fixtures'][name]['encoder_sessions'] == 2,
                                   'Delayed viewer never allocated its private encoder')
                        time.sleep(5)
                    finally:
                        late.close()
                        f.clients.remove(late)
                    eventually(lambda: gpu(out)['fixtures'][name]['encoder_sessions'] == 1,
                               'Private encoder was not retired after disconnect')
                    if iteration % 20 == 0:
                        checked = list(runs)[(iteration // 20) % len(runs)]
                        checked_fixture, _, _, _, checked_stream, _, _ = runs[checked]
                        checked_stream.reset_sample()
                        eventually(lambda: len(checked_stream.sample) >= 60, 'Periodic decode sample did not arrive')
                        decode_color(checked_stream, checked_fixture.out, f'periodic-{iteration}', 0)
                    iteration += 1
                    delay = started + iteration * 30 - time.monotonic()
                    if delay > 0:
                        time.sleep(min(delay, 30))
            assert args.smoke or len(samples) >= 60, 'Too few endurance samples'
            early = [s for s in samples if 120 <= s['elapsed'] <= 300]
            late = samples[-10:]
            assert args.smoke or (len(early) >= 5 and late[0]['elapsed'] > 300)
            for name, (f, page, sid, host, fast, quality, _) in runs.items():
                growth = {}
                for key, allowance in [('server_rss', 128 * 1024**2), ('browser_cgroup', 256 * 1024**2),
                                       ('server_fds', 4), ('gpu_memory', 128 * 1024**2)]:
                    if args.smoke:
                        continue
                    first = statistics.median(s['fixtures'][name][key] for s in early)
                    last = statistics.median(s['fixtures'][name][key] for s in late)
                    growth[key] = {'early': first, 'late': last, 'growth': last-first,
                                   'peak': max(s['fixtures'][name][key] for s in samples), 'allowance': allowance}
                    if last-first > allowance:
                        results['failures'].append({'fixture': name, 'check': key, **growth[key]})
                results[name] = {'growth': growth}
                # A resource-limit failure must not suppress final decoding for
                # this/other fixtures or the GPU-reclamation check after teardown.
                try:
                    fast.reset_sample()
                    eventually(lambda: len(fast.sample) >= 60, 'Final video sample missing')
                    results[name]['decode'] = decode_color(fast, f.out, 'final', 0)
                except Exception as error:
                    results['failures'].append({'fixture': name, 'check': 'final_decode', 'error': str(error)})
            results['duration_seconds'] = time.monotonic()-started
            results['samples'] = len(samples)
        # The host monitor retains process identities through server shutdown,
        # so orphaned GPU processes cannot disappear from accounting unnoticed.
        eventually(lambda: all(v['gpu_memory'] == 0 and v['encoder_sessions'] == 0 and v['server_host_pid'] is None
                               for v in gpu(out)['fixtures'].values()), 'Owned GPU resources remained after shutdown')
        results['gpu_reclaimed'] = True
        assert results['binary_sha256'] == {name: digest(path) for name, path in binaries.items()}, 'Test binaries changed'
        assert not results['failures'], results['failures']
        results['status'] = 'smoke_pass' if args.smoke else 'pass'
        print('PASS endurance harness smoke' if args.smoke else 'PASS endurance', json.dumps({'seconds': results['duration_seconds'], 'samples': results['samples']}), flush=True)
    finally:
        if results['status'] == 'running':
            results['status'] = 'fail'
            error = sys.exc_info()[1]
            results['error'] = f'{type(error).__name__}: {error}' if error else 'Run did not finish'
        results['samples'] = len(samples)
        if started is not None:
            results['duration_seconds'] = time.monotonic() - started
        (out / 'results.json').write_text(json.dumps(results, indent=2))
        (out / 'gpu-stop').touch()


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--host', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=7200)
    parser.add_argument('--smoke', action='store_true', help='Only validate the harness; never report endurance coverage')
    args = parser.parse_args()
    if args.seconds < 7200 and not args.smoke:
        parser.error('Endurance requires at least 7200 seconds; shorter harness checks need --smoke')
    if args.seconds < 60:
        parser.error('Harness smoke checks require at least 60 seconds')
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    run(args)


if __name__ == '__main__':
    main()
