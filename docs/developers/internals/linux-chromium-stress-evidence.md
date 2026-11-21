# Linux stress run records

Recorded evidence; these results apply to the named runs and artifacts.

## Recorded verdict

All twelve final additional suite/backend results and 35 selected server tests
passed. Four owned fixtures exited cleanly with no bridge sockets or cgroup leaks.

| Environment | Soak coverage |
| --- | --- |
| Wayland Chrome/Alloy | 603 s each, 106 samples, delayed-ACK churn throughout |
| X11 Chrome/Alloy | Multi-client/GPU-child/resize/decode checks; soak explicitly skipped |

Both Wayland streams stayed above 20 FPS during independent network/stalled-peer
pressure. Final server RSS was ~322 MiB; browser charge ~1.2 GiB.
The retained resource table gives early/final medians, not a leak-rate estimate.

## Corrections and retained failures

Encoder resizing/recreation now produces fresh decodable frames. The resource
fixture now creates the same delegated accounting boundary as production rather
than an ordinary unaccounted shell.
Earlier compilation-load throughput misses and a netem phase with no actual drops
remain failed attempts. Reruns retained assertions and required real packet loss.

The 130 ms/high-bandwidth case delivered ~50 FPS; 500 KiB/s cases ~27 FPS without
repeated keyframes. Both backends passed protocol/negotiation and four ACK/read-pressure cases.

## Fixture and acceptance scope

Use owned servers/profiles/namespaces. netem affects only a private namespace,
not normal host traffic. GPU fault tests kill only an owned subprocess, not the
physical device. FFmpeg must decode moving frames, not just accept a bitstream.

Ten-minute bounded growth is not overnight stability, other-vendor/compositor
acceptance, or proof of zero leaks. Later lifecycle/eight-hour results remain separate.

## Recorded measurements

### Linux Chromium stress and recovery tests

| Check | What is verified |
| --- | --- |
| Concurrent clients | Full HEVC, capped H.264, and a slow reader share a page; the fast reader retains at least 75% of its baseline rate; the capped reader retains its codec/resolution |
| Slow/stalled peer isolation | While another viewer is bandwidth limited or stops reading entirely, a healthy viewer retains at least 85% of baseline with no interframe gap over 750 ms |
| Encoded output | FFmpeg decodes at least 30 frames without errors; multiple decoded colors exclude a frozen stream |
| GPU subprocess termination | Only GPU subprocesses beneath the owned Chromium host are killed; replacement appears, the document survives, and moving hardware video resumes |
| Encoder recreation | Resizing creates a new video epoch with the new dimensions and decodable moving frames |
| Long-lived clients | Two subscribers run through a ten-minute soak while additional delayed-ACK clients join/leave every 20 seconds |
| Resource growth | Server RSS, browser cgroup memory, and server file descriptors sampled every five seconds; early and final windows compared |
| Kernel network impairment | Real `tc netem` packet drops, delay/jitter, and bandwidth caps on loopback inside a new network namespace |
| Network recovery | Video/control continue under impairment; after removing it, video returns to at least 75% of baseline and decodes correctly |
| Protocol/video negotiation | Late keyframes, independent codecs/renditions, explicit unsupported capabilities/PNG fallback, decoder reset/rejection, resize, unsubscribe/resubscribe |
| ACK/read pressure | High-bandwidth delayed ACKs and 500 KiB/s readers, separately from kernel-level packet loss |

### Follow-up validation and remaining scope

| Check | Verified scope |
| --- | --- |
| Encoder-session exhaustion | Actual eight-session hardware limit, healthy-viewer isolation, resize at capacity, waiting/new viewer recovery, and a server started under pressure |
| Broken connection and fresh reconnect | Forty abrupt TCP resets across Chrome/Alloy and Wayland/X11; new sockets authenticate, subscribe, and decode the retained page |
| Combined lifecycle churn | Eighty cycles combining tabs, queued resizes, subscription changes, and slow peers across all four configurations |
| Longer endurance and GPU memory | Two hours per configuration, concurrently; 240 samples each, owned GPU memory/session telemetry, periodic decoding, and successful final cleanup |

### Results

| Healthy viewer FPS | Chrome | Alloy |
| --- | ---: | ---: |
| Baseline | 51.75 | 51.62 |
| Alongside slow reader | 52.45 | 52.25 |
| Alongside nonreading subscriber | 51.50 | 51.25 |
| After peer disconnects | 51.87 | 51.62 |

### Results

| Resource change after warm-up | Chrome | Alloy |
| --- | ---: | ---: |
| Server RSS | +0.32 MiB | −5.81 MiB |
| Browser cgroup memory | −1.79 MiB | −0.68 MiB |
| Server file descriptors | 0 | −5 |

## Commands and examples

### Running the owned Linux fixture

```sh
uv run tests/platform/linux/linux_chromium_stress_e2e.py \
  --server /path/to/gft --host /path/to/graffitty_chromium \
  --backend chrome --platform wayland --seconds 600 \
  --output .cache/linux-stress/chrome \
  --bridge /path/to/private-shared-directory/chrome.sock
```

### Running the owned Linux fixture

```sh
uv run tests/platform/linux/linux_chromium_stalled_client_e2e.py \
  --ready /path/to/fixture/ready.json \
  --output .cache/linux-stress/stalled-peer
```

### Real packet loss without affecting the host

```sh
python tests/platform/linux/linux_chromium_netem_e2e.py \
  --parent-netns "$ORIGINAL_NETNS" \
  --ready /path/to/fixture/ready.json \
  --bridge /path/to/private-shared-directory/chrome.sock \
  --output /path/to/private-evidence/netem-chrome
```

### Real packet loss without affecting the host

```sh
cargo test --locked -p graffitty-server chromium_ -- --include-ignored
```

## Evidence files

- `.cache/linux-stress/evidence/`
