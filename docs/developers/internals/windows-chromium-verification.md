# Windows Chromium verification

These are recorded results, not a new test run. Build using
[Windows embedded Chromium](windows-chromium.md).

## Verification

| Date / scope | Result | Limit |
| --- | --- | --- |
| 2026-09-24, Godot 4.7.2/Windows 11/GTX 1660 SUPER | Full D3D12-validation run, 3D world, tabs/order/identity, terminal/close checks passed; zero export errors | Functional, not throughput/general GPU acceptance |
| 2026-10-01, renamed CEF capture switch | Standalone animated GPU capture passed, no visible windows | Full Godot run above not repeated with this runtime |
| 2026-10-26, standalone Chrome/Alloy | Storage, tabs, popups, Inspect, presentation, resize/backpressure, owner replacement passed; clean exit, zero GPU errors | Actual D3D readback test, not full Godot |
| 2026-10-26, physical Android tablet | Both backends passed 42 checks, HEVC NVENC/D3D11 → Qualcomm decoder | Streaming through SSH, not Windows frontend or throughput |
| 2026-11-20, Windows / Intel Iris Xe / driver 30.0.100.9836 | A real 960×540 Chromium pane streamed through H.264 QSV. The Windows D3D11VA decoder reproduced two page colors within three levels per channel. Seven crate tests passed, including H.264/HEVC scaling, static updates, recovery keyframes and zero encoder readbacks. | AV1 encode unavailable. Hardware MFTs emitted no first D3D11 packet and failed the probe. AMD AMF hardware unavailable. |
| 2026-11-20, Windows Server 2025 Hyper-V, Microsoft Basic Render Driver | Chrome (984×605) and Alloy (1000×700) delivered WebSocket PNG updates. Every pixel matched opaque RGB (208,32,32) and then (32,64,208). A video-only client received the no-hardware-codec error for each backend. | Embedded browser panes through a WebSocket client. |

On the GTX 1660 SUPER, hardware units passed H.264/HEVC round trips, BGRA/RGBA, odd-size GPU scaling,
recovery keyframes, and immediate static updates. The GPU advertises no AV1.

## Behavior under test

- Caption click, system close, and WM_CLOSE dismiss native UI without losing the page.
- Each native open obtains foreground activation and page focus.
- Inspect closure keeps session cookies; original observer closure keeps other tabs usable.
- Native page colors must be opaque: RGB alone previously passed invisible Alloy output.
- Android covers animation, adaptive resolution without CSS reflow, static updates,
  titles/URLs, tabs, popups, original-page closure, and preserved owner terminal.

## Run native host checks

Use the logged-in desktop, after building the host:

```powershell
cmake --build target/chromium-windows --config Release --target chromium_capture_test
python tests/chromium/chromium_native_backend_e2e.py --host dist/chromium-windows/graffitty_chromium.exe --capture-library target/chromium-windows/Release/chromium_capture_test.dll --artifacts .cache/chromium-backend-tests
```

## Run transport and frontend checks

```powershell
cargo +1.94.0 test -p graffitty-chromium-video shared_gpu::tests --lib
cargo +1.94.0 test -p graffitty-session-transport --lib
uv run tests/godot/test_dashboard.py test --headful --suite chromium
```

The Windows `chromium-native` supplement checks tabs, page identity/zoom,
native presentation, and GPU import on return. Keep native-window PNGs with
replay footage.

## Require hardware video

```powershell
. .\tools\prepare-windows-video.ps1
$env:GRAFFITTY_VIDEO_TEST_REQUIRED = '1'
cargo test -p graffitty-chromium-video -- --test-threads=1
```

These checks require actual encode/decode, retained texture lifetime, fresh
frames, alpha/colors, and zero encoder CPU readbacks. PNG cannot pass the physical
`android-chromium-hardware-backend` suite.
Evidence includes recordings, encoder utilization, state, logs, and artifact hashes.
The runtime lives in its own Windows DVC output, independently of world assets.
