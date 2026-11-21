# Linux GPU integration records

Recorded evidence; these results apply to the named runs and artifacts.

## Run index

| Date | Environment | Result |
| --- | --- | --- |
| Oct 1 | RTX A6000, driver 580.95.05, Godot 4.7.2 | FD/protocol and Vulkan/Godot lifetime/pixels passed; real DMA-BUF capture blocked by device access/extension availability |
| Oct 27 | GTX 1050 Ti, 580.178.04, rootless Podman/TigerVNC DRI3 | Both CEF backends delivered real shared pixels and animated app video |
| Oct 31 | Same GTX, Weston 14 NVIDIA EGL and TigerVNC X11 | Both native backend suites passed; Wayland had DISPLAY removed |
| Oct 31–Nov 1 | Physical SM-T733 over Tailscale | Twelve hardware/touch/background/scroll/crash/URL scenarios passed; navigation passed after cgroup fix |

Oct 1 default render-thread mode was clean. Separate-thread pixel/lifetime checks
passed but shutdown errors reproduced in an empty Godot project; keep that caveat.
Its Ubuntu 25.04 extension needed glibc ≥2.39, not a universal Linux baseline.

## Capture and transport contract

CEF lends DMA-BUF plane FDs/modifiers. Import into Vulkan, wait writer fence,
acquire foreign queue ownership, copy to owned storage, release/wait before returning.
A UID-checked seqpacket channel passes metadata/OPAQUE_FD with SCM_RIGHTS;
handshake matches device/driver UUIDs. CUDA imports and NVENC encode on NVIDIA.
The Vulkan receiver maps or stages the imported buffer for the CPU upload path.
AMD and Intel hardware encoding uses VA-API.
The local Godot import adapter exists, but those Linux sessions use video delivery.

Require compatible GPU/driver, device permissions, external-memory FD/DMA-BUF,
DRM modifiers, foreign queues, and buffer addresses. Native import rejects a
shared graphics/upload queue to avoid unsynchronized submission.
BGRA/RGBA8, up to 8192², ≤4 planes in one allocation are supported; disjoint or
unsupported synchronization/formats fail. Imported Godot frames are bounded to
three, plus one unacknowledged offer. Resize uses independent allocations.

## Platform corrections

- NVIDIA import with re-export metadata produced zero-filled frames without validation errors;
  the fork removes that import condition. A standalone GBM repro confirmed it.
- X11 uses ANGLE/Vulkan and DRI3. Wayland selects from its environment or explicit
  GRAFFITTY_CHROMIUM_OZONE_PLATFORM; failures never silently switch to XWayland.
- Hidden Chrome windows remain unmapped; returning native recreates the real Ozone
  output surface. Compositors may decline activation.
- OSR size/show retries stop on correct dimensions, hide, or destruction.
- The newest pending allocation survives pressure; release Vulkan before CEF shutdown.

## Android and accounting follow-up

The private cgroup boundary must be joined before exec. Missing delegated controllers
makes monitoring unavailable, not browser launch impossible. Cleanup retries empty-group
removal for one second without killing children.
All three delegated Linux accounting tests passed. Both final navigation/crash cases
passed with no cgroup leaks. The coordinate fixture later corrected video/CSS mapping;
eight navigation reruns passed, preserving the original failed baseline.

URL-under-load updates stayed below 3 s: Chrome 236–428 ms, Alloy 196–278 ms.
The table below is a ~10 s tablet sample, not sustained 60 FPS acceptance.
Earlier helper process-title parsing and ADB transfer failures were retained separately.

## Limits

ARM64 was built/packaged only. Other GPU vendors, GNOME/KDE, fractional scaling,
multi-monitor, and cross-adapter behavior remain unverified. Oct 1 device permissions
were an environment blocker, not a requirement to run Graffitty as root.
CUDA/NVENC keeps encoded frames on the GPU. The Vulkan/VA-API upload path uses readback. Exit 77 skips DMA-BUF checks.

## Recorded measurements

### Android remote validation (2026-10-31 through 2026-11-01)

| Backend | Source FPS | Presented FPS | Video size |
| --- | ---: | ---: | --- |
| Chrome | 60.1 | 32.5 | 564 × 1440 |
| Alloy | 60.1 | 35.7 | 564 × 1440 |

## Commands and examples

### Reproducing the native checks

```sh
test_dir=/path/to/ssd/graffitty/gpu-validation
mkdir -p "$test_dir"
g++ -std=c++20 -Wall -Wextra -Werror tests/platform/linux/linux_frame_protocol.cpp \
  -o "$test_dir/protocol"
"$test_dir/protocol"
g++ -std=c++20 -Wno-missing-field-initializers \
  -I"$CEF_ROOT" -I"$VULKAN_HEADERS" tests/platform/linux/linux_vulkan_buffer.cpp \
  -l:libvulkan.so.1 -pthread -o "$test_dir/buffer"
"$test_dir/buffer"
g++ -std=c++20 -I"$VULKAN_HEADERS" tests/platform/linux/linux_vulkan_producer.cpp \
  -l:libvulkan.so.1 -o "$test_dir/producer"
```

### Native backend regression test

```sh
python3 tests/chromium/chromium_linux_backend_e2e.py \
  --host /path/to/runtime/graffitty_chromium \
  --capture-library target/chromium-linux/libchromium_capture_test.so \
  --platform wayland --backend both --artifacts .cache/linux-wayland-tests
```

### Android remote validation (2026-10-31 through 2026-11-01)

```sh
cargo test --locked -p terminal-resource-monitor linux::tests -- --include-ignored
```
