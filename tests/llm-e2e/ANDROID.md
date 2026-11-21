# Android E2E tests

Use two suites. Put a check in `android-simulated` when Godot input and application
state can establish the result. Put it in `android-runtime` when the result
depends on Android APIs, the exported APK, or the operating system.

| Environment | Canonical suite directory | Runner |
| --- | --- | --- |
| macOS Godot with touch controls; no device | [`suites/shared/android-simulated/`](suites/shared/android-simulated/) | `uv run tests/godot/test_dashboard.py test --suite android-simulated` |
| Android emulator or connected phone running the APK | [`suites/shared/android-runtime/`](suites/shared/android-runtime/) | `mise run android:test --automated --serial emulator-5580` |

## 1. Android behavior on Mac Godot

`suites/shared/android-simulated/` runs the production client with the Android
interaction profile. The test harness is a thin wrapper: it loads the real
client scene, injects touch events, and checks the real UI and remote session.
There is no separate test UI or duplicate gesture implementation.

```sh
mise exec -- uv run tests/godot/test_dashboard.py test --suite android-simulated
```

Generate all 29 simulated replay videos with:

```sh
mise exec -- uv run tests/godot/test_dashboard.py record --suite android-simulated
```

The suite enables touch controls automatically. Normal Mac clients continue
to use native desktop controls. On macOS, simulated tests and recordings render
in the background without displaying native windows or taking desktop focus.
Add `--headful` to the dashboard `test` or `record` command to watch the windows.

## 2. APK tests on an Android emulator or phone

`suites/shared/android-runtime/` requires an authorized ADB device. The runner
distinguishes emulator coverage from cases that require a physical phone.

| Automated APK case | Coverage |
|---|---|
| `android-entry-smoke` | Native/icon/Java loading, Home/resume, restart and APK update |
| `android-native-input` | Android-delivered taps and installed IME keys in the production connection form; Back hides IME |
| `android-apk-runtime` | Connected production manager: native taps dismiss messages, open/close Connections, fit a pane; real installed-IME input/edit/commit reaches the server while the active client fits its grid above the IME |
| `android-main-area-keyboard` | Production server manager claims the phone’s usable aspect ratio; portrait/landscape, competing-client touch claims, keyboard row reflow and preserved Main View |
| `android-touch-ui` | Shared Android UI scenario: tabs, Korean output, messages, menus, About, toolbar, trackpad after dialogs, real portrait rotation and fit; every tap target must be on-screen at native DPI |
| `android-gestures` | Direct finger targeting, pane/wire drags, title double-tap, exact pinch anchors, continued pan through finger lift/rejoin and released contacts |
| `android-remote-state` | Shared remote-client scenario: graph wires/manifests/status, StatusStrip/resources, font metrics, Unicode/ANSI, control keys, shared resize, second observer, reconnect, idle traffic, latency, new/close tab and rejected authentication |
| `android-images` | Standalone server image/scrollback scenario: first attachment, live inline and server-file images, discarded VT state restored on reconnect, deletion by original ID and 180 Unicode history lines |
| `android-multiserver` | Shared multi-server scenario: two standalone servers and three workspaces, namespaced IDs, independent input/resize, graph authority, chromium frames and JavaScript state across detach/reattach |
| `android-lifecycle` | Connected Home/resume during a held selection, output produced in the background, process restart, APK update, persisted connection, restored terminal state and unchanged server PTYs |
| `android-ime-resume` | Native Gboard Korean composition and final-consonant editing before and after visiting keyboard settings; requires English and Korean 두벌식 installed |
| `android-keystore` | Credential save/retrieve/delete across Android process launches |
| `android-visual-preferences` | Independent remote pane font shortcuts, every cursor trail style and Off, exclusive menu check state, continued terminal output |
| `android-usability-regressions` | Rendered first-row and Hangul pixels, keyboard-safe cursor and connection controls without changing the server grid, live standalone CPU/RAM, and recovery after detaching the last connection |
| `android-scene-retention` | Owner output held in copy mode, release to latest state, inactive-tab restoration and overview without new output |
| `android-remote-notifications` | OSC 9/99 from a remote PTY, no unsupported desktop helper or diagnostic panel, subsequent input |
| `android-typing-effects` | Real remote key input activates effects; focus changes cancel them without accidental reactivation |
| `android-filetree-layout` | Real server-side Neovim filetree and viewer, namespaced connected-pane placement in tiled and floating modes |
| `android-agent-title-stream` | Six real PTYs animate owner titles while producing Unicode output; verifies title propagation and frame-time budget without provider cost |
| `android-terminal-throughput` | Six real PTYs with deterministic colored Unicode scrolling; records P95/P99/max loop intervals and rejects sustained stalls |

