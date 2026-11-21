"""Controlled workload for native tests. Never touches user sessions."""

import os
import signal
import subprocess
import sys
import time

children = []
orphans = []
memory = None
burn = "import time; end=time.process_time()+0.3\nwhile time.process_time()<end: pass"
try:
    print("ready", flush=True)
    for command in sys.stdin:
        command = command.strip()
        if command == "burn":
            exec(burn)
        elif command == "nested":
            subprocess.run(
                [
                    sys.executable,
                    "-c",
                    "import subprocess,sys; subprocess.run([sys.executable,'-c',"
                    + repr(burn)
                    + "])",
                ],
                check=True,
            )
        elif command == "frontier":
            # The intermediate process reaps its worker, remains alive, then
            # is itself reaped. A fast sampler sees all three frontier states.
            subprocess.run(
                [
                    sys.executable,
                    "-c",
                    "import subprocess,sys,time; subprocess.run([sys.executable,'-c',"
                    + repr(burn)
                    + "]); time.sleep(0.7)",
                ],
                check=True,
            )
        elif command == "parallel":
            children = [
                subprocess.Popen([sys.executable, "-c", burn]) for _ in range(3)
            ]
            for child in children:
                child.wait()
            children.clear()
        elif command == "memory":
            memory = bytearray(32 * 1024 * 1024)
            for i in range(0, len(memory), 4096):
                memory[i] = 1
        elif command == "detach":
            # Stay discoverable first; the next command causes reparenting.
            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import os,sys,time; os.setsid(); print(os.getpid(),flush=True); time.sleep(15)",
                ],
                stdout=subprocess.PIPE,
                text=True,
            )
            children.append(child)
            print(child.stdout.readline().strip(), flush=True)
            continue
        elif command == "orphan":
            # An intermediate parent exits after a grace period, leaving its
            # already-observed child alive under launchd.
            child = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import os,time; p=os.fork(); "
                    "\nif p: print(p,flush=True)\ntime.sleep(1 if p else 8)",
                ],
                stdout=subprocess.PIPE,
                text=True,
            )
            pid = int(child.stdout.readline().strip())
            children.append(child)
            orphans.append(pid)
            print(pid, flush=True)
            continue
        elif command == "quit":
            break
        print("done", flush=True)
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
        child.wait()
    for pid in orphans:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
