"""Observe original Windows process handles around a private fixture's close action."""
import json
from pathlib import Path
import sys
import time
from windows_relaunch_e2e import ProcessHandle


def main():
    directory = Path(sys.argv[1])
    handles = {}
    report = {'status': 'FAIL'}
    try:
        expected = json.loads((directory/'process-watch.json').read_text())
        for name, item in expected.items():
            handles[name] = ProcessHandle(item['pid'])
        assert all(not handle.exited() for handle in handles.values())
        (directory/'process-watch-ready').touch()
        deadline = time.monotonic() + 40
        while not (directory/'process-watch-close').exists():
            assert time.monotonic() < deadline, 'Fixture did not request close verification'
            time.sleep(.02)
        started = time.monotonic()
        for name, handle in handles.items():
            if expected[name]['exited']:
                assert handle.exited(max(0, int((started + 5 - time.monotonic()) * 1000))), name
            else:
                assert not handle.exited(), name
        report.update(status='PASS', seconds=time.monotonic()-started,
                      processes={name: {'pid': h.pid, 'birth': h.birth, 'exited': h.exited()} for name, h in handles.items()})
    except Exception as error:
        report['error'] = str(error)
    finally:
        # Observation only: fixture owns cleanup. Never terminate a survivor.
        for handle in handles.values():
            handle.api.CloseHandle(handle.handle)
        (directory/'process-receipt.json').write_text(json.dumps(report, indent=2))
    return report['status'] != 'PASS'


if __name__ == '__main__':
    sys.exit(main())