The shared scenario implementations are under `frontends/godot/project/tests/client_scenarios/`; the
original desktop entry scripts call those same implementations. APK scenarios
use the real native terminal, renderer, production UI and remote protocol.
Canvas replay gestures are injected as Godot touch events inside Android;
`android-apk-runtime` separately uses Android-delivered ADB taps and actual IME
keys. The APK keeps the real display scale and rotates through Android APIs.
It does not substitute a desktop-sized viewport to make controls fit.

Image snapshot tests use the standalone server, as in the original headless
client scenario. The desktop cell-snapshot server does not transmit images;
these results do not certify image restoration through that backend.

The runner starts fresh loopback-only fixture servers and forwards their ports
with `adb reverse`. It exports once per invocation, installs disposable packages,
and records each UI case by default. Identical per-case APK artifacts share one immutable
file through hard links where supported; a new export replaces its directory
entry so older evidence stays intact. It never connects to the user's running server.
Unexpected diagnostics are sticky failures, including dialogs dismissed before
the next screenshot. Only exact intentional message fixtures are allowed.

Run all 47 automated APK cases (IME-specific prerequisites are reported BLOCKED):

```sh
mise run android:test --automated --serial emulator-5580
```

For physical-device performance comparisons, set `GRAFFITTY_TEST_SERVER` to
the current release owner binary (for example, `$PWD/dist/bin/gft`). Keep that
owner build and device geometry consistent between captures; debug-owner
timings are not a release performance baseline.
Use `--no-record` for a separate performance capture without Android's screen
encoder; screenshots, state assertions and error logs are still collected.
Each APK case writes `capture.json` identifying whether recording was enabled.
Do not compare recorded and unrecorded timings as if only the application changed.
The scenario status file is replaced only when its contents change, so unchanged
progress does not add periodic synchronous disk writes to the measured workload.

Remaining procedures are kept separate and reported BLOCKED unless actually
executed: `android-ime` adds broader composition/cancellation, portrait, emoji and OEM IMEs;
`android-system-ui` adds cross-app clipboard, external intents, split screen,
lock/unlock and actual VPN/network changes; `android-device-stress` requires a
physical phone for GPU, memory pressure and hardware behavior. The automated
Unicode key test is not evidence of real Korean IME composition. Neither a
process restart nor a simulated gesture proves physical-device behavior.

Add an APK run to the same replay gallery as the desktop cases:

```sh
mise exec -- uv run tests/godot/test_dashboard.py import-android build/android/e2e/RUN_DIRECTORY
mise exec -- uv run tests/godot/test_dashboard.py build
```

This converts the native screen recordings to the gallery's AV1 format while
keeping the original Android recordings and logs in the evidence directory.

The runtime runner writes results, device identity, screenshots and logs under
`build/android/e2e/`, including Android screen recordings for the UI cases.
The native-input case uses pinned `uiautomator2` through `uv run` to inspect all
Android windows, including the installed keyboard; the legacy `uiautomator dump` command only
exposes the active app window here. Exit codes are 0 for all pass, 1 for failures, and 2 when
checks remain blocked. It uses disposable packages and does not reset the
installed client. Build the current sources before running it.

The Android project disables Swappy frame pacing because the API 36 emulator
returns `VK_INCOMPLETE` during presentation with it enabled (both host and
SwiftShader GPUs). It retains Mobile/Vulkan and uses normal Vulkan presentation.
Unexpected render errors remain failures. Phone frame pacing still needs device
validation; an emulator pass does not establish physical-device smoothness.

For the existing credential automation, build first and select the emulator or
device explicitly (the APK and Android ABI must match):

```sh
mise run android:build
ANDROID_SERIAL=emulator-5554 mise exec -- python3 tests/android/test_android_credentials.py
```

It uses a disposable test package rather than the user's client data.

