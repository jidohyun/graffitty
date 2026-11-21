# GPU startup

The Windows shortcut and the installed Linux desktop and command-line entry
points start a supervisor before Godot initializes its rendering device.
Windows keeps a GUI-subsystem entry point and launches its watcher without a
console. The Linux export plugin places the embedded engine beside the shell launcher as
`GraffittyRuntime`. Resolving the launcher symlink pins retries to one release.
The macOS launcher continues to exec its Metal runtime directly.

| Platform | Attempt order |
| --- | --- |
| Windows | D3D12, Vulkan, OpenGL Compatibility |
| Linux | Vulkan, OpenGL Compatibility, OpenGL with Mesa software rendering |

The watcher preserves the engine and app argument boundary, working directory
and environment across retries. Explicit renderer flags and headless tools
run directly. On Linux the GUI and its server helpers start with system loader
paths. The launcher carries the original `LD_LIBRARY_PATH` and `LD_PRELOAD`
in private variables. The server restores those values when constructing the
PTY environment, before explicit per-terminal overrides and holder handoff.

## Recording a successful start

Each child gets a private attempt directory under the app's state directory,
in `gpu/`. The first autoload records the actual renderer, adapter and API
version. In `gpu/history.json`, each successful adapter's `presentation` records
the actual display server, Graffitty's window transparency result at startup,
and both Godot's and Graffitty's results after drawing. On X11, Graffitty checks
the window's XRender alpha mask and the compositor selection for its screen.
NVIDIA Vulkan can report an opaque swapchain even when Mutter composites the
window's alpha. Display observations do not participate in adapter identity.
The autoload acknowledges health after a drawn frame, two seconds of runtime,
and a second draw. The supervisor observes the child exit status even if the
engine dies before the first autoload. A clean early exit honors the user's
close request. A crash after the health acknowledgment preserves the exit
status without relaunching the app.

The Windows project disables `rendering/rendering_device/fallback_to_d3d12`.
This prevents a Vulkan attempt from re-entering D3D12 in Godot before the
watcher can intervene. Forward fallbacks to Vulkan and Compatibility remain
enabled. Godot can use ANGLE/D3D11 inside Compatibility. The watcher retries
that backend as OpenGL and records its exact name, `opengl3_angle`. Godot
4.7.2’s Windows ANGLE display requests D3D11 without a WARP device attribute.

## Failure handling

The startup watchdog uses a monotonic clock and gives a hardware renderer
30 seconds without progress, or Mesa software rendering 60 seconds. The
autoload reports arrival, first draw, and entry into the forced second draw.
A responsive minimized window sends a heartbeat while waiting to present.
A scheduling gap longer than two seconds gives the child a fresh interval
after sleep or host starvation. On Windows the watcher also recognizes the
child's native Godot video-driver initialization error dialog by PID, class
and title. It rechecks progress, health and exit before terminating just the
failed frontend. Any other running frontend and the session server continue.

Every failed startup advances to the next eligible choice. History records the
phase, reason, timestamp and available exit code. Timeouts, native graphics
initialization failures and observed device loss spend the crash budget.
An unclassified early exit also gets a retry. It is recorded separately and
spends no GPU crash budget. Three attributable failures on one mode exclude
it until its count decays. One failure is forgiven per full five minutes since
the previous attributable failure. A failure on a different mode starts a
new count. After startup, a device-loss diagnostic accompanied by an abnormal
exit is recorded for the next launch. The running session is never relaunched
by the watchdog after health acknowledgement.

A healthy fallback gets first preference for five minutes. If it fails, the
remaining eligible modes are available within the same launch. After cooldown
the next launch probes higher eligible modes again. Changing the application
version or inventory clears history immediately. A changed observed adapter,
renderer or API also triggers one fresh selection. Windows uses the predicted
Godot D3D12 adapter, DXGI PCI identity and driver build for its driver rules.
Rule 1 skips D3D12 for the listed AMD Vega APU families on driver 27.20.1034.6.
The rule ID is recorded even on successful launches. On Linux the fingerprint
includes DRM devices, kernel, dynamic linker cache and driver-selection
environment. A linker-cache refresh can trigger another probe.

The watcher atomically replaces its v1 history file and stores the effective
renderer in a marked section of the installation's `override.cfg`. Engine
arguments select the mode on read-only installations. The supervisor grants
one frontend permission to show a notice when it commits a fallback transition.
The frontend displays it for Compatibility or software rendering. A Windows
hardware fallback from D3D12 to Vulkan keeps Forward+ effects and stays silent.
Exhaustion writes the attempts and matched rule IDs to `gpu/last-failure.json`
under the state directory. The supervisor shows the reasons and log path in
a native Windows message box or Linux desktop dialog. Linux falls back to
stderr and a desktop notification if a dialog cannot be shown.

The ordered modes, crash forgiveness and driver rules draw on Chromium’s
[GPU fallback](https://chromium.googlesource.com/chromium/src/+/da15ed75d0263bef51185a44bd3438c9dd3277f9/content/browser/gpu/gpu_data_manager_impl_private.cc#1633),
[crash accounting](https://chromium.googlesource.com/chromium/src/+/da15ed75d0263bef51185a44bd3438c9dd3277f9/content/browser/gpu/gpu_process_host.cc#742)
and [watchdog](https://chromium.googlesource.com/chromium/src/+/da15ed75d0263bef51185a44bd3438c9dd3277f9/gpu/ipc/service/gpu_watchdog_thread.cc#471).

Chromium shared textures require a compatible rendering device. Linux desktop
clients use negotiated video or PNG, including on hardware Vulkan. On Windows
the client offers D3D shared textures only on D3D12. On macOS the browser
and terminal GPU paths require Metal. The existing negotiated browser stream
and terminal asset delivery remain available when shared textures are unavailable.
Linux decoder discovery initializes the system VA-API dispatch table before
probing FFmpeg, including when the frontend probes decoders before encoders.
Desktop builds import S3TC textures for the desktop export presets even on
ARM build machines.

## Verification

Run `cargo test -p graffitty-cli gpu_startup` for policy and child-process
tests, and `cargo test -p graffitty-platform gpu_loader` for the shell
environment round trip. On a machine with a display, set `GRAFFITTY_TEST_GODOT`
to the Godot executable and run
`cargo test -p graffitty-cli real_godot_draws -- --ignored --nocapture`.
The integration test forces the Vulkan process to exit before engine startup,
then requires Godot itself to report healthy OpenGL frames on two launches.
