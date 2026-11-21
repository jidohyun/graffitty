"""Opt-in AeroSpace isolation for windows belonging to a private test process.

Never changes global layout/rules or selects windows by title/application name.
"""
import argparse
import json
import os
from pathlib import Path
from types import SimpleNamespace
import shutil
import subprocess
import sys
import time


def owned_pid(pid, root):
    table = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True)
    parents = {int(p): int(parent) for p, parent in (line.split() for line in table.splitlines())}
    seen = set()
    while pid not in seen:
        if pid == root and pid in parents:
            return True
        seen.add(pid)
        pid = parents.get(pid, 0)
    return False


def float_test_windows(pid, owner, timeout=15):
    """Float only this owned PID's windows, returning before/after evidence.

    Call while the fixture owner is alive. A missing manager/window or ownership
    mismatch fails the test instead of falling back to global/focused commands.
    """
    assert sys.platform == 'darwin', 'AeroSpace isolation requires macOS'
    binary = shutil.which('aerospace')
    assert binary, 'AeroSpace is required for --float-test-windows'
    deadline = time.monotonic() + timeout
    while True:
        assert owner.poll() is None and owned_pid(pid, owner.pid), 'Window process is not owned by this live fixture'
        windows = json.loads(subprocess.check_output([
            binary, 'list-windows', '--monitor', 'all', '--pid', str(pid),
            '--format', '%{window-id} %{app-pid} %{window-layout}', '--json',
        ], text=True, timeout=5))
        if windows:
            break
        assert time.monotonic() < deadline, 'Owned native window did not appear'
        time.sleep(.1)
    for window in windows:
        assert int(window['app-pid']) == pid, window
        assert owner.poll() is None and owned_pid(pid, owner.pid), 'Fixture process exited before window isolation'
        subprocess.run([binary, 'layout', '--window-id', str(window['window-id']), 'floating'],
                       check=True, timeout=5)
    after = json.loads(subprocess.check_output([
        binary, 'list-windows', '--monitor', 'all', '--pid', str(pid),
        '--format', '%{window-id} %{app-pid} %{window-layout}', '--json',
    ], text=True, timeout=5))
    assert after and all(w['window-layout'] == 'floating' for w in after), after
    return {'pid': pid, 'before': windows, 'after': after}


def move_test_window(pid, owner, screen):
    """Move this fixture's floating window into the destination workspace.

    Godot indexes NSScreen.screens from 0. AeroSpace's format field indexes
    the same array from 1. Use that field to translate screen positions.
    AeroSpace monitor IDs can differ from their positions in the array.
    """
    assert screen >= 0
    isolation = float_test_windows(pid, owner)
    assert len(isolation['after']) == 1, 'Expected one fixture Godot window'
    binary = shutil.which('aerospace')
    monitors = json.loads(subprocess.check_output([
        binary, 'list-monitors', '--format',
        '%{monitor-id} %{monitor-appkit-nsscreen-screens-id}', '--json',
    ], text=True, timeout=5))
    matches = [m for m in monitors if int(m['monitor-appkit-nsscreen-screens-id']) == screen + 1]
    assert len(matches) == 1, 'Requested native display is unavailable/ambiguous'
    assert owner.poll() is None and owned_pid(pid, owner.pid), 'Fixture exited before display move'
    window = isolation['after'][0]
    assert int(window['app-pid']) == pid, 'Window ownership changed before display move'
    monitor = matches[0]
    # Do not request focus-following or select another window.
    subprocess.run([binary, 'move-node-to-monitor', '--window-id', str(window['window-id']),
                    str(monitor['monitor-id'])], check=True, timeout=5)
    return {'screen': screen, 'monitor': monitor, 'isolation': isolation}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--move-parent-to-screen', type=int, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    output = args.evidence.resolve()
    assert output.is_relative_to(Path(os.environ['GRAFFITTY_GPU_EVIDENCE']).resolve())
    assert not output.exists(), 'Use a fresh movement evidence path'
    # This adapter is launched asynchronously by the test Godot process. It
    # cannot target an arbitrary PID, and must not block Godot's AX event loop.
    pid = os.getppid()
    owner = SimpleNamespace(pid=pid, poll=lambda: None if os.getppid() == pid else 1)
    value = move_test_window(pid, owner, args.move_parent_to_screen)
    output.write_text(json.dumps(value, indent=2) + '\n')


if __name__ == '__main__': main()
