# Windows embedded Chromium

Use the Graffitty CEF fork in `fork/cef/windows/` and the pinned runtime artifact.
The small host DLL is rebuilt independently of Chromium.

## Build

Requirements: MSVC/Windows SDK, CMake, MSYS2 make/pkgconf/nasm, and matching
CEF public SDK `cef_binary_150.0.20+ga832838+chromium-150.0.7871.253_windows64_minimal`.
SDK archive SHA-1: `35d4522e8baa6048b9f8886d015b3bbb0f5a4178`.

```powershell
.\apps\server\chromium\build-windows.ps1 -CefRoot C:/sdk/cef_binary_150.0.20+ga832838+chromium-150.0.7871.253_windows64_minimal -Generator 'Visual Studio 17 2022'
.\tools\build-windows.ps1
.\tools\build-cli.ps1
godot --path frontends/godot/project res://scenes/terminal.tscn --rendering-driver d3d12
```

| Override | Purpose |
| --- | --- |
| `MSYS2_ROOT` | Nondefault MSYS2 installation |
| `GRAFFITTY_VCVARS64` | MSVC environment |
| `-CMake`, `-Generator` | Host build tools |

Build scripts prepare pinned static FFmpeg with NVENC, oneVPL/QSV, AMF and Media Foundation encoders. The recipe checks each required encoder and D3D11VA decoder accelerator.
No separate CUDA toolkit/FFmpeg executable is needed. Runtime files install to
`dist/chromium-windows/`; checksums, provenance, source hashes, and extraction
cache are verified against the DVC artifact.

## Sandbox and bootstrap

The CEF bootstrap EXE loads the host DLL; **both are required**.
Missing sandbox context fails startup. Runtime read/execute ACLs permit the
least-privileged app containers. Chromium's layered child windows require the
bootstrap's modern Windows manifest.

BackupRefPtr remains enabled. The host disables `GwpAsanMalloc` and
`ExtremeLightweightUAFDetector` because the pinned tracing allocator can
recursively deadlock. Raising CDP timeouts does not fix that startup deadlock.

## Private control and native windows

The owner launches the helper in a job. A current-user pipe carries NUL-delimited
CDP/Graffitty commands, with kernel PID checks at both ends. Browser-level private
DevTools pipes survive page closure; writes are bounded/overlapped.
Launch arguments are excluded from Chrome URL parsing.

Embedded windows reject activation. Native presentation routes context menus
through the owning Godot window. Input uses logical CSS coordinates, independent
of physical texture scale. Chrome's native minimum size/UI/DPI affect capture;
Alloy uses requested capture size. Closing Inspect retains live Alloy session cookies.

## Capture without a GPU

When DXGI has no hardware adapter capable of D3D11 rendering, the host enables
Chromium software compositing. The host and server recognize the Microsoft Basic
Render Driver by its vendor/device ID (`1414:008c`) even when DXGI omits the
software flag. Chrome and Alloy send PNG frames over the private
DevTools connection. The server starts the screencast for an embedded subscriber
and stops it when capture is idle or the browser is presented natively.
Diagnostics report `captureTransport=cdp-screencast`. A client offering video
and PNG receives PNG when the server's hardware encoder probe finds no codec.
The PNG path also serves hardware-rendered surfaces through D3D11 staging readback
when a viewer requests images.

## GPU transfer and ownership

1. Copy the borrowed CEF D3D11 texture to fresh immutable NT-shared storage.
2. Wait for GPU copy completion before returning the callback.
3. Publish metadata; retain the handle until the receiver opens it.
4. Keep at most one additional newest pending frame and retry when pressure clears.

The server retains imported storage independently. Owner/job disappearance ends
the helper. Native client negotiation uses `d3d-shared-nt-v1` and a second
PID-verified pipe. Import/read of a fresh challenge on the real D3D12 device must
succeed before frame handles are offered. Acknowledgements bound resource lifetime.
A forwarded byte stream cannot authorize another process.

Godot imports on its render thread and compute-converts BGRA to owned RGBA.
This avoids an incompatible sRGB view/device removal in Godot 4.7.2.
The destination retains the source COM reference through deferred GPU destruction.
There is no CPU pixel readback/upload in this native path.

### Remote video

The server uses the captured texture’s adapter. NVIDIA uses NVENC with BGRA input.
Intel QSV uses a oneVPL device derived from the capture device. AMD AMF and hardware
Media Foundation transforms accept D3D11 NV12 frames. The video processor scales
and converts to NV12 on the GPU, including for QSV’s mapped D3D11 texture.
H.264 and HEVC can fall back to Media Foundation if the vendor encoder cannot
produce a keyframe. AV1 requires working vendor hardware. Negotiation probes a
real D3D11 texture and advertises codecs that produce a packet.
Decoder checks include adapter profiles and NV12 output; merely opening an
FFmpeg decoder can falsely imply AV1 hardware support.

Use `RUST_LOG=graffitty_video` to inspect encoder/scaling/readback counts.
Video-only CPU readbacks must remain zero; an explicit PNG subscriber requests readback.
Disconnect/import failure requests portable delivery using actual codec capabilities.

## Test the host

[Run native and video checks](windows-chromium-verification.md) on an interactive
desktop. The native path requires **Direct3D 12** and compatible browser/Godot
GPU adapters. Broader multi-GPU and device-loss acceptance remains unverified.