An [Android emulator](https://developer.android.com/studio/run/emulator) is
suitable for most runtime cases. For future automation, use Godot's test bridge
for canvas controls and [UI Automator](https://developer.android.com/training/testing/other-components/ui-automator)
for system UI and interactions outside the app. Godot-drawn controls need not
appear as native Android accessibility widgets.

Run the Mac suite first, then runtime cases, then a physical-phone smoke/stress
check before release. An emulator cannot certify the phone's GPU driver,
hardware-backed credential storage, OEM IME or low-memory behavior. Keep those
checks in the second suite with `physical_device = true` where required.

### Shared workspace regressions

Twenty-eight shared scenarios in `frontends/godot/project/tests/client_scenarios/workspace.gd` adapt the
existing desktop workspace regressions to a real standalone server and the
Android interaction profile. They cover pane controls, nearest-pane close,
fit/restore, tiling, independent tab layouts/views, tab dragging, resize,
external-keyboard prefixes, diagnostics copy, touch selection, bracketed paste,
PTY mouse reporting, history/search, tab titles, cwd inheritance, graph editing,
chromium navigation, crowded connection lists and credential recovery.

Run all twenty-eight without an Android VM:

```sh
mise exec -- uv run tests/android/test_android_runtime.py --simulated
# Show the simulated client while debugging one case.
mise exec -- uv run tests/android/test_android_runtime.py --simulated android-pane-controls --headful
```

The thin `frontends/godot/project/tests/client_scenario_desktop.gd` wrapper loads exactly the same scenario
as the runtime APK. Select individual cases by name, for example
`android-selection-copy android-tab-reorder`. Omit `--simulated` and pass
`--serial emulator-5580` to execute and record those cases in the actual APK.
These cases are also registered in `android-simulated`. The standard dashboard
test/record commands run all 29 simulated cases; recording captures the actual child client, not the headless fixture.
A Mac wrapper does not validate Android platform services.

The standalone simulated runner also uses background rendering by default on
macOS. It retains native visibility/activation checks under each case's
`background/` evidence directory; failed checks fail the scenario.
`--headful` opts into a visible client, including when `--movie` records it.
The dashboard carries this choice through its nested fixture processes.
Actual Android device and emulator runs retain their usual display behavior.

The graph-editing regression connects ports with an actual finger drag and
checks the server-owned edge and unchanged terminal dimensions. Chromium navigation
taps the address field, verifies focus survives the native IME, edits the
URL, and navigates with Enter. Both paths were added after the hands-on review
exposed gaps in earlier RPC-only coverage. Native Gboard settings-return input
is recorded separately by `android-ime-resume`.

Run the complete 38-case automated APK suite with:

```sh
mise exec -- uv run tests/android/test_android_runtime.py --automated --serial emulator-5580
```

`android-main-area-keyboard` runs through the production Servers manager, including
its combined connection. It checks server-acknowledged usable dimensions, a second
client taking and yielding the size claim, and repeated keyboard reflow without
leaving Main View. The simulated case supplies animated inset heights; the APK
case opens the real IME. Retain and visually review the native recording.

### Physical tablet remote regression run

```sh
GRAFFITTY_TEST_SERVER="$PWD/dist/bin/gft" mise exec -- uv run tests/android/test_android_runtime.py \
  --serial SERIAL --automated --output build/android-tablet-perf/e2e
```

The server runs on this Mac and the APK uses the real remote protocol over ADB
reverse, including independent owner/client state. This suite complements the
Tailscale-connected interactive agent workload; ADB reverse does not measure
Wi-Fi jitter or VPN reconnection. Never infer remote correctness solely from a
desktop replay. Each case keeps its screen recording, final screenshot, sticky
diagnostic state and process logcat. Failures also keep a Python traceback.

The lifecycle entry case repeats Home/resume three times before process restart
and APK replacement. Vulkan surface failures are failures, even if the next
frame recovers. The native surface-release bridge's errors are checked too.

Throughput intervals measure the Godot main loop, not display FPS or input
latency. The six-pane workload runs for ten seconds with a two-second recovery
window and fails at P95 >=50 ms or any >=500 ms interval. Real provider CLIs
remain a separate bounded, cheap-model check; this deterministic test needs no
provider account or model spend. The installed IME is recorded. Gboard-only
Korean recovery and shortcut cases are BLOCKED when another keyboard is active;
this is not evidence of an app failure or successful OEM IME coverage.
