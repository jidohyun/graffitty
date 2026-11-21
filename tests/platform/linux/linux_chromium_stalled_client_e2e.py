#!/usr/bin/env python3
# /// script
# dependencies = ["websocket-client>=1.8,<2"]
# ///
"""A subscribed client that stops reading/ACKing must not starve a healthy peer.
Attaches only to the private fixture described by --ready; never stops its server.
"""
import argparse
import json
import os
from pathlib import Path
import time

from linux_chromium_stress_e2e import Stream, eventually


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ready", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    ready = json.loads(args.ready.read_text())
    healthy = Stream(ready["descriptor"], ready["chromium"])
    stalled = None
    slow = None
    results = {}
    try:
        eventually(lambda: healthy.latest, "Healthy peer did not receive video")
        started = time.monotonic()
        time.sleep(8)
        results["baseline"] = healthy.stats(started)
        slow = Stream(ready["descriptor"], ready["chromium"], ack_delay=.35, rate_kb=250)
        started = time.monotonic()
        time.sleep(20)
        results["slow_peer"] = healthy.stats(started)
        results["slow_delivery"] = slow.stats(started)
        assert results["slow_delivery"]["fps"] >= 2, results
        results["slow_decode"] = slow.decode(args.output, "slow-peer")
        slow.close()
        slow = None
        stalled = Stream(ready["descriptor"], ready["chromium"], paused=True)
        # Deliberately never recv or acknowledge frames on this socket.
        started = time.monotonic()
        time.sleep(8)
        results["stalled_peer"] = healthy.stats(started)
        resumed = time.monotonic()
        stalled.paused.clear()
        eventually(lambda: stalled.stats(resumed)["frames"] >= 60, "Stalled viewer did not resume on its existing connection", timeout=15)
        eventually(lambda: len(stalled.sample) >= 60, "Resumed viewer did not receive a complete decode sample", timeout=15)
        results["resumed_decode"] = stalled.decode(args.output, "resumed-peer")
        results["resume_seconds"] = time.monotonic() - resumed
        stalled.close()
        stalled = None
        started = time.monotonic()
        time.sleep(8)
        results["after_disconnect"] = healthy.stats(started)
        (args.output / "results.json").write_text(json.dumps(results, indent=2))
        baseline = results["baseline"]["fps"]
        assert baseline >= 20, results
        for name in ("slow_peer", "stalled_peer", "after_disconnect"):
            assert results[name]["fps"] >= baseline * .85, results
            assert results[name]["longest_gap_s"] < .75, results
        print("PASS stalled-client isolation", json.dumps({k: round(v["fps"], 2) for k, v in results.items() if isinstance(v, dict) and "fps" in v}), flush=True)
    finally:
        if stalled:
            stalled.close()
        if slow:
            slow.close()
        healthy.close()


if __name__ == "__main__":
    main()
