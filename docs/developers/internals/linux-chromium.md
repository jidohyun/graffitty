# Linux Chromium integration

Use the matching Linux CEF SDK and native host; test Chrome and Alloy independently
on X11 and native Wayland.

## Start here

1. [Build or restore CEF](../build-and-run/cef-linux.md).
2. Build the Graffitty host with `apps/server/chromium/build-linux.sh`.
3. Run the [functional matrix](linux-chromium-e2e.md).
4. Check the [Godot frontend](linux-chromium-frontend.md) separately.

## Host startup

The host selects its Vulkan or software capture path before Chromium processes
its rendering flags. With CEF 150, the Linux host disables the optional
`GwpAsanMalloc` and `GwpAsanPartitionAlloc` heap samplers. With sampling
active, a new Chromium thread could enter the allocator while glibc was
allocating storage for the sampler's own pthread key. The recursion exhausted
the thread stack before the host answered its first CDP request. When updating
the SDK, test repeated GPU launches with sampling forced on before removing
these switches.

## Capture and encoding

The host imports the CEF DMA-BUF and sends a dedicated Vulkan buffer on the
device and driver named in the server handshake. With CUDA available, the
server imports that buffer into CUDA and scales and encodes with NVENC. Otherwise
the Vulkan receiver acquires the buffer and reads it through host-visible memory.
Software paint delivers an immutable BGRA mapping to the same receiver.

The host waits for the DMA-BUF writer before importing each frame. It normally
polls an exported sync file. If `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` returns
`ENOTTY` or `EOPNOTSUPP`, the host polls the borrowed DMA-BUF itself for
`POLLIN` on this and subsequent frames. Both paths have a three-second
deadline. The selected wait mode appears once in `cef.log`. Both waits depend
on the exporter publishing its write dependencies. [Linux DMA-BUF implicit fence polling](https://docs.kernel.org/driver-api/dma-buf.html#implicit-fence-poll-support)

A timeout, poll error or failed frame validation, import or copy prevents the
host from sending that frame. When the session server advertises software
support, the host logs the reason and switches to CDP screencast for its
remaining lifetime. Both backends keep their browser, tabs and page state.
Diagnostics change from `vulkan-opaque-fd` to `cdp-screencast` only if the
host actually switches. A direct GPU-only receiver cannot use CDP.

For CPU-accessible frames, FFmpeg scales BGRA or RGBA into NV12 and uploads it
to a hardware encoder. AMD and Intel use VA-API through an accessible DRM
render node and an installed VA driver with encode support. The server probes
H.264, HEVC and AV1 individually by requesting a keyframe. The available codecs
depend on the installed device and driver.

Set `GRAFFITTY_CAPTURE=vulkan`, `cuda` or `software` on the server to select
a receiver during tests. A forced GPU receiver must initialize successfully.
Each GPU receiver also accepts sealed software frames from the host.

## GPU-less capture

The session server negotiates frame kinds before CEF starts. On a software-only
endpoint, Alloy requests windowless CPU paint at 10 fps. Each changed view
becomes a sealed, tightly packed BGRA memfd. Chrome uses the SDK's bundled ANGLE
SwiftShader compositor for its unmapped window. An attached CDP page session
delivers PNG screencasts sized to the pane, up to 1280 × 900.

On Linux the host selects Wayland when `WAYLAND_DISPLAY` or `WAYLAND_SOCKET`
is set, X11 when only `DISPLAY` is set, and Chromium's bundled Ozone headless
platform when all three are empty. `GRAFFITTY_CHROMIUM_OZONE_PLATFORM` can
explicitly select `wayland`, `x11` or `headless`. Headless mode streams embedded
panes without a compositor service or Xvfb. It reports
`nativeWindowSupported=false` and rejects native-window presentation.

A Godot client advertises PNG alongside its hardware video codecs. If there is
no shared encoder and decoder, the server sends the latest PNG revision and
the client acknowledges each received image. The server reuses Chrome's
PNG bytes and encodes Alloy's pixels on the preview worker. Small previews are
limited to 10 fps. Larger frames increase the interval, up to one second. When
a hardware codec is negotiated, the server decodes the screencast image to
pixels for the hardware encoder.

## Coverage boundary

Recorded x64 runs cover specific X11/Wayland environments. Linux ARM64 application
acceptance, additional GPU vendors, mixed DPI, and GNOME/KDE still need their own
results. See [stress](chromium-platform-stress.md) for the failed eight-hour run.

## Detailed evidence

[Linux Chromium integration — source notes and results](linux-chromium-evidence.md).

The linked record retains the original measurements, failed attempts, commands,
and coverage limits. It is historical evidence, not a new test run.
