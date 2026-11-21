# Linux browser E2E matrix

Recorded evidence; these results apply to the named runs and artifacts.

## Results

| Run | Result |
| --- | --- |
| Nov 1 baseline | 32/33 passed; X11 Chrome Unicode navigation failed |
| Corrected navigation | Eight reruns passed: three Chrome/display, one Alloy/display |
| Delegated cgroup tests | All three passed |

Every required matrix check has passing evidence across baseline and reruns,
not one uninterrupted all-pass run. Baseline 28 and total 36 Android server fixtures
exited without cgroup leaks. Disposable APK was removed; production data survived.

## Coordinate-fixture correction

A physical video point (30,30) was treated as CSS (30,30). At 94×240 video for
1280×3267 CSS this missed the 70 px input. Derive video positions from actual CSS
geometry; retain Unicode assertions at full and deliberately reduced resolution.
This was a fixture correction, not grounds to erase the original failure.

## Running

Build the current Android client, Linux server/host, and chromium_capture_test.
Require Wayland and X11, hardware Vulkan/video, and delegated CPU/memory cgroup v2.
Set GODOT_RESOURCE_CGROUP_PARENT if needed. SSH must provide desktop/GPU access.
The runner uploads fixtures into a private cache; it does not build/replace production binaries.

Default catalog size is 37 results after expansion; the dated baseline contained 33.
Four native cases cover GPU pixels/tabs/presentation; Android scenarios run per
backend/display, plus the resource invocation. Use repeatable platform/backend/case
filters and fresh artifacts. --skip-native/--skip-resources select Android-only reruns.

## Verify the server Vulkan receiver

Build the production receiver with the test harness adapter, and run it against
a matching CEF host. In a desktop session, run the following command once per
display platform (`wayland` and `x11`).

```sh
cargo build -p graffitty-chromium-video --example linux_capture_test
GRAFFITTY_CAPTURE=vulkan python3 tests/chromium/chromium_linux_backend_e2e.py \
  --host "$CEF_HOST" --platform wayland --backend both \
  --capture-library target/debug/examples/liblinux_capture_test.so \
  --artifacts .cache/linux-chromium-e2e/receiver-wayland
```

On November 20, the GTX 1050 Ti passed both CEF backends on native Wayland
and X11 via Xwayland. The server read opaque red, blue and green samples,
including after tab changes and a backpressured resize. The host in this run
sent GPU frames exclusively. AMD and Intel VA-API encode/decode round trips
still require testing on those GPUs.

## Coverage limits

Actual shared GPU pixels—not CDP screenshots—must establish capture.
No inference covers other vendors, GNOME/KDE, fractional scale, monitors,
Linux ARM64, or Windows. Logs/state/screenshots/cleanup are private evidence.

## Recorded measurements

### Linux Chromium E2E checklist

| Test | Required evidence | Matrix |
| --- | --- | --- |
| Native GPU capture | Actual Vulkan pixels, dimensions, opacity, animation | Both displays × both backends |
| Native tabs and ownership | Shared storage, tab order/selection, original-owner close | Both displays × both backends |
| Native presentation | Native/embedded transitions for Chrome; explicit Alloy capability | Both displays × both backends |
| Resize and backpressure | Final static frame after delayed ACK; Alloy's idle resize retry settles | Both displays × both backends |
| Resource accounting | Private cgroup inherited before exec; descendants measured; cleanup race | Linux with delegated CPU/memory controllers |
| Hardware streaming | Decoded page colors, source ≥55 FPS, presented ≥30 FPS, hardware codec, adaptive rendition | Both displays × both backends × Android |
| Navigation and monitoring | Address editing, Unicode DOM input at full/small renditions, Back/Forward, CPU/memory, process ownership, tab drag | Both displays × both backends × Android |
| Touch | Browser click/drag/wheel interactions | Both displays × both backends × Android |
| Scroll stability | No black strips or stale page regions; decoder diagnostics | Both displays × both backends × Android |
| Background/resume | Two heartbeat-expiring background cycles, same page, fresh video | Both displays × both backends × Android |
| Crash recovery | Host restart, renderer reload, unresponsive-page recovery, error UI and fresh video | Both displays × both backends × Android |
| URL under load | Eight URL changes each visible within 3 seconds during terminal flooding | Both displays × both backends × Android |
| Frontend clipboard | Unicode paste/copy/cut, input event, password-copy protection | Both displays × both backends × Android |
| Cleanup | Server exit, no private accounting-group leaks, disposable APK removed | Every Android scenario |

### Results

| Environment | Native GPU suite | Android scenarios | Corrected navigation repeats |
| --- | --- | --- | --- |
| Wayland / Chrome | Pass | 7 / 7 verified | 3 / 3 pass |
| Wayland / Alloy | Pass | 7 / 7 verified | 1 / 1 pass |
| X11 / Chrome | Pass | 7 / 7 verified | 3 / 3 pass |
| X11 / Alloy | Pass | 7 / 7 verified | 1 / 1 pass |

### Results

| Display | Backend | Presented FPS |
| --- | --- | ---: |
| Wayland | Chrome | 36.1 |
| Wayland | Alloy | 35.3 |
| X11 | Chrome | 35.8 |
| X11 | Alloy | 35.8 |

