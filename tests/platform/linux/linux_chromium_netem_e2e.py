#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""Real TCP packet loss, delay and bandwidth limits in a PRIVATE network namespace.

Run inside a new network namespace with CAP_NET_ADMIN. A private filesystem Unix
bridge connects to the owned Linux fixture. Never alters the normal host network.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time

from linux_chromium_stress_e2e import Bridge, Stream, eventually


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready", type=Path, required=True)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--parent-netns", required=True, help="readlink /proc/self/ns/net BEFORE creating the private namespace")
    args = parser.parse_args()
    assert os.readlink("/proc/self/ns/net") != args.parent_netns, "Refusing to modify the normal network namespace"
    args.output.mkdir(parents=True, exist_ok=False)
    ready = json.loads(args.ready.read_text())
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()

    def accept():
        while True:
            try:
                client, _ = listener.accept()
                upstream = socket.socket(socket.AF_UNIX)
                upstream.connect(str(args.bridge))
            except OSError:
                return
            threading.Thread(target=Bridge.copy, args=(client, upstream), daemon=True).start()
            threading.Thread(target=Bridge.copy, args=(upstream, client), daemon=True).start()

    threading.Thread(target=accept, daemon=True).start()
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    descriptor = dict(ready["descriptor"], url=f"ws://127.0.0.1:{listener.getsockname()[1]}")
    results = {}
    viewer = None
    try:
        viewer = Stream(descriptor, ready["chromium"])
        eventually(lambda: viewer.latest, "Netem client did not receive video")
        started = time.monotonic()
        time.sleep(8)
        results["baseline"] = viewer.stats(started)
        assert results["baseline"]["fps"] >= 20, results
        for name, options in [
                ("delay", ["delay", "65ms", "10ms"]),
                ("lossy_slow", ["delay", "65ms", "10ms", "loss", "2%", "rate", "8mbit"]),
                ("burst_stall", ["delay", "200ms", "50ms", "loss", "5%", "rate", "4mbit"])]:
            subprocess.run(["tc", "qdisc", "replace", "dev", "lo", "root", "netem", "limit", "100", *options], check=True)
            before_traffic = json.loads(subprocess.check_output(["tc", "-s", "-j", "qdisc", "show", "dev", "lo"]))
            time.sleep(3)
            started = time.monotonic()
            time.sleep(12)
            # Random loss can legitimately drop nothing in a short, low-rate
            # phase (loopback offload also coalesces packets).
            #
            # Extend that phase until loss is observed, with a strict bound;
            # never report an unexercised loss configuration as a passing
            # packet-loss test.
            while True:
                traffic = json.loads(subprocess.check_output(["tc", "-s", "-j", "qdisc", "show", "dev", "lo"]))
                dropped = sum(q.get("drops", 0) for q in traffic) - sum(q.get("drops", 0) for q in before_traffic)
                if name == "delay" or dropped > 0 or time.monotonic() - started >= 45:
                    break
                time.sleep(5)
            stats = viewer.stats(started)
            stats["measurement_seconds"] = time.monotonic() - started
            stats["qdisc_before"] = before_traffic
            stats["qdisc"] = traffic
            stats["packet_drops"] = dropped
            request = len(results) + 50000
            sent = time.monotonic()
            viewer.client.action("rpc", viewer.client.topology["panes"][0]["id"], request=request, method="session.capture", params={})
            received = eventually(lambda: viewer.response(request), "Control RPC stalled under network impairment", timeout=10)
            stats["control_seconds"] = received - sent
            results[name] = stats
            (args.output / "results.json").write_text(json.dumps(results, indent=2))
            assert stats["frames"] >= 12 and stats["longest_gap_s"] < 8, stats
            if name != "delay":
                assert stats["packet_drops"] > 0, "No packets were actually dropped in this phase"
            print(name, json.dumps({k: stats[k] for k in ("fps", "longest_gap_s", "control_seconds")}), flush=True)
        subprocess.run(["tc", "qdisc", "del", "dev", "lo", "root"], check=True)
        time.sleep(5)
        viewer.reset_sample()
        started = time.monotonic()
        time.sleep(10)
        results["recovered"] = viewer.stats(started)
        assert results["recovered"]["fps"] >= .75 * results["baseline"]["fps"], results["recovered"]
        results["decode"] = viewer.decode(args.output, "network-recovered")
        (args.output / "results.json").write_text(json.dumps(results, indent=2))
        print("PASS netem packet loss/delay/bandwidth and recovery", flush=True)
    finally:
        if viewer:
            viewer.close()
        listener.close()
        subprocess.run(["tc", "qdisc", "del", "dev", "lo", "root"], capture_output=True)


if __name__ == "__main__":
    main()
