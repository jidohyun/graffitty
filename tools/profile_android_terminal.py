#!/usr/bin/env python3
"""Capture Android scheduling and CPU evidence on a physical device.

The capture excludes screen and terminal contents.

- Keep Graffitty in the foreground and repeat the same workload.
- A report is invalid if the app leaves the foreground or its process changes.
- Treat missing FrameTimeline events as inconclusive. Godot's Vulkan
  SurfaceView may omit them even when busy or dropping frames.
"""
import argparse
import json
import re
import shlex
import subprocess
import time
from pathlib import Path

PACKAGE = "com.graffitty.client"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--package", default=PACKAGE, help="Application ID, including disposable benchmark packages")
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cpu", action="store_true", help="Also sample native stacks with simpleperf (debuggable APK)")
    args = parser.parse_args()
    package = args.package
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+", package):
        parser.error("--package must be an Android application ID")
    if not 1 <= args.seconds <= 120:
        parser.error("--seconds must be between 1 and 120")
    args.output.mkdir(parents=True, exist_ok=False)

    def adb(*command, timeout=15):
        return subprocess.check_output(["adb", "-s", args.serial, *command], timeout=timeout, text=True)

    def shell(command):
        return adb("shell", command)

    pid = shell(f"pidof {package}").strip()
    if not pid.isdigit():
        raise RuntimeError("Expected one running Graffitty process")
    config = f'''buffers {{ size_kb: 32768 fill_policy: RING_BUFFER }}
 duration_ms: {args.seconds * 1000}
 data_sources {{ config {{ name: "linux.ftrace" ftrace_config {{
 ftrace_events: "sched/sched_switch" ftrace_events: "sched/sched_waking"
 ftrace_events: "power/cpu_frequency" atrace_categories: "gfx"
 atrace_categories: "view" atrace_categories: "input" atrace_apps: "{package}"
 }} }} }}
 data_sources {{ config {{ name: "linux.process_stats" process_stats_config {{
 scan_all_processes_on_start: true proc_stats_poll_ms: 1000 }} }} }}
 data_sources {{ config {{ name: "android.surfaceflinger.frametimeline" }} }}
'''
    (args.output / "config.pbtxt").write_text(config)
    stamp = str(time.time_ns())
    remote_config = f"/data/misc/perfetto-configs/graffitty-{stamp}.pbtxt"
    remote_trace = f"/data/misc/perfetto-traces/graffitty-{stamp}.pftrace"
    remote_cpu = f"/data/local/tmp/graffitty-{stamp}.data"
    adb("push", str(args.output / "config.pbtxt"), remote_config)
    (args.output / "thermal-before.txt").write_text(shell("dumpsys thermalservice"))
    package_info = shell(f"dumpsys package {package}")
    (args.output / "version.txt").write_text("\n".join(line for line in package_info.splitlines()
        if any(key in line for key in ["versionCode=", "versionName=", "lastUpdateTime="])))
    samples = []
    children = []
    logs = []
    old_harden = None
    started = time.monotonic()
    try:
        def launch(command, name):
            log = (args.output / name).open("w")
            logs.append(log)
            child = subprocess.Popen(["adb", "-s", args.serial, "shell", command], stdout=log, stderr=subprocess.STDOUT)
            children.append(child)
            return child

        trace = launch(f"perfetto --txt -c {remote_config} -o {remote_trace}", "perfetto.log")
        cpu = None
        if args.cpu:
            old_harden = shell("getprop security.perf_harden").strip()
            shell("setprop security.perf_harden 0")
            cpu = launch(f"simpleperf record --app {package} -p {pid} -g --duration {args.seconds} -o {remote_cpu}", "simpleperf.log")
        while time.monotonic() - started < args.seconds:
            activities = shell("dumpsys activity activities")
            resumed = [line.strip() for line in activities.splitlines() if "topResumedActivity=" in line]
            foreground = any(package + "/" in line for line in resumed)
            current = shell(f"pidof {package} || true").strip()
            samples.append({"elapsed_seconds": round(time.monotonic() - started, 3),
                            "foreground": foreground, "same_process": current == pid})
            time.sleep(1)
        trace.wait(timeout=30)
        if trace.returncode:
            raise RuntimeError("Perfetto failed; see perfetto.log")
        adb("pull", remote_trace, str(args.output / "trace.pftrace"), timeout=120)
        if cpu is not None:
            cpu.wait(timeout=30)
            if cpu.returncode:
                raise RuntimeError("simpleperf failed; see simpleperf.log")
            for sort in ["dso", "dso,symbol"]:
                report = shell(f"simpleperf report -i {shlex.quote(remote_cpu)} --sort {sort}")
                (args.output / ("cpu-" + sort.replace(",", "-") + ".txt")).write_text(report)
        report = {"serial": args.serial, "package": package, "pid": int(pid), "seconds": args.seconds,
                  "valid_foreground_interval": bool(samples) and all(s["foreground"] and s["same_process"] for s in samples),
                  "samples": samples,
                  "frame_warning": "Missing Vulkan SurfaceView FrameTimeline events do not imply smooth rendering."}
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
        for log in logs:
            log.close()
        if old_harden is not None:
            shell("setprop security.perf_harden " + shlex.quote(old_harden))
        shell("rm -f " + " ".join(map(shlex.quote, [remote_config, remote_trace, remote_cpu])))


if __name__ == "__main__":
    main()