## Commands and examples

### Running

```sh
uv run tests/platform/linux/test_linux_chromium.py \
  --ssh linux-test-host \
  --repo /path/to/checkout \
  --server /path/to/gft \
  --host /path/to/graffitty_chromium \
  --capture-library /path/to/libchromium_capture_test.so \
  --adb tablet-serial \
  --url ws://linux-test-host:41817 \
  --artifacts .cache/linux-chromium-e2e/run-name
```

## Verify GPU-less PNG delivery

Run as an ordinary user in a Linux container with no GPU devices. Supply the
built CLI and the CEF host beside its runtime libraries. Start with a new output
directory for each case. On a VM without a display server, run:

```sh
for backend in alloy chrome; do
  env -u DISPLAY -u WAYLAND_DISPLAY -u WAYLAND_SOCKET \
    uv run tests/chromium/chromium_linux_software_e2e.py --platform headless \
    --server "$GFT" --host "$CEF_HOST" --backend "$backend" \
    --output ".cache/linux-chromium-e2e/software-$backend" || exit 1
done
```

The WebSocket client offers H.264, HEVC, AV1 and PNG. It checks the software
transport, the PNG format, exact center pixels after resizing and resubscribing,
and rejection of native presentation on a headless host. For the desktop X11 case,
run the same script in an X11 session with `--platform x11`; Chrome also checks
capture after returning from native presentation.

On x86_64 Ubuntu 26.04, both backends passed with no GPU devices, X server,
Wayland compositor or Xvfb installed. Diagnostics reported `ozonePlatform=headless`
and `nativeWindowSupported=false`. The WebSocket client received RGB (208, 32, 32)
at 640 × 480, (32, 64, 208) after resizing to 720 × 360, and (200, 112, 48) at
720 × 360 after resubscribing.

On x86_64 Ubuntu 26.04 under Xvfb, a rootless container without GPU devices
delivered the expected PNGs from both backends. The client received RGB
(208, 32, 32) at 640 × 480 and (32, 64, 208) at 720 × 360. With system Vulkan
ICD discovery disabled, both also delivered (200, 112, 48) after resubscribing.
Chrome delivered (48, 160, 64) on return from native presentation. This run used
the WebSocket client fixture and the SDK's SwiftShader libraries.

## Verify Linux DMA-BUF fence waits

Use a GPU-enabled Linux container with a working accelerated CEF host. Compile
`tests/native/linux_missing_fence_ioctl.c` as a C object. Repeat the host's
link command with that object and `-Wl,--wrap=ioctl,--wrap=poll`, writing the
result to a separate test runtime beside the CEF libraries. The wrappers only
affect host calls. Chromium and the Vulkan driver still produce real DMA-BUFs.

```sh
for mode in implicit poll-error observe; do
  for backend in alloy chrome; do
    GRAFFITTY_CAPTURE=vulkan uv run tests/chromium/chromium_linux_software_e2e.py \
      --platform "$PLATFORM" --backend "$backend" --fence "$mode" \
      --server "$GFT" --host "$FAULT_TEST_HOST" \
      --output ".cache/linux-chromium-e2e/$PLATFORM-$backend-$mode" || exit 1
  done
done
```

Run once with `PLATFORM=x11` and once with `PLATFORM=wayland`. The WebSocket
client checks exact pixels and sizes after resize and resubscribe. In
`implicit` mode, injecting `ENOTTY` must leave the GPU transport active and
deliver multiple GPU frames. In `poll-error` mode, the fixture additionally
returns `POLLERR | POLLIN` from the DMA-BUF wait. The host must drop that first
frame and continue via CDP, preserving PID, page target and JavaScript state.

In `observe` mode the kernel exports the real sync file. The fixture samples its
readiness with a zero-timeout poll and inspects its component fences with
`SYNC_IOC_FILE_INFO`. Each run saves its observations in `fence.trace`.

On an NVENC-capable server, use `GRAFFITTY_CAPTURE=cuda` and add
`--verify-h264` to the implicit-wait run. A second WebSocket client negotiates
H.264 and decodes a keyframe with FFmpeg. The test checks its size and center
pixel with a tolerance of eight levels per RGB channel.

On a GTX 1050 Ti with NVIDIA 580.178.04 and Linux 6.8, all 72 real sync files
sampled in the X11 animation and backpressure test were already readable. Each
contained a single signalled fence named `stub`. Linux supplies that fence when
export finds no outstanding dependency. These samples establish that the host
saw no pending writer at capture time. They cannot distinguish an already
completed write from a write for which the driver published no fence.
[Linux 6.8 DMA-BUF export implementation](https://github.com/torvalds/linux/blob/v6.8/drivers/dma-buf/dma-buf.c#L331-L345)

With sync-file export disabled, all 35 DMA-BUF polls in the four WebSocket
H.264 runs were readable at the initial zero-timeout sample. Each backend on
each display delivered a decoded 720 × 360 H.264 keyframe with center RGB
(199, 112, 48) for requested RGB (200, 112, 48). Forcing a DMA-BUF poll error
instead delivered the exact PNG colors via CDP in all four cases.
