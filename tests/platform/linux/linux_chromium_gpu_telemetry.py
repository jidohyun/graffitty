#!/usr/bin/env python3
# /// script
# dependencies = ["nvidia-ml-py>=13,<14"]
# ///
"""Read-only host-side NVML sampling for explicitly owned container fixtures.

Resolve each container PID using both NSpid and the exact private --connection
argument. Never attribute unrelated desktop processes to the test.
"""
import argparse
import json
import os
from pathlib import Path
import time
import pynvml as nv


def processes():
    result = {}
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            stat = (path / 'stat').read_text().rsplit(')', 1)[1].split()
            result[int(path.name)] = (int(stat[1]), int(stat[19]))
        except (OSError, ValueError, IndexError):
            pass
    return result


def root(entry, table):
    candidates = []
    for pid in table:
        try:
            args = (Path('/proc') / str(pid) / 'cmdline').read_bytes().split(b'\0')
            connection = args.index(b'--connection') + 1
            if args[connection].decode() != entry['connection_path']:
                continue
            namespaces = next(s.split()[1:] for s in (Path('/proc') / str(pid) / 'status').read_text().splitlines() if s.startswith('NSpid:'))
            if int(namespaces[-1]) == entry['server']:
                candidates.append(pid)
        except (OSError, ValueError, IndexError, StopIteration):
            pass
    assert len(candidates) <= 1, 'Ambiguous owned server PID'
    return candidates[0] if candidates else None


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--stop-file', type=Path, required=True)
    args = parser.parse_args()
    nv.nvmlInit()
    handle = nv.nvmlDeviceGetHandleByIndex(0)
    owned = {}
    deadline = time.monotonic() + 180
    while not args.manifest.exists():
        if args.stop_file.exists():
            return
        assert time.monotonic() < deadline, 'Fixture manifest never appeared'
        time.sleep(1)
    entries = json.loads(args.manifest.read_text())
    while not args.stop_file.exists():
        table = processes()
        memory = {}
        for p in [*nv.nvmlDeviceGetComputeRunningProcesses(handle), *nv.nvmlDeviceGetGraphicsRunningProcesses(handle)]:
            assert 0 <= p.usedGpuMemory < 2**60, 'GPU memory accounting is unavailable'
            memory[p.pid] = max(memory.get(p.pid, 0), p.usedGpuMemory)
        sessions = nv.nvmlDeviceGetEncoderSessions(handle)
        report = {'at': time.time(), 'gpu_memory_total_used': nv.nvmlDeviceGetMemoryInfo(handle).used,
                  'gpu_name': nv.nvmlDeviceGetName(handle), 'fixtures': {}}
        for name, entry in entries.items():
            pid = root(entry, table)
            seen = owned.setdefault(name, {})
            family = {pid} if pid else set()
            while True:
                children = {p for p, (parent, _) in table.items() if parent in family}
                if children <= family:
                    break
                family |= children
            for member in family:
                if member in table:
                    seen[member] = table[member][1]
            alive = {p for p, identity in seen.items() if p in table and table[p][1] == identity}
            active = [s for s in sessions if s.pid in alive]
            report['fixtures'][name] = {'server_host_pid': pid, 'gpu_memory': sum(memory.get(p, 0) for p in alive),
                'encoder_sessions': len(active), 'gpu_processes': {str(p): memory[p] for p in alive if p in memory},
                'encoders': [{'pid': s.pid, 'session': s.sessionId, 'width': s.hResolution, 'height': s.vResolution} for s in active]}
        temporary = args.output.with_suffix('.tmp')
        temporary.write_text(json.dumps(report))
        temporary.replace(args.output)
        with args.output.with_suffix('.jsonl').open('a') as history:
            history.write(json.dumps(report) + '\n')
        time.sleep(5)
    nv.nvmlShutdown()


if __name__ == '__main__':
    main()
