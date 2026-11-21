# Coverage, execution, and reporting

These specifications are broader than implemented automation. Keep pass/fail/blocker
records per scenario; do not mark the entire requirements set done from a build.

## Prefix split punctuation (IN-10)

2026-11-15: shared Rust resolution uses the typed `|`, `_`, `\`, and `-`
characters after the workspace prefix. Shift, Option, and AltGr needed to produce
them do not change the split direction. Explicit modifier bindings keep priority.
The acceptance steps are in [input.md](input.md#in-10--prefix-split-characters-follow-the-keyboard-layout).

Shared Rust and Godot key-event checks passed for ordinary, Shift, Option, and
Ctrl+Alt/AltGr symbol events, including a shifted non-split character. These are
simulated layout events, not physical keyboard-layout or Android device passes.

## Projected graph port spacing (UI-05)

2026-11-14: port rows use projected pane-edge height and actual themed hit targets.
Expanded ports retain at least 44 logical pixels of separation for touch and 28
for mouse input. Five touch outputs fit a 200px pane at quarter zoom; an 80px pane
compacts. Automatic wire routes remain cached while their endpoints follow the
spread ports. Logical ports, edges, permissions and terminal bounds are unchanged.

Passed on macOS: five Rust scene-core geometry tests, the existing
`graph_compact_ports_smoke.gd` fixture in mouse and `--touch-controls` modes
(60 assertions each, no runtime errors/warnings), and 77 graph-editing assertions.
The editing fixture emits its expected warning when undo would overwrite a
concurrent connection change. These are headless layout/hit-testing checks, not
physical Android touch acceptance. Phone/foldable feel and orientation checks
remain pending; no Android build or install was performed for this change.

The refreshed `touch-ports-20261114` mobile demo also passed its complete
desktop-mobile replay against an isolated real server, with direct socket drags
and expanded output rows visible in the rendered overview. This is simulated
mobile input on macOS, not a physical-device E2E pass.

Later on 2026-11-14, the signed Android release was built and installed in place
on an SM-F966N. The installed APK hash matches the built artifact, the app data
directory was preserved, and the launch command succeeded without startup errors
in the app log. The device remained locked, so rendered UI and physical touch
behavior were not verified. The full macOS Android-simulated suite passed only
1 of 33 replays: failures included shader compilation, a stale `MobilePointer`
test property, and fixture connection timeouts. This installation is not an
Android acceptance pass.

## Optional mobile Flat 3D and platform-condition audit (UI-13)

2026-11-13: Android and iOS default to Flat 2D and offer both built-in worlds
under View → World, with all eleven translations. Explicit Flat 3D startup
configuration is honored. The shared mobile checks now cover haptics, floating
control orientation profiles, keyboard-aware camera following, diagnostic touch
targets, font download limits/recovery, render diagnostics and web-only terminal
links. Android's Java IME/insets, launch cover, native text selection, font fallback,
permissions, density scaling, codecs, TLS and credential adapters remain specific
to that platform; iOS retains its own native paths.

Passed on macOS: native extension build, changed-script parser checks, 30 Godot
unit tests (camera following, hyperlinks, orientation profiles, checkpoints and
localization), 7 Rust font-cache/rendering-policy tests, and font-download smoke.
The rendering-policy test covers both Android and iOS hardware defaults.
The simulated real-server `android-retained-transitions` run passes all 51
scenario assertions: World menu selection/checks, both flat renderers, final-frame
colored text, retained Push/Pull rendering, viewport cleanup and surviving shell.
Its obsolete Dust case was removed because the current tab-transition API accepts
only None and Push/Pull. The Flat 3D final frame was visually inspected.

The full runtime harness still **fails** on a shutdown warning about 11 leaked
RefCounted instances. The separate font-local-cache smoke also completes its
assertions with that same warning. This is not a clean E2E pass. Evidence stays
outside Git. The iOS native-only build was queued behind another build's lock
and canceled without compiling; no Android/iOS device run or installation was
performed. UI-13 and the shared iOS control checks still require hardware evidence.

## Session viewport retention and flight effects (UI-08)

2026-11-14: Fly away and in now prepares the full destination terminal geometry
outside the camera crop, retains its rendering through the flight, and keeps the
assembled image until the normal live crop has repainted. The new
`uv run tests/godot/test_session_effects.py --case landing --evidence <fresh-short-directory>`
regression compares static colored markers in the destination, final animation
frame and six consecutive handoff frames. On macOS Metal, all 32 screenshots
across both flight effects in Flat 2D and Flat 3D matched the settled marker pixels
exactly. The original
fixture had zero cyan-marker overlap at landing and in the blank first live frame.
The native extension build, 10 switch-animation unit tests, and all 223 assertions
in the existing session-effects fixture also pass. These are isolated desktop
renderer tests, not Android device acceptance. No installed app or user server
was restarted.

2026-11-12: session changes capture the departing client view before the transport
changes workspace identity. Desktop windows keep independent in-memory views;
the managed workspace uses its existing device-local store. Delayed autosaves
cannot assign departing tabs to an arriving session. `test_live_session_switch.py`
passes all three tests, including desktop and simulated Android presentations, distinct
pan/zoom round trips, immediate switches, failed switches, new sessions, CLI
completion, retained PTYs and independent observers. Six view-state unit tests pass.

`tests/godot/test_session_effects.py --evidence <fresh-short-directory>` exercises
both flight effects in Flat 2D and 3D, viewport round trips, and CPU/RAM presence
from the first arrival frame. `test_live_session_switch.py` also checks immediate
cached resource delivery after topology, correct destination PIDs, and preserved
CPU baselines for inactive sessions. All pass on macOS Metal with hidden native
windows. Five switch-animation, two resource-monitor, and six view-state unit
tests pass. The desktop and simulated Android switching checks pass; these are
not physical-device acceptance results.

2026-11-12 (later): in the Android manager, moving to a session on another
connected server now plays the session flight too; a finger swipe between
servers keeps its own slide. A temporary probe drove the simulated Android
manager (headless, Flat 3D) against two private servers: same-server and
cross-server changes all showed the session effect, no tab effect, and no
camera discontinuity when the effect ended. A reported jump cut after the last
flight frame on a physical foldable was not reproduced and remains open.

## Software-rendering defaults

`graffitty-client-config::rendering` tests CPU adapter detection, known software
renderer names, integrated/discrete/virtual/headless exclusions, and explicit
world/profile/power overrides. `tests/rendering_defaults_smoke.gd` checks the
native adapter and resolved defaults against the actual active renderer; use
`--expect-software` only when running a real software renderer. This test flag
does not override detection. The session-effects fixture also checks that Off
skips session capture/flight and World Default releases the hold.

Passed on macOS: 38 client-config Rust tests (including four renderer tests),
three OSC protocol tests, 25 Godot unit tests, headless and actual Metal adapter
checks, and the Flat 2D/3D session-effects fixture with Off. The Metal adapter
reported an integrated Apple GPU and retained normal defaults. No real
llvmpipe/SwiftShader rendering pass was run; software classification is unit-tested.

The Android hardware follow-up adds an Adreno case with no configured world or
profile; all five renderer-policy tests pass. Physical Android startup logs show
Godot loading the Adreno Vulkan driver. Android's existing presentation defaults
to Flat 2D, and this hardware path leaves World Default effects enabled. No device
configuration was changed. This is renderer/default-policy verification, not a
physical-device visual-effects acceptance run.

## Mod registration and title folding (UI-09)

2026-11-12: `[mods.<id>]` in `client.toml` now controls bundled overrides and
new panels/pane strips through the shared Rust resolver. Built-in JSON manifests
were removed. Entry paths, ordering, hosts, docking constraints and appearance
are validated before startup; configured props survive native presenter updates.
Title clicks/taps fold individual docked or floating panels and preserve expanded
geometry and saved folded state. Drag/cancel handling stays separate from clicks.

Passed: 34 client-config Rust tests; 40 mod-engine tests including explicit entry
paths, sibling imports and storage identity; `mod_configuration_smoke.gd`,
`mod_defaults_smoke.gd`, `embedded_mods_smoke.gd`, `agent_status_badge_smoke.gd`,
`list_docking_smoke.gd`, and `panel_folding_smoke.gd` (desktop and mobile fixtures).
Floating panels now have an application-drawn title and resize edges. Title
folding and docking consume press/move/release events, with no pointer polling.
A native drag keeps an empty transparent window mapped while its content is in
the preview, preserving the original input stream. Wayland movement/resizing is
delegated to the compositor; folding needs only window-local coordinates.
The folding fixture also passed with real macOS windows at 1.5×, using viewport
injection for native title clicks, preview entry/exit and docking on release.
Headless desktop/mobile fixtures cover same-frame click/release, restored body
layout, canceled touch/mouse release, Escape, second contact, focus loss and
occlusion by another window. Mouse and emulated-touch close-button checks pass.
Expanded/folded native renders were inspected. This is not physical OS
mouse-event evidence.
Five backdrop and ten localization unit checks and the changed-script parser
checks passed. The shared `android-list-docking --simulated` harness passed with
new viewport-injected floating and docked title taps. The existing Android touch
smoke passed in a real macOS window at 1.5×, including floating title fold/unfold.

One unrelated mod test remains failing: `websocket_video_warns_in_yellow_with_its_reason_in_the_tooltip`
expects a text `!`, while the current status-line script draws `triangle-alert.svg`.
The 40-test run excludes that assertion after recording its failure. No physical
Android/iOS run, Windows/Linux run or production installation was performed.
Wayland was not exercised here; native cross-window docking still requires shared
desktop coordinates. Filesystem/process mod APIs remain unavailable.

## Confirmation action layout and local server close (UI-05)

Window close (×) never ends a session: local windows offer Kill Server, Detach
and Cancel; remote windows offer Detach and Cancel. On 2026-11-17 the native
`tab_window_e2e.py --scenario close --gpu` route passed (Cancel/Enter, Detach of
an idle window keeping its session and shell, root promotion, reattach, and a
final-window Detach that quits the app while the owner keeps running), as did
`--scenario close-server --gpu` (final-window Kill Server quits the app and the
owner exits). The French close-dialog capture was inspected. `remote_window_close_smoke.gd`
passes for offline, Cancel, Detach, disconnect-while-confirming and federated
windows. `responsive_dialogs_smoke.gd` passes for the two-action remote dialog in all
eleven languages; its `--local-close` variant currently aborts headless with a Godot
message-queue overflow, also on the previous test revision, so the three-action
layout is covered only by the native capture above.

The `test_live_sessions.py` local-server-close case passes against disposable real
servers: authenticated loopback WebSocket shutdown is rejected, local attached
and detached PTYs end, and a separate remote server stays usable. The CLI/server
build, Godot script checks and all ten localization tests pass. These are desktop
and simulated-layout results; no physical Android/iOS run or installation is claimed.

## iOS/iPadOS port (minimum 16.0)

`tests/tools/test_build_ios.py` passes eleven build-configuration tests: minimum OS and
bundled mod assets, signing-input validation, all eleven permission localizations,
remote-client startup, framework deployment stamps, and export verification. The ARM64 release extension links with the iOS Keychain
adapter and iOS-specific bindings. Godot import/export, the signed Xcode device
build, and strict/deep signature verification pass. The extension and app executable
have iOS 16.0 Mach-O minimum versions; the app plist also declares 16.0
(lowered from 18.0 so iPadOS 16 hardware can run it; earlier evidence below was
recorded against 18.0). All 31
client-config Rust tests and four headless touch-config tests pass. These are build
and unit results, not iOS physical-device E2E. Xcode currently reports the intended
physical device unavailable. Reuse the remote-client and touch-control
scenarios from this document when it is connected, unlocked, trusted, and in
Developer Mode; do not count the Android evidence as iOS evidence.

Reviewed native media adapters: 24 `graffitty-dictation-audio` tests pass with
`device-capture`, including cancel/restart ownership, permission waits, interruptions,
and worker panic completion. All 18 Chromium video tests pass on macOS with
`--include-ignored --test-threads=1`: hardware H.264/HEVC, cropped sizes,
NV12/RGBA colors, split parameter sets, resolution changes, and corrupt-input
containment. Godot headless tests pass: dictation (13), chromium_events (25),
and localization (10). Failed microphone polls discard queued and same-poll audio;
normal stop still flushes its tail. App pause/resume releases hardware decoders,
acknowledges queued frames, retains the displayed texture, and rebuilds at the
next keyframe without rejecting the codec.

The reviewed ARM64 iOS build and final repackage pass deep/strict signature,
signing-team, bundle-ID, every Mach-O minimum version, and permission-localization
verification. Both app and embedded framework plists now agree with the iOS deployment-target
binaries (Godot's generated framework stamp had incorrectly said 15.0). Permission
purpose strings and new audio errors have all eleven translations. These are not
physical iOS microphone or video passes. Pending:
UI-06 microphone permission/interruption/stop/cancel cases, and a real remote
Chromium stream on iOS (H.264/HEVC capability negotiation, pixels, resize, rotation,
background/resume, recovery and PNG fallback). No AV1 or zero-copy texture
support is claimed for iOS.

## Default docking and embedded mods (UI-07 / UI-09)

Headless `mod_defaults_smoke.gd`, `status_line_smoke.gd`,
`embedded_mods_smoke.gd`, `tab_list_scroll_smoke.gd`,
`tab_list_touch_smoke.gd` and `command_line_layout_smoke.gd` pass.
They cover first-open left/bottom placement, deliberate floating placement,
mod text/hit regions, touch cancellation and momentum, and command-line bounds.
The 12 `adaptive_zoom` unit tests and `cargo test -p graffitty-mods` pass.
`tab_search_smoke.gd` remains blocked by its replay's pane split not creating a
window, before search assertions. Dock fixture shutdown reports three leaked
objects. No installation, visual acceptance or physical-device E2E is claimed.

## Pane Status rename and Resource Monitor table (UI-09R)

The focused-pane panel formerly called Resource Monitor is now **Pane Status**
(`pane-status`, `PaneStatus`, dock key `pane_status`); earlier entries in this
file that name the Resource Monitor's readout, rails or band docking describe it.
**Resource Monitor** is now the all-pane table (`resource-monitor`,
`ResourceMonitor`, dock key `resource_monitor`).

Passed headless: `cargo test -p graffitty-mods --test resource_monitor` (4: rows,
captions, pinned totals with the per-computer CPU mean, click-to-focus; header
sort cycle, right-edge resize, drag reorder, persistence across copies;
computer/session filters with **All**, captions without the chosen computer,
computer/session sorting; compact rail), `cargo test -p graffitty-client-core --lib
pane_resources` (3), `resource_monitor_smoke.gd` (published rows, live sample and
total updates, a closed pane leaving, row click focusing its pane), and
`mod_defaults_smoke.gd`, `pane_status_drag_smoke.gd` (desktop and `-- --android`),
`pane_status_band_docking_smoke.gd` (top and `-- --bottom`), `pane_header_smoke.gd`,
`agents_dialog_smoke.gd`, `status_line_smoke.gd` and the localization unit tests.
Not run: the client scenarios that need a standalone server, a physical Android
device, visual acceptance, and remote or multi-window use of the table.

Pane column, sideways scrolling and touch hold-to-drag (2026-11-10). Passed
headless: `cargo test -p graffitty-mods` (resource_monitor 6, including `%N`
numeric sort and a 360-pixel panel scrolling sideways while vertical wheels and
drag-reorder still work), `resource_monitor_touch_smoke.gd` (finger slide scrolls
columns without focusing a pane, sliding past the panel's edge returns fully,
hold-then-drag reorders a header without scrolling), `resource_monitor_smoke.gd`,
`list_touch_scroll_smoke.gd`, `tab_list_touch_smoke.gd`, `status_line_smoke.gd`
and the localization unit tests. The compact status line's prefix chip now shows
the configured chord as a keycap instead of ⌘; no test asserts that form yet.
Not run: a physical Android device or an installed build.

## Pointer capture and horizontal thumb regression (UI-09R)

Passed: `cargo test -p graffitty-mods --test render --test resource_monitor`
(7 renderer tests, 11 Resource Monitor tests), including draggable horizontal
thumb, header drag leaving and returning, release outside ending a resize, and
horizontal-resize cursor. `cargo check --manifest-path
frontends/godot/extension/Cargo.toml` passed. The count header is intentionally
`#procs` in all languages; its tooltip remains localized.
The full mods suite has an unrelated status-line warning-color assertion failure.
Not verified: an installed build, physical mouse/trackpad or Android device.
These are engine tests, not physical-device E2E evidence.

## Translucent panels, scrollbars, filters and live column drag (UI-09R)

`mod.json`'s `background_opacity` makes a panel's surface translucent (the
Resource Monitor uses 0.78); overflowing mod lists show a scrollbar by default
and its thumb drags; macOS trackpad pan gestures scroll mods; mod popups paint
above the rows they cover (`ModView` numbers canvas items in paint order).

Passed: `cargo test -p graffitty-mods` (render: default scrollbar and thumb drag,
timer cancel, Pane Status readout scrolling instead of squashing; resource
monitor: multi-select Server/Session filters with All, arrows, live drag preview
with eased columns, vertical row scrolling, plus the earlier table tests), and
headless `resource_monitor_smoke.gd` (manifest opacity, one translucent surface
when docked, per-pixel transparency floating, opaque panels unchanged),
`pane_status_drag_smoke.gd`, `pane_status_band_docking_smoke.gd`,
`mod_defaults_smoke.gd`, `agents_dialog_smoke.gd`, `sessions_dialog_smoke.gd`,
`list_touch_scroll_smoke.gd`, `list_docking_smoke.gd`, `status_line_smoke.gd`.
A windowed macOS capture of the fixture showed the docked panel at 78% over the
workspace, the filter list opaque over the rows, the arrow and funnels, and the
floating window's viewport at alpha 0.78 with per-pixel transparency set. Not
verified: the desktop blur behind a floating panel, a real trackpad swipe,
Windows, Linux and Android.

## SwiftKey Ctrl+Enter investigation (IN-03)

The disposable native `tests/android/test_android_ime.py` instrumentation passed on an
Android foldable with a new balanced Ctrl-down / Enter-down / Enter-up / Ctrl-up
case followed by plain Enter. Native callbacks preserve Ctrl and release it.
This injects InputConnection events; it does not tap SwiftKey's modifier/Enter
keys or verify terminal bytes. The reported real SwiftKey-versus-accessory Ctrl
mismatch remains unresolved; no production fix or installation is claimed.

## Hangul syllable streaming (IN-02)

`tests/android/test_android_ime.py` passed on an Android tablet with new cases: a
whole-word Korean composition sends each finished syllable and previews only
the open one, Backspace into a sent syllable erases and reopens it, committing
the word sends only the remainder, and a Japanese composition stays local until
committed. This replays InputConnection calls; no real keyboard was typed on,
no terminal bytes were recorded, and the app was not rebuilt or installed.

## `@graffitty/playwright` launch and placement

`launch()` creates a chromium pane, places it with `pane.place` (which now shows
a hidden pane), retries a not-ready page, attaches, and `close()` removes it.
The package now accepts the session server's `ipc://` endpoint (previously it
passed that string to `net.connect` and could not connect from server-backed
terminals) and loopback `tcp://`. Passed: 8 package unit tests; the real-GUI
`tests/e2e.py` (Node and Bun attach, Playwright Test fixture, revocation, and
hidden `launch()`); a live run from a server-backed terminal (`ipc://`, create,
place, attach in 1.3 s, trusted click, close). The E2E fixture serves the
frontend API, which has no `pane.place`, so visible placement is covered by
the live run and Rust tests (`shown_hidden_pane_placed_beside_joins_the_tiles`,
CLI `chromium_new_placement_follows_creation`). The installed server predates
show-on-place, so the live pane was placed but stayed hidden.
The E2E now uses a short `/tmp` directory: macOS's default temp path made the
terminal holder socket exceed `SUN_LEN`, failing server startup.
`test_graffitty_cli.py`: 18 pass; two agent-hook tests time out with or without
the inherited environment, unrelated to these changes.

## Agents in-place titles, nvim zoom settle and centered reveal

Agents rows update titles in place; only structural changes rebuild, so hover
Pin no longer flickers and clicks survive retitling (`agents_dialog_smoke.gd`).
`FramingSettle` (scene-core) keeps adaptive zoom from following transient
alternate-screen clears: 12 typing-camera Rust tests and 14 `adaptive` Godot tests
pass. Fitting panes are centered by keyboard reveal when not fully visible: 9
workspace-core navigation tests and 10 navigator tests pass. `pane_inspection_test`
still fails 10 cases on the pre-existing missing `workspace_chrome_bottom` fixture.
No nvim session was recorded on screen; the zoom sequence is unit-level evidence.

macOS: release package passed `check-package.py` and was installed in place.
`gft restart-server` kept all 18 terminals. A first restart accidentally ran
before replacement (an aborted install step) and lost one Chromium pane, which
restart-server does not preserve; the second ran on the new build. The GUI
frontend was not restarted, so frontend changes are not yet live.

## Agents server/session captions (UI-07)

Headless `agents_dialog_smoke.gd` passes: captions appear above row groups, repeated
server/session contexts are skipped, local agents show only the session, and the
caption uses 10-pixel text. 7 `agents` unit tests pass, including manual/automatic/ID
session labels. No visual review, physical device run or installation.

Later: the caption no longer has a fixed 14 px height (its 10 px text was cropped);
it sizes to its text and tucks against its row. Graphical
`agents_status_ring_smoke.gd` passes on macOS: the idle ring and done dot are drawn
as true circles, mirror difference 0.00, where the whole-pixel style box had made a
7 px ring with a 1.5 px stroke lopsided (2 px on one side, 1 px on the other).

## Wrapped mod text no longer overlaps; status line icons when narrow

Pane Status lines overlapped in a narrow sidebar on the Android foldable. The mod
painter measures and draws text with one shared paragraph; drawing a one-line
label left it without word wrapping and limited to one line, so a wrapped line
was then measured one line tall and the next line drew over it. Measuring now
resets both. `pane_status_wrap_smoke.gd` passes (wrapped lines, no overlap) on the
rebuilt extension. The status line gets its width as a mod prop and, when its
labels would not fit, shows the effect switches as icons (accent when on, dim when
off), the prefix as a key cap of its chord (another agent's follow-up change) and
the agent count without the word. `status_line_smoke.gd` passes 29 checks,
including 360 px fit, no labels when narrow, tooltips, and labels returning when
wide; a graphical capture at 900 and 420 px was reviewed. Installed on the
foldable without Godot errors; its screen was asleep, so no device screenshot.

## Floating buttons on top of everything (UI-02)

Floating buttons were at canvas layer 110, under the command line, notifications
and every embedded window (floating panels, dialogs, popups at Godot's layer
1024). They are now layer 2000. Drawing on top was not enough: Godot hands a
press inside an embedded window to that window and focuses it, ignoring layers
and its mouse-passthrough settings (read in 4.7.2 `Viewport::_sub_windows_forward_input`
and confirmed by probes). Each button therefore has an invisible, unfocusable,
always-on-top embedded window over it that absorbs the emulated press and clears
panel focus without taking it, so the touch reaches the button and typing stays
put; real mouse input on it is handed to the button. `floating_buttons_on_top_smoke.gd`
passes 7 checks five times in a row (drawn over a focused panel, touch, focus,
typing, mouse, hidden button releases the area); one earlier run failed the mouse
check once. `floating_buttons_smoke.gd`, `floating_capture_smoke.gd`,
`touch_menu_smoke.gd`, `mobile_floating_chrome_smoke.gd`,
`touch_keybar_repeat_smoke.gd`, `android_list_docking_smoke.gd` (52), the unit
suite (layer-order test updated) and simulated `android-list-docking` and
`android-text-size` pass. The `⋯` menu pill is unchanged (menu layer). No device run yet.

## Touch controls: `[touch]`, mod faces, clean outlines (UI-01, UI-02)

The Android-only "Android controls" profile is now "touch controls"
(`InteractionProfile.touch_controls()`, `--touch-controls`, `TouchKeyBar`); the
`android` bindings platform key is unchanged. client.toml `[touch]` chooses the
strip keys (built-ins or `{label, action, text}`) and the floating buttons,
validated in `client-config` (3 new Rust tests). The bundled `touch-controls` mod
paints every face; native buttons keep input and chrome. A graphical capture of
the strip (plain, Ctrl armed, Alt and Shift locked) and the floating buttons
(keyboard, microphone, stop, disabled, recording, text size) against the
committed code: the strip is pixel-identical; the text-size pill differs in 2
pixels; icon faces differ only along anti-aliased edges (114 pixels, at most
35/255), because the mod rasterizes SVGs at 2×. Floating buttons and the `⋯` pill
now draw their outline as a true curve (`RoundOutlineStyle`): ring brightness
spread fell from 45–110 to 31–56 with no bright seam dots.
Passing: `touch_config` unit tests (4), `android_prefix` (11, updated for faces),
full unit suite except the existing pane-inspection failure,
`touch_keybar_repeat_smoke.gd` (28), `floating_buttons_smoke.gd`,
`floating_capture_smoke.gd`, `touch_menu_smoke.gd` (17), `android_ime_keys_smoke.gd`
(7), `mobile_floating_chrome_smoke.gd`, `android-text-size` (simulated). Also
failing on the committed tree, not from this change: `mobile_menu_smoke.gd` (3
menu-open checks), the dictation replay's server half (transcription disabled in
the isolated server), and an intermittent Android docking edge-resize check.
`android-main-area-keyboard` (simulated) now passes after correcting its expected
area to include docked panels and exclude the floating menu, enabling actual
portrait/landscape simulation, and handling wrapped terminal output. See the
event-driven panel and keyboard results below. No physical-device run yet.

### Copy/Paste and navigation keys, strip scrolling, Shift+drag selection (UI-01, IN-05)

The default strip is now Copy, Paste, Esc, Tab, Ctrl, Alt, Shift, the arrows,
Home, End, PgUp, PgDn. An overflowing strip opens at its left end and scrolls
under a sideways finger drag handled by `TouchKeyBar` itself (no scroll bar);
the drag cancels the pending press of the key it started on. With Shift armed
or locked, `MobilePointer` routes a one-finger terminal drag as a pointer drag,
so the existing pointer chord attaches Shift and the terminal selects locally.
Passing, headless on macOS: `client-config` touch tests (3),
`touch_keybar_repeat_smoke.gd` (39, including the narrow-strip scroll, no tap
or latch from a drag, one tap after scrolling, and the four navigation keys),
the unit suite (663, with new `touch_config` and `mobile_pointer` cases),
`touch_scroll_smoke.gd` and `workspace_pointer_smoke.gd` (15).
`touch_controls_visual_smoke.gd` now shows its strips (they were hidden before
the capture) and adds a phone-width strip scrolled to its end; the capture was
inspected by eye only. Not run: any Android or iOS device, the strip on a
folded and unfolded foldable, and Shift+drag selection plus Copy against a real
mouse-reporting application. An arrow key still sends once when a strip scroll
starts on it, because arrows act on touch down.

Follow-up: the strip is a clipped row that `TouchKeyBar` places itself, not a
`ScrollContainer`, so it can also slide right past its resting place until its
first key is at mid-screen (one-handed reach on an unfolded foldable).
`touch_keybar_repeat_smoke.gd` now has 44 checks (both limits on a narrow and a
wide strip, taps where the strip was slid to); the unit suite still passes
(663) and the visual smoke adds a slid strip, inspected by eye. No device run.
A flick now glides on the shared `TouchScrollMotion` momentum:
`touch_keybar_repeat_smoke.gd` has 51 checks (glide continues and slows, a
touch brakes it without sending the arrow under the finger, a hard flick stops
at the end), passing three runs in a row headless; the feel on a device is
not verified.

## Link menu for file links and under mouse reporting

A right-click on an OSC 8 `file://` link already opened the link menu in a plain
shell. Inside mouse-reporting apps (agent TUIs, editors) the right-click went to
the app instead, so no menu. The terminal now handles a right-click on a link
itself, with or without Shift; off-link right-clicks still reach the app, and
explicit right-button bindings still win. The app never sees a half click.
`workspace_hyperlink_menu_smoke.gd` (graphical replay, real server) passes with new
file-link checks: menu opens, Copy Link Address copies the `file://` URI, and the
menu opens under mouse reporting. `terminal_hyperlink_smoke.gd` passes 21 checks
after its old Shift-only expectation was updated; hyperlink unit tests pass (6).

## Status line prefix keycap at every width; switch icons with labels

The prefix switch is now the compact keycap at every width (its tooltip still
reads "Prefix <key>"), and the wide layout's switches show their icons, colored
when on, beside the labels instead of a dot. Headless `status_line_smoke.gd`
passes, asserting the keycap with no "Prefix" label when wide and the tooltip.
Not run: a physical Android device or an installed build.

## Status line prefix switch and touch zoomed-out close

The status line gained a prefix switch: labelled with the configured prefix key,
lit while the prefix is armed, a tap runs the new `TogglePrefix` action (also a
bindable registry action). The mod reads `prefix()` and the host publishes it on
every prefix arm/cancel. Headless `status_line_smoke.gd` passes 25 checks,
including arming and cancelling from the switch. `agents_dialog_smoke.gd`,
`sessions_dialog_smoke.gd` and `list_docking_smoke.gd` still pass; client-config
binding tests pass with the new action. "Prefix" has all 11 translations.

With Android controls a compact (zoomed-out) pane header no longer shows its ×;
narrow headers at normal zoom and desktop compact headers keep it. `pane_header`
unit tests (8) and `pane_header_smoke.gd` (13) pass. No device run yet for either.

## Pane-title status and automatic session selection

Headless validation passed: 7 pane-header tests, 18 remote-manager tests and the
server-browser smoke. Rust validation passed: 20 remote-auth tests, 4 saved-connection
tests and `cargo check -p graffitty`. Running/busy pane-title spinners are removed;
waiting indicators and other agent badges remain. Blank connection sessions remain
blank through editor, persistence and authentication, allowing server-owned automatic
selection/naming instead of inventing `main`. Explicit names remain supported.
No installation or physical-device acceptance was performed for this change.

## Android last-connection restoration (UI-12)

Passed headlessly: 17 `remote_manager` unit tests, 5 `remote_view_state` unit
tests, and `server_browser_smoke.gd`. Coverage includes persisted selection and
clear, normal authentication/session restoration, missing credentials, removed
and transient entries, offline workspace retention, explicit manager cancellation,
and disconnect. These are fixture/unit checks, not real Android background/resume,
VPN recovery or process-death E2E. Physical phone/foldable acceptance and production
installation remain pending.

## Dense lists and invisible stack dividers (UI-08 / UI-09)

Headless `agents_dialog_smoke.gd`, `sessions_dialog_smoke.gd` (desktop and
`--android-controls`), and `list_docking_smoke.gd` pass. They cover tighter
spacing, mobile footer suppression, stable five-row-capacity thresholds, and
invisible full-gap stack targets with zero/8/24-pixel gaps. The Android docking
smoke passes corner/edge resize and stack-divider touch checks, but still fails
the embedded-title dock and undock checks headlessly; it is not an overall pass.
No physical-device run, visual acceptance or production installation was done.
This supersedes the older always-visible compact Add server and painted horizontal
separator requirements below; historical results describe their tested builds.

## Mods, panel windows and band rows (UI-09)

Headless `agents_dialog_smoke.gd`, `sessions_dialog_smoke.gd`,
`status_line_smoke.gd`, `status_strip_events_smoke.gd` and
`agent_status_badge_smoke.gd` (the per-pane `pane-strip` mod: published samples
and agent events re-render it synchronously, hover shows the history tooltip), `pane_status_drag_smoke.gd` (desktop and `-- --android`),
`pane_status_band_docking_smoke.gd` (top and `-- --bottom`),
`status_line_band_touch_smoke.gd` (a tap on a compact bottom band's switch
presses it; its label still drags the band) and
`list_touch_scroll_smoke.gd` drive the JavaScript mods through the engine's hit
regions and text runs: sections, captions, folds, pins, session switching, the
status line's adaptive zoom, tilt and pane zoom switches, compact rails/rows, side-by-side band cells, a second band
row with its own height, persistence and touch scrolling. `cargo test -p
graffitty-mods` covers layout, tracked reads, hover styles, scrolling, timers and
storage. These are headless checks, not physical-device or visual acceptance.

## Dock preview presentation ownership (UI-09)

Headless checks pass for `tests/list_docking_smoke.gd` and
`tests/pane_status_band_docking_smoke.gd` (top and `-- --bottom`). They cover
live compact/expanded preview transitions, drag-frame updates, deferred size
updates, exact destination bounds, and cancellation. Shared Agents/Sessions list
fixtures exercise narrow/wide rails on both sides; Resource Monitor exercises
32-pixel horizontal rows and expanded readouts. `sessions_dialog_smoke.gd`,
`agents_dialog_smoke.gd`, and `pane_status_drag_smoke.gd` also pass.
These are headless geometry/lifecycle checks, not physical-device dragging or
native OS title-drag acceptance. Device visual confirmation remains pending.

## Fold-size profiles (UI-10) and connection icon (UI-11)

The current four-profile change passes `tests/run.gd -- floating_profiles`: two unit
cases covering independent cover/inner × portrait/landscape keys, saved anchors,
default-layout seeding, controller recreation, ten four-profile cycles, keyboard
independence, and drag cancellation on rotation/folding. This supersedes the prior
rotation-shared profile checks. Both Graffitty and Artemis signed release APK builds
pass; Artemis's targeted profile and keyboard-inset tests pass. These use injected
display sizes, not physical folding; physical four-layout acceptance remains pending.

The companion Artemis change passes 68 UI tests and its signed release build.
Its tests also cover the slow-connection icon visibility/animation lifecycle.
Neither unit result establishes actual radio-quality transitions or physical folding.
No network impairment was introduced into the user's working session.

## Saved-server order (UI-08)

2026-11-13: workspace-manager cards show only server identity, address and
connection status. Their duplicate identity tooltips and session-number row are
removed from the shared desktop/Android/iOS UI; the actions hint and accessible
server details remain. Mouse and touch-profile `server_reorder_smoke.gd` runs
pass headlessly, including lift, movement, landing, persistence, cancellation,
and no card tooltip. The stale `workspace` field was removed from that fixture's
saved-server records to use the current server-only schema.

The server-browser smoke, 20 remote-manager unit tests, 4 server-card unit tests,
and `test_remote_resume.py` with the current release server pass on macOS. The
resume fixture verifies the second tab, focused view, pan/zoom and retained PTY
through chooser return, reconnect and disk restore. Three terminal-theme tests
pass. These are desktop
headless and injected-input results, not physical Android/iOS acceptance.

Background correction: terminal color remains gray (`#282c34`) on every
platform, with its configured pane opacity. Blue-gray (`#3b4452`) belongs only
to the surrounding space in both Flat renderers when native window transparency
is unavailable. Android opens Flat 2D. The rendering-defaults smoke checks the world color
separately from the terminal theme and opacity, including mobile project
overrides and an explicit terminal color. Hardware validation is recorded
separately from these configuration checks.

The corrected rendering defaults pass with headless (blue-gray Flat space)
and native macOS Metal (gray space), while both retain gray terminal colors and
configured pane alpha. Three terminal-theme and three Flat settings unit tests
pass. All 26 world-compositor pixel checks pass on Metal, including transparent,
partial, and opaque fills and wallpaper alpha. These do not establish an Android
physical-touch E2E pass.

The signed Android APK (`bce0e1d5d9a6ca93c84caf39d5a6b2423503c0edc12bd6ddfebda6ecbd6b3b11`)
was installed in place on the Android 17 foldable. Its running Flat 2D view
shows the blue-gray world gutter separately from the gray terminal pane; a
device capture confirms distinct colors after compositing. Startup has no
script errors, and the application identity and data directories are retained.

The shared order uses the saved-connections array. Focused validation passed:
`cargo test -p graffitty-transport --lib saved_connection` (3 tests),
`tests/run.gd -- sessions` (7 tests), `tests/sessions_dialog_smoke.gd`, and
`tests/server_reorder_smoke.gd`.

2026-11-12: workspace-manager cards no longer use GUI drag and drop. On a
foldable, hold-and-drag did nothing: the touch scroll page raises a hover shield
after every press, which hid the cards as drop targets. The card now follows the
pointer itself. `tests/server_reorder_smoke.gd` passes headless in both mouse
mode and `-- --touch-controls`, pushing pointer events through the real server
list page (shield included): lift, follow, gap, landing, Rust persistence,
grouped sessions, edge auto-scroll, Escape, click-still-opens, and a swipe that
does not lift. These are injected events, **not** a physical-device pass; the
swipe-scrolls assertion only runs where the platform reports a touchscreen.
UI-08 physical touch checks remain pending on phone and foldable. The build
was installed on a foldable, but no reorder gesture was performed there.

## Compact touch menus (UI-05)

Unchecked touch-menu options now use the shared outlined checkbox/radio icons,
including disabled states. A separate indicator preserves the command icon and
label position when toggled. The expanded `touch_menu_smoke.gd -- --touch-controls`
passes 34 checks with Metal at 1.5× scale, with the rendered indicators inspected.
The updated `android-touch-menus` passes 42 checks in desktop simulation, including
unchecked options in the real View menu. The two shared accent unit tests and the
changed scripts' parser checks also pass.

On an SM-F966N running Android 17, the updated scenario completed all 42 injected
touch checks without runtime errors. Its recording transfer exceeded the runner's
30-second timeout; recording/log collection and disposable-package cleanup were
completed separately. The recording exposed a stale native launch cover, so that
run is not a visual menu acceptance pass. A build made during Java package renaming
had retained the old Application class in its cached template. Template reuse now
checks that class, and Java/Dex compilation clears obsolete outputs. After a clean
signed rebuild, the installed APK hash, manifest and classes matched; the production
chooser opened normally, and checked/unchecked outlines in the server editor were
visually verified on the device. The editor was closed without saving changes.

`android-touch-menus` uses the existing runtime harness and a real server. The
final implementation passed desktop simulation and a physical SM-F966N APK run:
37 checks, no failures or runtime errors. It covers bounded menu size, touch-row
scrolling to the final command, cleared highlights, no activation on drag release,
opener toggling, shared Back dismissal, submenu navigation and preserved terminal
sessions. The disposable package was removed; production app data was untouched.
Test APK SHA-256:
`1c8ebf274acdbeac9180ac47d87641cc34d036aec869b60c659125e8aeaf478a`.

`tests/touch_menu_smoke.gd -- --android-controls` also passed 17 assertions,
covering 1.5× scaling, repeated unchanged layout/inset updates during scrolling,
disabled items, cancellation, extra fingers, exactly-once command selection,
keyboard navigation, keyboard-safe bounds and canceled deferred opening. Adjacent
validation passed: 14 remote-manager tests, 2 popup-chrome tests, 3 hyperlink-menu
tests, 58 Chromium-filter tests and the desktop mobile-menu smoke.

Retained failed evidence: an initial device attempt was interrupted during APK
transfer. A subsequent device run passed, but the final resize-cancellation change
then failed scrolling: unchanged inset/layout notifications canceled the gesture.
Cancellation now requires changed geometry, with a regression assertion; the
final simulated and device runs above passed. These are automated injected touches
on hardware, not human-confirmed smoothness, real IME/rotation/folding acceptance,
or a physical Android Back gesture. Production installation is not part of this
validation. Private artifacts remain outside the repository.

## Existing Graffitty E2E entry points

Use the existing shared Android-runtime harness, not a second runner in this directory.
The desktop simulated profile still uses the production client, a real server, and
real PTY/Chromium paths; it is **not** evidence from a physical Android keyboard.

With `EVIDENCE_DIR` set locally to a fresh output directory:

```sh
uv run --with websocket-client python tests/android/test_android_runtime.py \
  --simulated android-mouse-reporting --output "$EVIDENCE_DIR/mouse"
uv run --with websocket-client python tests/android/test_android_runtime.py \
  --simulated android-chromium-touch --output "$EVIDENCE_DIR/chromium"
```

Read `tests/android/test_android_runtime.py --help` for device-backed execution rather than
assuming simulated options exercise an APK. Use a fresh output directory for each run.

Test implementation: `frontends/godot/project/tests/client_scenarios/workspace.gd`.
The related shared specifications live in
`tests/llm-e2e/suites/shared/android-runtime/`.

At the time this checklist was consolidated, both above scenarios passed:

- Real PTY: one-shot Ctrl on down/drag/up, locked Alt across repeated clicks, releasing
  the lock, and no leftover pointer contact/button state.
- Chromium: Ctrl/Alt/Shift/Cmd flags on both DOM click edges and one-shot consumption.

This does **not** establish native Cmd+C/Cmd+W routing, every physical modifier
combination, all scroll chords, real Android IME integration, or lag behavior.
An earlier Chromium run timed out; retain failed-run evidence when investigating
flakiness rather than hiding it behind a subsequent passing run.

## Live dictation transport (UI-06)

- `cargo test -p graffitty-dictation-audio --lib`: Opus streaming, exact duration,
  codec delay/tail, compression, malformed batches and capture drain unit tests.
- `cargo test -p graffitty-server dictation:: --lib`: RPC format/order/ownership,
  decoded duration and final-tail checks, plus provider adapter fixtures.
- `python tests/android/dictation_e2e.py`: production Godot/server transport and terminal/
  Chromium insertion with synthetic microphone capture and a local provider.
- `tests/android/test_android_dictation.py`: isolated Android capture/drain and codec test;
  not provider or complete dictation UI E2E coverage.

Local Opus implementation validation: 11 dictation-audio tests, 22 server
dictation tests, and 9 Godot dictation tests passed; the CLI and Godot extension
builds succeeded. The Godot filter command is:
`godot --headless --path frontends/godot/project --script tests/run.gd -- dictation`.
The attempted `tests/android/dictation_e2e.py` run was blocked before microphone testing:
the session server reported `the terminal holder did not start within 5 s`.
This is not an E2E pass. Physical-device acceptance for the live Opus transport
is not yet recorded.

## Agent list and sound — Android device regression

`android-agent-attention` is an automated case in the same runtime harness:

```sh
uv run --with websocket-client python tests/android/test_android_runtime.py \
  --serial "$ANDROID_SERIAL" --no-record android-agent-attention \
  --output "$EVIDENCE_DIR/agent-attention"
```

2026-11-05: passed on a physical Samsung SM-G780F (Galaxy S20 FE), Android 13,
using disposable app/server fixtures. Build: `ac33a73` + working-tree changes;
test APK SHA-256 `42193f3335282fc0848a6a02ddeac57ff5d628fef634584e16c4aca800b48ca4`.
Real CLI registration and server status transitions reached the production list.
An automated touchscreen event selected its row from another tab and returned to
the correct pane. Waiting produced one native AAudio playback; Android logs show
output closing afterward. Duplicate refreshes and client mute produced no extra
playback. An independent Android output capture contains the droplet (peak
−32.6 dBFS at test volume). Media volume was temporarily raised and restored.

A subsequent extended device run also passed the OSC-only path: a shell process
reported `app=pi` working/blocked through OSC 7501 without agent hooks. Its row
appeared and played attention audio, while the graph provider remained `shell`.
Extended test APK SHA-256:
`592d83880ad220b53143ae9271235c116eb97746759045649fe884f5c5ef87af`.
The extended run's recording did not finalize; two attempts to repeat its audio
capture were blocked before the Android scenario by fixture-server topology
subscription timeouts. Those attempts are not passes. The digital-output evidence
above covers the same native playback implementation in the earlier hook-based run.

Limits: fixture agent, automated touch injection, and captured digital output—not
human-confirmed audibility or general physical-touch/IME acceptance. The user's
own server connection was not tested; OSC-only reporting was exercised using a
fixture and is now covered. A separate
attempt to duplicate speaker playback into a recording was rejected by Android's
audio policy; ordinary output capture succeeded. An intermediate build failed on
an unrelated dictation script/native mismatch; rebuilding matching sources passed.
Private device metadata, logs and recordings remain outside the repo. The harness
removed its disposable package; no production app data was cleared.

### UI-07 follow-up: non-modal Agents and bounded command line

The window/layout changes after the APK hashes above passed 17 command-line unit
tests, `command_line_layout_smoke.gd -- --android-controls` at 320×480 with
keyboard insets, and `agents_dialog_smoke.gd`. The latter also passed with
`--touch-chrome` in a real desktop window: injected touch moved/resized the embedded
window; row selection/focus loss left it open; three synthetic keyboard-inset
cycles restored its geometry. This is not physical Android input/IME evidence.
The expanded `android-agent-attention` scenario subsequently passed on a physical
SM-G780F / Android 13 with automated touch injection. It entered through the real
command line, checked embedded title drag and corner resize, selected an agent,
and confirmed that the window stayed open. An initial attempt failed because a
deferred hover callback accessed a detached row after selection; the callback now
checks tree membership before accessing its viewport. That attempt's recording
was silent and is not a sound pass.

The successful test APK SHA-256 is
`95a8f2956e84a77a2950e1a0856d344ebc399965f8f6c46a59445a3330a25c7a`.
A finalized 89.69-second Android internal-output capture contains exactly two
active sound bursts. Matching the energetic part of the bundled droplet against
the capture (mono 16 kHz, normalized waveform cross-correlation, silence excluded)
found alerts at 41.8035 s and 50.5715 s, with correlations 0.75579 and 0.75539.
Peak output was −35.90 dBFS. The two alerts correspond to provider-hook and
OSC-only attention transitions. Duplicate snapshots and the muted transition
produced no additional audio. Logs confirm both native output streams closed.
Recording SHA-256:
`d1d052df5c30a9e240196e3ddd6f82adf5bb7f5b3535fe4ff9d98d371ab681fd`.
Media volume was restored and the disposable package removed. Private recordings,
waveform analysis and device metadata remain outside Git. This confirms digital
output, not microphone-recorded speaker audibility; real IME/rotation acceptance
and the user's production connection remain outside this fixture's coverage.

A further SM-G780F run passed the styled-window/visible-grip version, explicitly
asserting **both** width and height increased during a touch drag, and exercising
the footer's Test sound button. Test APK SHA-256:
`562b7bf3afd70cd9ed9a65fb3aa7bf10a205b86274bfb043fac71f444d6d7047`.
The 89.99-second internal-output recording contains three matching droplets at
40.8222, 49.7395 and 51.5955 seconds (normalized correlations 0.80310, 0.75519,
0.75502; peak −35.04 dBFS): two status alerts plus the explicit sound test.
Mute and duplicate-event assertions passed, and all three native streams closed.
The prior audibility/IME/production-connection limitations still apply.

### S20 speaker-to-microphone confirmation

A subsequent SM-G780F / Android 13 run recorded the phone's own **UNPROCESSED
microphone**, not REMOTE_SUBMIX or playback capture. Android confirmed an active,
unsilenced microphone source with no input effects; media output was routed to
the built-in speaker at 7/15 volume. The scenario passed and all three droplets
were present in the microphone recording at 40.95, 49.93 and 51.79 seconds.
Gain-normalized 500–7500 Hz time-frequency matching against the bundled clip,
with pre-alert background removed, gave similarities 0.8293, 0.8328 and 0.8329.
Direct waveform correlations were lower (0.2747, 0.2667, 0.2685), as expected from
speaker/room/microphone filtering. These events align with the native playback
logs; muted/duplicate transitions produced no additional matching bursts.

This establishes physical speaker playback on this S20 at the tested volume,
not calibrated SPL, subjective loudness, or playback on a different device.
Volume and routing were unchanged; recording ended and the fixture app was
removed. Microphone audio is private and retained outside the repository.
Microphone recording SHA-256:
`1d52b9355d00bda9f336d9f7ba4416a15c68d7eff346904e1a1b58ba2b61273e`.
Test APK SHA-256:
`5c832be5b9220dd0e479e631b7613d6fca566d899a42d9a66068143b2c51f92a`.

A further microphone-recorded S20 run explicitly asserted that Godot's driver
remained Dummy and Graffitty's RECORD_AUDIO permission was **ungranted before and
after** all alerts and the Test sound action. The scenario passed without granting
app microphone permission. The independent shell microphone capture matched all
three droplets at 41.120, 50.124 and 51.944 seconds (spectral similarities 0.8332,
0.8355, 0.8353). The recorder is the ADB shell, not the app. This validates playback
without microphone permission, not the separate first-use dictation permission UI.
Test APK SHA-256:
`de827f9dc797ea289119015045e5c1fe02478144e582352c319208149f579fd4`.

### Android Back / workspace-menu dismissal

The Back-first dismissal regression passed the 14 `remote_manager` unit tests,
including nested popups, expanded floating chrome, subsequent Back navigation,
and direct transitions to the manager. Physical Android Back-button/gesture
verification has not yet been run for this change. See UI-05.

## Artemis automated checks

DI-05a tab-switch PiP regression: targeted `OfficeTabsPipTest`,
`OfficeTabsResumeTest`, and `PanZoomPictureInPictureTest` passed (5 tests).
These verify pre-launch suppression, launch-failure recovery, switch intent flags,
live-slot selection, and crop/restore math. Home-after-return and actual Android
PiP lifecycle behavior remain unverified on physical devices; no device E2E pass
or install is claimed.

In sibling `../artemis`, with its documented Android SDK and Java environment:

```sh
./gradlew :app:testNonRoot_gameDebugUnitTest \
  --tests '*StreamingInputConnectionTest' \
  --tests '*OfficeTextInputTest' \
  --tests '*OfficeModifiersTest' \
  --tests '*OfficeControlsTest' \
  --tests '*TouchNavigationHandlerTest' \
  --tests '*PanZoomPictureInPictureTest'
./gradlew :app:assembleNonRoot_gameDebug
```

Consult that checkout's `OFFICE.md` for build setup and any additional test suites.
These checks cover portions of IME text/key routing, modifier ownership, floating
geometry, gesture ownership, and PiP crop/restore math. They do not replace device
screenshots, host event observations, Android lifecycle transitions, or network tests.

## Windows host / Mac client live run

See [windows-desktop-validation.md](windows-desktop-validation.md) for the actual
stream/reconnect results and the Accessibility-blocked interaction checks. This
run does not establish Windows-to-Android coverage or a cache-hit speedup.

## Three-finger remote switching (GE-07)

The `android-multiserver` scenario now checks injected three-finger switching,
return and short-swipe cancellation. It also supports `--simulated`; unsupported
simulation selections are rejected rather than silently running zero cases.

Current validation: 15 Rust touch tests, 6 Rust agent tests, 2 Godot slide tests,
22 Godot touch tests, 14 remote-manager tests and the Agents dialog smoke passed.
The dialog smoke checks the remote label before elapsed time. Full two-server
simulation is **blocked**: its observer times out waiting for the initial topology,
before the swipe scenario runs. Full script scan also reports an unrelated stale
`_start_tile_resize` override in `workspace_pointer_smoke.gd`. No physical-device
swipe pass or animation smoothness claim is recorded; test on Android before
acceptance.

## Narrow pane header, context commands, and filetree titles

Pane-header mod migration: the seven `pane_header_test` checks, three Rust
`pane_header` rendering/action tests, `pane_header_smoke`, and
`pane_header_mod_smoke` pass on macOS. The latter forwards projected pointer
press/release through the real workspace and confirms that a compact × covered
by the enlarged title dispatches once without beginning a drag. Paint-only mod
views retain their input-ignore setting after entering the tree.
`pane_header_visual_smoke` compares the mod with native reference primitives:
title alpha matches exactly; toolbar alpha differs by 3.56% of reference ink
with the two SVG rasterizers. `scatter_status_quality_smoke` passes at 1×/2× DPI
with 3× enlargement, and `tab_list_touch_smoke` passes simulated touch routing.
These are desktop automated checks, not physical Android E2E evidence.

The close-only narrow/compact action group passes all seven `pane_header_test`
checks. `pane_context_menu_test` checks resolved hints for all ten actions,
filetree's own binding, duplicate-free reopening, and left/up dispatch to the
clicked pane. All ten localization checks pass. The three bundled-Neovim
`tests/server/test_filetree_config.py` checks pass, including `~`, `~/…`, percent escaping,
root navigation, and a sibling home-prefix that must not be abbreviated.
The wider `pane_` unit selection reported 70 passes and 10 failures in unrelated
camera/navigation fixtures (missing `workspace_chrome_bottom`); it is not a
full-suite pass. No physical-device acceptance pass is claimed for this follow-up.
The updated macOS package passed its package check and was installed/reopened;
checkpoint + holder restart retained all nine terminals and the session list.
The Android replacement installed with matching APK SHA-256 and no captured startup
script errors. Windows rebuilt and passed interactive Direct3D 12 startup validation;
installation awaits permission to close live sessions because its server cannot
restart while preserving running processes. Existing filetrees may need reopening
to load the new Neovim title hook.

## Sessions window (UI-08)

`tests/unit/sessions_test.gd` covers local-first grouping, remote deduplication,
retained offline groups without stale session rows, command registration and the
shared floating-window base. `tests/sessions_dialog_smoke.gd` covers keyboard-safe
geometry, injected two-axis resize, selection RPC and non-modal persistence.
These tests and `tests/agents_dialog_smoke.gd` pass. The `android-multiserver`
scenario additionally selects each existing remote through the Sessions dialog;
the attempted simulated run timed out in initial fixture authentication/topology
setup before UI execution. It is not a multi-server or physical-device pass.

### Sessions touch scrolling regression

The shared `TouchScrollGesture` now owns descendant event propagation for both
connection pages and floating lists. Sessions/Agents buttons no longer stop touch
events before the native ScrollContainer, including dynamically rebuilt rows.
The gesture helper stays with the content when docking changes its viewport;
hover capture and scrollbar controls retain their own input ownership.

`tests/list_touch_scroll_smoke.gd` passed headlessly with native GUI-routed touch
and emulated-mouse events: overflowing Sessions rows scroll in full/compact/full
layouts, dragging activates nothing, a fresh tap activates exactly once, and
release clears capture after content reparenting. Sessions, Agents and server
browser smokes also passed headlessly, as did all 14 remote-manager unit tests.
No foreground desktop windows were used. These are desktop headless input checks,
not a physical Android pass, human touch-feel result, or production installation.
Phone/foldable floating/docked scrolling remains device acceptance work.

### Flick momentum in touch menus and panel lists (GE-09)

Touch context menus (`TouchMenu`) and mod panel lists (`ModView`) followed the
finger and stopped dead on release. Both now use the shared scene-core
`ScrollMotion` that terminal scrolling uses.

Passed headlessly (2026-11-12): `tests/touch_menu_smoke.gd -- --touch-controls`
(a rested drag stops, a flick glides past the release point, a touch brakes the
glide without activating a row), `tests/list_touch_scroll_smoke.gd` (a flicked
Agents list glides, a touch brakes it, it rests, a later tap focuses once),
`resource_monitor_touch_smoke.gd` (hold-then-drag still reorders a column right
after a flick), `tab_list_touch_smoke.gd`, `embedded_mods_smoke.gd` and
`list_docking_smoke.gd`. These are desktop headless input checks. The feel on a
phone or foldable, and GE-08 with a gliding sidebar, are not yet device-tested.

### Returning to the Android app (reconnect on resume, startup cover)

A dropped connection used to wait the fixed 3 s retry delay even when the loss
was only noticed on returning to the app, and a fresh start showed the server
list until the last server had reconnected. The first reconnect after
`NOTIFICATION_APPLICATION_RESUMED` is now immediate (a second failure backs off
as before), and startup shows a "Connecting…" label over the server list while
it returns to the last workspace; the list stays visible and usable. A password
prompt or an offline or failed server removes the label. Startup also compiles
the workspace scripts on a worker while the server connects.

Passed headlessly (2026-11-13): `remote_connection_status_test.gd`
(`test_first_reconnect_after_resume_is_immediate`) and `remote_manager_test.gd`
(label shown during restore, gone in the workspace, absent when a password is
needed); all 661 unit tests pass. Not device-tested: how long a real resume
takes on a phone or foldable, and a cold start after the system killed the app.

### Sessions Add server visibility regression

The prior Sessions smoke checked button existence and its callback, missing that
`clip_text` removed its text-width minimum and the footer spacer consumed the
available width. The new readable-width assertion fails on that implementation.
The action now expands into the footer, and the shared window footer policy keeps
Sessions' `+` action visible in compact mode while suppressing spacer/grip.
`sessions_dialog_smoke.gd` passed in a real macOS window and headlessly, including
`--android-controls`: readable full-width action, repeated compact transitions,
manager callback, accessible label and visible bounds in a 44-point window at
1×/1.5×. The Agents and list-docking smokes also passed. These are layout and
callback checks, not physical Android touch E2E or an installed-build pass.

Follow-up verification: the Sessions smoke isolates XDG settings so existing saved
docks cannot contaminate geometry assertions. It passes headlessly and in a real
macOS window with actual IDs `0, 2, 3, 4`, opening/error/empty status transitions
that leave the footer rectangle unchanged, and 44-point widths at 1×/1.5×.
`server_browser_smoke.gd` passes for the shared desktop/Android card page at
840/390/320 widths, separate editor navigation, secret clearing on Back, and
preservation of the client connection on close. The startup checkbox wraps at
narrow widths. `list_docking_smoke.gd` verifies shared red close-hover styling;
all 10 localization checks pass. These are smoke checks, not a physical-device
E2E claim for this follow-up. Windows repeats the Sessions/browser smokes against
the prepared staging project (pass, no script errors), and the packaged graphical
startup passes on its interactive Direct3D 12 desktop. A raw-source Windows smoke
attempt lacked imported assets/native registrations; it is not counted as a pass.
The final working-tree builds were installed in place on macOS, Windows, and the
Android foldable. macOS used checkpoint + holder restart (seven terminals retained);
Windows changed only the UI executable (hash verified; original sessions retained).
Android's incremental transfer stalled; the full non-incremental replacement
succeeded and its installed APK SHA-256 matched the build. The device was locked
at launch verification, so this does not establish final interactive device E2E.

## Mobile invisible floating-window resizing (UI-09)

The shared mobile resize gesture replaces stock embedded all-edge resizing: no
painted border/grip, invisible left/right/bottom targets and bottom corners, with
the entire top excluded. `android_list_docking_smoke.gd` passes at 1×/1.5× with
side/corner axis checks, top exclusion, cancellation, docking and manager isolation;
the desktop docking smoke passes unchanged. One earlier injected run lost a title
drag; after explicitly settling reset geometry, both final scale runs passed.
The expanded `android-list-docking` APK scenario passed on the physical Android
foldable: 34 checks, zero failures/errors. It used injected touches in a disposable
app, a real session server, and no foreground macOS test window. This verifies
on-device behavior but not human-confirmed touch feel. The test app was removed;
production application data was untouched.

### Floating mobile window backdrop leak

On the Android foldable, floating panels showed a light wedge outside each rounded
bottom corner and a one-pixel light line down the right edge. Pixel sampling of a
device screenshot showed pure white at the corners and light grey along the edge:
the mobile path forced an opaque embedded window, whose square viewport painted its
clear colour behind the rounded body (white on Android, near-black on macOS).
Mobile embedded windows are transparent again, as desktop embedded ones always
were. Graphical `mobile_floating_chrome_smoke.gd` puts a magenta plane behind the
window and samples corners and edges: it fails against the previous code and passes
now. `android_list_docking_smoke.gd` passes twice at 1×. Installed on the Android
foldable: a screenshot of a floating Resource Monitor sampled at both bottom corners
has a maximum brightness of 34/255 (the workspace behind, under the shadow) where
the previous build had 255, and the right edge column is body colour then shadow
with no light line. Resize behaviour itself was unchanged and already per spec:
left, right and bottom edges plus bottom corners, never the top.

### Floating windows may hang off the screen

Floating embedded windows were clamped whole into the usable area on every
undock, drop and keyboard inset, so a phone could never push a panel aside.
`DockableWindow` now keeps only a 44-logical-pixel piece of the title inside the
usable area horizontally and the title row inside it vertically; the body may
leave the screen. Native desktop windows are unchanged. Evidence:
`android_list_docking_smoke.gd` 52/52 at 1× and 1.5× (the 1.5× run drops a
drag about one time in three, a known flake); `list_docking_smoke.gd`, both
Resource Monitor band smokes, Sessions and Agents smokes pass; the shared
`android-list-docking` scenario passes in `--simulated` mode (38 checks) with new
hang-off, title-strip and near-edge-start checks, after its openings were updated
for default docking and a `[] == []` match in `ListDockSpace.reflow` that applied
band weights to an empty column was fixed. Physical devices: on the SM-T733 tablet a
real title drag left the Agents window 411 px off the right edge with 232 px showing
and it docked back on a return drag; on the Fold the same drag reached the 56 px edge
zone and docked right instead, which is the intended edge gesture (the window was
left docked right there). The SM-G780F phone was not tested: its screen was showing
another app at the time.

## Dock retention on application resize (UI-09)

Removed automatic floating during layout reflow. Existing sidebars and horizontal
bands keep their ownership when the app shrinks; preferred widths and weights
remain unchanged so expanding restores the layout. New placement fit checks remain.
Headless `list_docking_smoke.gd` and `pane_status_band_docking_smoke.gd`
(top) pass, including a 220×180 shrink/expand regression and insufficient-height
band retention. No physical-device or foreground desktop validation was performed;
this follow-up is not installed yet. At sizes below control minimums, clipping
can still occur; this change does not claim arbitrary-size content usability.

## Desktop list docking (UI-09)

The current `tests/list_docking_smoke.gd` passes headlessly and in a real macOS
window. It checks native/resizable floating windows, live-content reparenting,
preview/commit rectangle equality, stack insertion/reordering, horizontal divider
proportions, width resizing, proportion retention, main-content-only insets,
undocking and close cleanup. The real-window run also exercises native maximize/
restore and checks original geometry. It invokes drag/layout handlers; it does
not establish native OS title-drag delivery or physical double-click behavior.
The Agents/Sessions embedded-dialog smokes pass. The localization coverage suite
passes all 10 tests, including app-wide scanned UI-string coverage; four Rust
localization tests also pass, with every affected string present in all 11 locales.

The live-preview follow-up passes headlessly and in a real macOS window. It checks
that preview owns the original controls, the source window/old dock is hidden,
status changes remain live, cancellation restores ownership, workspace navigation
restores a preview-hidden window, and closing during preview cleans up. The
Android touch-injection smoke also passes after this change. These are handler
and injected-input checks: native OS title dragging through hide/re-show and a
new physical-device run remain unverified for this follow-up. The title-anchor
and hairline-divider follow-up also passes the headless, real-window geometry,
and Android touch-injection smokes: detached title coordinates, transparent
resize hitboxes, one-pixel lines, and mobile 16-pixel touch targets. These checks
do not establish physical native-title drag behavior or a new phone-device pass.
The arrow-removal/narrow-strip follow-up passes the same docking/touch smokes and
Agents dialog smoke: 40-pixel minimum, 44-pixel collapsed width, no arrow controls,
and visible status glyphs with a scrolling compact list. The Android device
scenario now expands via edge resize instead of a rail button; that updated
scenario has not yet been rerun on a physical device. The preview-title follow-up
passes desktop docking smokes with the actual header moved into preview and
restored on cancel/drop (20-pixel header, 11-pixel text). The Android injected
smoke passes with 24-pixel embedded title chrome; one initial corner-resize check
missed, followed by two passing reruns. No physical-device pass is claimed.

The extended docking smoke also covers saved layout, folded rails, read-only
control previews with immediate neighbor layout, reopen restoration and the actual
hovered-divider cursor through viewport mouse injection. Tab-menu tests (8) and
localization coverage (10) pass. `android_list_docking_smoke.gd` passes touch
injection in a real macOS window: actual embedded corner resize, title docking,
stack/width dividers, undocking and manager/editor/workspace isolation.

`android-list-docking` in the existing Android runtime harness passed on physical
Samsung SM-G780F / Android 13 with automated touchscreen injection, using a
production manager connected to a real disposable server. It verified real window
corner resize, title docking and stacking, divider resizing, rail expansion,
manager isolation for docked and floating lists, return restoration and survival
of the original PTY. Test APK SHA-256:
`220033333a8c6339d108b0f79dba7ed7cab617efb44bcfa0dc09ed33a90a8aba`.
Both the corrected run and a final rerun passed. The first attempt failed on a
new fixture script's type-inference error; it is not
a pass. The harness removed its disposable package and left production app data
untouched. Evidence remains outside the repository. This is not human touch-feel,
physical keyboard/IME, foldable, rotation or restart-persistence device evidence.

Windows/Linux native dragging, Chromium, HiDPI and multiple main windows still
require acceptance testing. The docking button was removed; global-position
native docking remains unavailable on Wayland.
Native OS-window merging is not used: the same content is reparented. The Android
scenario now finds Agents under its Window owner and invokes the internal sound
diagnostic directly; the removed Test sound button is no longer an entry point.

### Desktop local and remote Sessions

`test_desktop_sessions.py` passes with the native macOS Metal renderer and three
owned disposable servers. It launches the normal desktop scene with two remote
connections, verifies **This Computer** is first, switches repeatedly in one
window, and checks retained connections, local pan/zoom and unchanged shell PIDs.
Explicit disconnect preserves every server process. Retiring the last local
presentation reveals a retained remote; the local group remains first and its
New Session action opens a real local session. The background guard passes.

`desktop_servers_e2e.py --gpu` passes manager and startup scenarios: shared server
editor, independent additional windows, returning locally while keeping the
remote connected, rejected passwords, recovery, forgetting/reconnecting without
resaving, and startup preference persistence. Session-group/unit checks (10),
remote-manager checks (18), authentication checks (8), and the Rust Sessions mod
reorder test pass. Earlier runs exposed a deferred-menu lifetime error and a
copied authentication-settings bug; both were fixed before the passing runs.
This is desktop macOS evidence, not Android/iOS or Windows/Linux E2E evidence.

### Dock coordinates and shared composition follow-up

The raw Window touch stream now converts once to logical viewport coordinates;
embedded-title tracking no longer mixes physical and UI pixels. `WorkspaceLayers`
owns named canvas ordering and shared desktop slide offsets. Sessions groups use
reported/saved OS icons, with a monitor for unknown platforms.

Validation: 3 `remote_swipe`, 14 `remote_manager`, and 8 `sessions`-filtered tests pass;
`list_docking_smoke.gd` and `sessions_dialog_smoke.gd` pass headlessly.
`android_list_docking_smoke.gd` passes in a real macOS window at 1× and with
`-- --scaled` (1.5×), including logical-pointer assertions during embedded chrome
capture. Initial injected runs failed corner/divider/inset or undock checks;
subsequent runs passed. The fixture now uses current viewport bounds for inset
and undock checks instead of assuming the OS preserved the requested window size.
These are desktop-injected checks, not human touch-feel or physical Android passes.
Phone/foldable smoothness, live multi-server sidebar animation and menu occlusion
still require device acceptance; no updated APK was installed for this follow-up.

### Panel touch isolation follow-up (UI-09)

Dock bodies, resize targets and live previews now opt out of workspace gesture
capture. Chrome contacts remain excluded through outside release, including when
a workspace finger is already down; hit testing includes canvas transforms.
Validation: 22 `touch_navigation` unit tests and the headless `list_docking_smoke.gd`
passed, including new dock-body/resize registration and second-contact isolation
checks. `android_list_docking_smoke.gd` also passed with injected touch in a real
macOS window. These are not physical Android or human touch-feel passes; updated
phone/foldable acceptance remains pending.

### Shared dockable Resource Monitor (UI-09)

`DockableWindow` now owns the common lifecycle and platform behavior;
`FloatingListWindow` specializes it for Agents/Sessions and `ResourceMonitorDialog`
provides selectable resource text. The existing `android-list-docking` device
scenario now also opens, touch-docks and selects/copies Resource Monitor and checks
manager isolation; that expanded device scenario has not yet been run.

Passed: 6 resource-monitor unit tests, 10 localization tests, Agents/Sessions
smokes, shared headless docking, and the shared Android touch-injection smoke at
1.5× in a real macOS window. `pane_status_drag_smoke.gd` passes both desktop
and `-- --android` modes headlessly and in real macOS windows; Android-mode title
docking uses the existing touch injector. These cover the same live readout through
reparenting, selection freeze/resume, 40-pixel layout, persistence and reopen.
They do not establish physical Android, Windows/Linux native title dragging or
physical IME behavior. No production installation was replaced.

Full script scan was blocked by the pre-existing `_start_tile_resize` override
signature in `workspace_pointer_smoke.gd`. The pane-header smoke passed its monitor
and world-switch assertions but failed overall on unrelated menu access to missing
`SessionBackend.connection`; it is not recorded as a pass.

### Dock-aware camera regression (UI-09 / GE-04)

`android-dock-camera` uses the existing Android-runtime harness and a disposable
real PTY. It checks left/right/double docks, two dock widths, closing the docks,
1.15×/2× typing zoom, both cursor corners, framebuffer cursor pixels, unchanged
saved navigation, and manual-zoom pinch anchoring. It asserts the requested zoom
and dock reservations are actually active. It calls production docking APIs;
`android-list-docking` remains the touch-drag routing test.

The simulated real-server E2E passes. Temporarily restoring the old full-window
camera bounds makes this same E2E fail cursor containment and framebuffer checks
behind left/right/double docks; restoring the fix passes again. Also passed:
73 scene-core Rust tests (67 unit, 6 integration), 9 Godot camera-follow tests,
and 32 touch-filtered tests. Native desktop and Android builds succeeded.

The first physical foldable run was **blocked by the lock screen**: the runtime
test activity stopped before the scenario started and the harness timed out.
After unlocking, `android-dock-camera` passed on physical Samsung SM-F966N,
Android 17, with 67 checks and no failures. Build: `ac33a73` + working-tree
changes; test APK SHA-256:
`868c69c2772183e664976c0c6e6112bf77b1e37d7c94cdc39107961410995ec8`.
This device-backed run confirmed the requested zoom, real PTY cursor positions,
rendered cursor pixels outside left/right/double docks, changed dock widths,
no-dock restoration, pinch anchors, and survival of the original fixture PTY.
The disposable test package was removed; production app data and live sessions
were untouched. Reproduce with:

```sh
uv run --with websocket-client python tests/android/test_android_runtime.py \
  --serial "$ANDROID_SERIAL" --no-record android-dock-camera \
  --output "$EVIDENCE_DIR/dock-camera"
```

Actual IME/rotation, the second physical geometry, and subjective motion quality
remain acceptance work. Private screenshots, logs and device details stay outside
Git. This follow-up was not installed over the production Android app.

### Workspace-region and transient zoom containment follow-up

`WorkspaceRegion` centralizes unobstructed layout/fit/projection/hit-test geometry;
`CameraViewport` owns camera-region bounds in Rust. Camera containment now applies
to the final rendered pan during easing, not just its destination and decorations.
The terminal's bottom-left IME anchor is converted to a cell center for following.

Passed: 8 Rust typing-camera tests, 2 Godot workspace-region tests (including every
intermediate zoom frame after cursor jumps and dock changes), 9 Godot camera-follow
tests, and the simulated real-server `android-dock-camera` scenario. The extended
scenario also checks both rendered cursor corners during all 30 zoom samples per
configuration, in addition to its existing framebuffer/settled/inverse-projection
checks. This is desktop simulation, not a new physical Android pass. No OS mouse
warping or production installation/session changes were used.

### Invisible sidebar resize edge

Removed the vertical resize-edge drawing entirely, preserving its desktop/mobile
hit target and cursor. Horizontal stacked-panel separators are unchanged.
Headless docking smoke passed. Desktop-injected Android docking passed on rerun;
the initial run missed the stack-divider drag and logical-pointer check. This is
not a new physical-device pass.

### Resource Monitor top/bottom docking (UI-09)

`pane_status_band_docking_smoke.gd` covers both edges (default top, `--bottom`),
in desktop and `--android` control modes. It covers monitor-only eligibility, live preview/cancel, placement
between sidebars below the tab bar, sidebar width/removal changes, mouse/touch
bottom-edge resizing, manager isolation, live samples, current-v1 persisted height,
close/reopen, undocking, moving back to a sidebar and insufficient-height fallback.
`workspace_region_test.gd` passes with top/bottom-only and combined side reservations,
including band resizing during camera easing. The extended simulated real-server
`android-dock-camera` scenario passed: every sampled zoom/resize frame keeps the
caret outside docks, framebuffer pixels confirm visibility, fixed-geometry follow
preserves manual navigation, and pinch preserves its inverse-projected anchor.
The first extended run mixed fixed-grid assertions with live PTY resizing; those
are now separate phases so neither check is discarded. These are desktop simulated
and injected-input tests, not physical-device E2E or visual-review evidence.

### Compact Resource Monitor band (UI-09)

Top/bottom bands shrink to 32 logical pixels; below 100 they use a one-row
status-strip layout (pane ID, CPU/RAM icons and values, agent badge) with the
body as drag target. `pane_status_band_docking_smoke.gd` passes for top,
`--bottom`, `--android` and `--android --bottom` headlessly. It checks the minimum height and reservation,
single-row geometry, live values, body drag start (desktop only) and restoration
of the full readout. `list_docking_smoke`, `pane_status_drag_smoke`,
`sessions_dialog_smoke` and `agents_dialog_smoke` pass. `android_list_docking_smoke`
fails two embedded-title touch checks both with and without this change's
side-dock-relevant edits. No visual review or physical-device run was performed.

## Adaptive typing zoom

2026-11-14: manual pan, wheel zoom and pinch interrupt the Rust adaptive
projection at its displayed correction. Content changes and the idle return
cannot restart it; fresh typing resumes it. Both Flat 2D and Flat 3D use the
same takeover path, including navigation starting from Main and an overview.

Passed on macOS: 3 Rust adaptive-projection tests, 19 adaptive-zoom and 9
camera-follow Godot unit tests, the native extension build, and
`uv run tests/godot/test_session_effects.py --case adaptive --evidence <fresh-directory>`.
The existing adaptive projection fixture now uses the private-server harness;
its former bare-host setup failed on the current session backend. The Metal run
checks displayed pan/zoom, immediate interruption without snapping, continued
manual navigation, stable frames through content/idle changes, and resumption
on fresh typing in both renderers, with no runtime warnings/errors and a clean
native background guard. This is desktop integration evidence, not physical
Android/iOS gesture acceptance. No installed app or user server was restarted.

Combined-projection follow-up: 11 Rust typing-camera tests pass, including 18
pane-scale/tilt/curvature combinations sampled across 289 surface points with
asymmetric viewport insets, idempotent correction, and a Flat 2D no-padding
regression. All 6 headless adaptive tests pass, including the production world's
final camera wrapper and 81 projected content points. Flat 2D script validation
passes. An initial native link failed on incremental-cache symbols; rebuilding
without incremental compilation succeeded (one attempt timed out first).
No foreground windows or device runs were used. Animated visual comfort, shader
pixels and hardware acceptance remain pending; the follow-up is not installed.

Zoom-out regression follow-up: the fit solver previously forced full-grid content
below the resting scale to make room for margins. A new headless regression failed
on that implementation, then passed after flooring the relative typing target at
1×. All 5 adaptive tests and 9 Rust typing-camera tests pass, including every
animation frame for dense content, asymmetric docks, manual magnification above
the automatic cap and zooming in from overview. The native extension builds.
This follow-up is not installed or physically visually verified.

Headless validation passed: 4 `adaptive_zoom` tests (shared world adapter, exclusive
mode selection, asymmetric viewport bounds, manual overview compensation,
animated content retargeting and idle return), 9 existing `camera_follow` tests,
6 `effect_rules` tests, 10 localization tests, and 12 real-libghostty
`visible_area_smoke.gd` checks. All 9 Rust `typing_camera` tests pass, including
the new absolute content-fit case. The native extension builds successfully.
No foreground desktop windows were opened. This is not physical-device E2E,
curved-sheet visual acceptance, or an installation. UI-09 adaptive checks remain
pending on hardware.

## Device validation still required after each relevant change

| Area | Required evidence |
| --- | --- |
| SwiftKey | Toolbar screenshot, unfinished composition/backspace result, normal + Programming Mode |
| Terminal keys | Actual host events/bytes for Enter, arrows, deletion, modifiers; no shortcut letter leak |
| Address-bar history | IN-06: suggestions during composition, tap and arrow selection, keyboard Enter, Back closes the list |
| Floating layout | Ten keyboard cycles on two geometries, coordinates before/after, drag reachability |
| Modifier bar | Real click/drag/scroll chord delivery, one-shot/lock/cancel, native shortcuts |
| Gestures | Scroll/pinch distinction, survivor pan/rejoin, free offsets, no letterbox clipping |
| Local cursor | Immediate movement under measured delay/stall, remote convergence, no double cursor |
| Displays | Actual host list/count, captured output and confirmed badge, switching timings |
| PiP | Before/inside/after images for current-region crop, no bars, coherent fullscreen restore |
| Quality | Fixed text fixture, codec/resolution/bitrate/zoom metadata, static-versus-motion comparison |
| Permissions | Correct installed identity, both grants, working capture and input after restart |

## Result format

For each scenario record:

- ID; app/host commit and installed build; platform/device class and OS; IME/version.
- Relevant settings and fixture; measured network conditions if applicable.
- Exact steps; expected and observed result; pass/fail/blocked/not-run.
- Evidence references outside the committed tree; redact private information.
- Scope limitations, unresolved regressions, and any state/network changes restored.

Pending feature goals such as adaptive static-detail improvement must remain labeled
unimplemented/unverified until a repeatable acceptance run supports them. Likewise,
new cursor drawing is not proof of latency tolerance, PiP geometry unit tests are not
an Android PiP lifecycle pass, and host repeat suppression is not a universal lag fix.

## Event-driven panel and keyboard updates (UI-04, UI-09)

Dock layout and floating backdrop geometry now follow layout/input notifications.
Mods subscribe to host, transport, resource and saved-connection changes. Android
insets arrive through native layout/inset/animation callbacks; dialogs share that
measurement. Keyboard dismissal uses a bounded one-shot retry timer, and tab/session
hover previews use a deadline and animation instead of reading the mouse each frame.

Passing on macOS: 19 Android-related unit tests; panel folding, list docking, mod
configuration, resource-monitor and Sessions smoke tests (including sample/topology
signals, saved-server edits and idle reflow/publication counts); responsive dialogs
across translations plus inset/rotation notifications. The private native-window
`window` and `merge` scenarios pass with Metal; the window test delivers captured
mouse motion/release events. Simulated `android-list-docking` passes.

Android Java sources and instrumentation fixtures compile. Windows caption C++
cross-compiles, and its Rust callback adapter type-checks for Windows. The native
Windows integration test is skipped on macOS; no physical Android IME or Windows
runtime pass is claimed.

The private native-window `placement` scenario also passes with Metal. Its final
screen-position assertions now wait for the camera animation to finish; effects
remain enabled and the original one-pixel tolerance is unchanged. All five transfer
cases preserve preview geometry, camera state and shell processes.

`android-main-area-keyboard` passes in desktop simulation after fixing its chrome
measurement, enabling portrait/landscape scaling with the correct aspect ratio,
and accepting markers wrapped across terminal rows. It covers competing client
claims, repeated keyboard transitions, terminal reflow and typing, cursor visibility,
saved navigation and a tall landscape keyboard. Measured navigation drift is at
most 0.6 px, and the original shell survives. This is not a physical Android pass.

## Session context menu and destructive pane actions (UI-05)

2026-11-12, working tree based on `addd172`, macOS 26.5.2, Godot 4.7.2 with
Metal: `test_session_context_menu.py` passes against disposable local and
authenticated remote servers. The runtime fixture opens the Sessions menu,
renames an inactive session, cancels kill, then confirms kill. The original
session's shell PID survives, the server remains usable, and a stale session ID
is rejected. Docked and narrow native-window menu bounds pass; a French render
was inspected for complete labels and red trash/text. Tests use Flat 2D with
effects off and the background-window guard; artifacts remain outside the repo.

Two Rust Sessions tests pass, including full/compact right-click routing when
local and remote groups share a session ID. Session/pane menu and localization
unit tests pass (12 total). `touch_menu_smoke.gd -- --touch-controls` passes with
Metal and injected touch events, covering scrolling, cancellation, keyboard-safe
bounds, nested menus, shortcuts and checkbox indicators after the shared popup
sizing change. This is desktop runtime and simulated-touch evidence, not a
physical Android/iOS or Windows/Linux pass. This task did not reinstall or
restart the production app.

## Captured pane input through the projected canvas (UI-05)

2026-11-12: the native-window `tab_window_e2e.py --scenario placement --gpu`
fixture now sends captured motion and release through the source window for
pane transfers as well as tabs. It passes on macOS with Metal across tab, pane,
collision and tiled-stash transfers (five cases), including a panned/zoomed
destination, preview/drop geometry, camera preservation and surviving shell PIDs.
The error/warning logger is empty: pane forwarding uses the world's projection
instead of asking a standalone SubViewport for a screen transform. This is
injected desktop input, not physical Android touch evidence. The installed app
and live server were not restarted.

## Pinch across a docked sidebar (GE-08)

2026-11-12, working tree based on `addd172`, macOS, Godot 4.7.2: every touch
contact now has one owner, decided in `scene-core` (`TouchArena`). A resting
finger on docked panel content joins a main-area finger as a workspace pinch, in
either order; the panel sees that contact canceled. `MobilePointer` only hit-tests
(`touch_yield` beside the existing `touch_chrome`) and delivers.

Passed: 20 `scene-core` touch tests (5 new arena tests), 22 Godot
`touch_navigation` unit tests, headless `list_docking_smoke.gd` (151, with the
join rule replacing "dock touch cannot join"), and the new simulated real-server
`android-sidebar-pinch` scenario (29 checks: both finger orders, anchoring, an
uninterrupted pane title drag, sidebar scroll and long rest kept by the sidebar,
exclusive resize edge and title). Simulated `android-list-docking`,
`android-pane-controls`, `android-tab-reorder` and `android-touch-menus` still
pass.

Failing before and after this change, verified by rebuilding without it:
`android-dock-camera` (dock reservation and typing-zoom checks),
`android-pane-resize` (left-edge resize at 1.1x), `floating_buttons_smoke.gd`
(floating title), `pane_status_band_docking_smoke.gd` (undock reservation), and
`android-direct-touch`, `android-gestures` and `touch_scroll_smoke.gd`, which
stop on a missing `Terminal.perform_action`.

This is desktop simulation with injected touch, not a physical Android pass.
GE-08 remains open on a phone and a foldable: right sidebar, bands, two-hand
landing delay and feel. No app was installed and no server restarted.


## Workspace manager start controls (UI-09)

2026-11-13: headless server-home layout/navigation smoke passed across its
French, German and English viewport cases; all 20 remote-manager unit tests
passed, including connect-only card activation and Connect all navigation intent.
The changed connection UI scripts passed Godot parser checks. Physical mobile
right-thumb hit targets and live multi-server desktop/mobile acceptance are pending.

Centered-logo follow-up: `server_home_smoke.gd` passes headlessly in desktop and
touch-control profiles across French, German and English at 820×910, 360×780,
780×360 and 360×280. It checks a centered logo, compact translated speech bubble,
the shared start action from either hit target, and disabling that action when
no server is connected. The same fixture passes with native Metal rendering in
a background macOS window; tablet and phone screenshots were visually reviewed.
These are layout and injected-input checks, not physical-device touch acceptance.

Larger-bubble follow-up: the bubble starts 24 logical pixels right of center,
uses 14-pixel text and a 48-pixel height, and expands its hit bounds by 8 pixels.
A signed UI-only replacement was installed with `--no-incremental -r` on an
Android 17 foldable; the installed APK hash matches the verified artifact.
The centered logo, larger translated bubble and eight saved servers were
visually checked. ADB-injected taps on both the bubble and logo opened the
workspace. Startup logs have no script-loading errors. This is installation,
visual and injected-input evidence, not human touch-feel acceptance. The new
server/session protocol is staged separately and was not part of this install.

## Shared SwiftKey terminal modifiers (IN-08)

2026-11-13: the disposable Android IME instrumentation fixture passes on an
Android tablet with the actual SwiftKey Polyglot debug connector bundled into
the fixture. It covers negotiation, modifier changes in both directions,
one-shot/locked replies, duplicate commands, 50 repeats, replacement-connection
release, late closure of an obsolete connection, and stale reply rejection.
Composition finishes before the shared chord without spending its modifier.
Existing native Shift navigation, Hangul composition and Ctrl+Enter checks pass.
The fixture is removed afterward; installed keyboard and Graffitty apps are not
replaced.

On macOS with Godot 4.7.2, four shared-modifier tests, four native-IME adapter
tests, six touch-configuration tests, script parser checks and the 51-assertion
arrow/scroll-strip smoke test pass. These cover complete modified gestures,
shifted punctuation, hidden accessory bars, preserved toolbar state across
reconnection, and stale peer/generation rejection. SwiftKey's 25 focused Kotlin
tests and lint pass; its rebuilt 22-APK set passes signing and privacy checks.

This is Android adapter instrumentation and desktop state/runtime evidence.
IN-08 remains open for physical SwiftKey touch/rendering, terminal-byte E2E,
phone/foldable geometry and real app transitions. No production server restarted.

A subsequent signed Android release build and installation on a foldable passed;
the installed APK hashes match the builds and the client launches without logged
startup errors. This remains installation evidence, not IN-08 touch/terminal E2E.
The first incremental install reported success, then the Android loader reported
status 9 and PackageManager removed Graffitty, losing its local data in both
profiles. A full `--no-incremental` install succeeded and work-profile availability
was restored; previous local settings could not be recovered. Use the full
transfer for future installations.

## Server connection and client view separation (UI-09)

2026-11-13: `tests/godot/test_remote_resume.py` passes with two real encrypted
WebSocket clients and a server-owned PTY. Authentication on an empty server
creates no session; explicit creation, loss/reconnect, preserved shell PID,
client tab/pane/pan/zoom restoration from disk, last-session closure with both
authenticated channels retained, and creation on the still-connected empty
server all pass. The permanent-password process fixture also passes across two
server launches and rejects an incorrect password. All 86 focused Godot remote
unit checks and 14 session-related unit checks pass. Rust authentication,
saved-server validation and client session-selection tests pass.

These are native headless and injected-input checks. The revised connection
lifecycle has not yet passed physical-device acceptance or deployment to the
remote Windows servers.

The same lifecycle fixture also verifies switching between two authenticated
empty desktop presentations without disconnecting either. Desktop and touch
live-session switching tests pass. The enlarged start bubble passes native
Metal rendering and injected logo/bubble clicks, with a 48-pixel bubble height
and larger type, across the documented translated phone/tablet viewports.

All six session-transfer cases pass with retained fixture evidence, including
remote transfers through an authenticated connection whose destination session
selection is still pending. No physical drag gesture is claimed by those tests.

The release Windows CLI/server also builds and passes an isolated encrypted
connection check using the native Godot client: server-only authentication,
missing remembered session without implicit PTY creation, explicit session
creation and catalog selection, closure acknowledgment, catalog removal, and
the same authenticated channel surviving last-session closure. The disposable
server was removed afterward. The existing Windows server checkpoint succeeded;
its session-preserving restart reports unsupported, so production replacement
remains pending authorization to end its live terminals.

## Keyboard callback boundary, side-by-side start bubble and scrollbar fades

2026-11-13: the foldable crash trace identified `BadParcelableException` while
reading SwiftKey Polyglot's private `ResultReceiver` subclass. The keyboard now
sends a framework receiver, and Graffitty rejects malformed callback parcels.
The existing native IME instrumentation passes on an Android 17 foldable with
the actual rebuilt keyboard connector. Its messages are parcelled with only the
framework class loader available, and an unavailable callback class is rejected
without changing modifier state. Five focused SwiftKey modifier unit tests pass.

`server_home_smoke.gd` passes headlessly and with background native Metal rendering
across its French/German/English phone/tablet viewports. The bubble is vertically
centered beside the centered logo, with a left-pointing tail; narrow screens use
a smaller logo and up to three prompt lines. Both hit targets remain active.

The Rust mod checks pass: 11 library, 11 renderer and 14 Resource Monitor tests.
They verify intermediate fade opacities, idle timing, interruption without an
opacity jump, stable list dimensions, thumb dragging through idle, and no further
redraw requests after settling. Fade timing is 120 ms in, 1.2 s idle, 280 ms out.
These automated layout/input checks do not establish human touch-feel acceptance.

The signed maintenance APK (SHA-256
`e6e11a8e7e7d1d864353aa7bbb5ec303e558c8b3cf306bc944ff79ec10b771a7`)
and rebuilt SwiftKey Polyglot were replaced in place on the Android 17 foldable.
All eight saved server records compare exactly with their pre-install values;
the application identity and original install time are unchanged. This APK
contains the keyboard, start-bubble and scrollbar fixes, while the separate
server-connection redesign remains undeployed.

ADB-driven checks on that installed build completed ten keyboard open/close
cycles with the same Graffitty process and no new crash or script errors. For
the mobile-start portion of UI-09, a French unfolded-screen capture shows the
bubble entirely to the right of the centered logo, and taps on each target
separately return to the connected workspace. For UI-09S, an on-device recording
of the overflowing Sessions panel shows intermediate opacity during appearance
and disappearance, the idle hold, and a fully hidden settled thumb. The first
recording at the list boundary was inconclusive; scrolling back through the
list supplied the fade evidence. These are injected-input device checks, not a
physical-touch E2E pass; human touch feel, other devices and the complete
wheel/trackpad/drag acceptance matrix remain unverified.


## Terminal image paste and `gft terminal put` (IN-09)

2026-11-14, working tree based on `70912e8`, macOS ARM64 host:

- Rust upload/transport tests: 20 passed, including fragmented local-socket
  requests, bounded chunks and stable destination receipts. Two server staging
  tests passed (exact bytes, publication once, scope/metadata validation,
  oversize/path rejection and partial expiry). Shared image decoding test
  passed for PNG, TIFF/BMP conversion and invalid input.
- `test_remote_controller.RemoteControllerTests.test_headless_ssh_attachment_publishes_and_revokes_alias`
  passed with real local CLI and authenticated encrypted remote transport. Its
  SSH process is a loopback forwarder. A file larger than one command packet
  reaches the owner byte-for-byte; `--paste` delivers exactly one quoted path
  inside bracketed-paste markers with no Enter. No production server is used.
- `android-bracketed-paste --simulated` passed all 11 scenario assertions:
  production manager connection, Unicode paste, large PNG SHA-256 at the owner,
  exact path paste, typing ordered after upload and original terminal survival.
  The overall harness is **not a pass**: Godot reports 11 leaked RefCounted
  objects at shutdown. `android-working-directory --simulated`, which never
  uses image upload, reports the same warning; a standalone 20-upload-object
  lifetime check exits without a leak warning. Retain the failing runner result.
- `tests/android/test_android_ime.py` passed on Samsung SM-G780F, Android 13, using its
  disposable instrumentation APK. Image content MIME advertisement, provider
  URI bytes, exactly one callback with the current generation, and rejection
  after closing the editor connection were asserted. This is adapter evidence,
  not keyboard touch or clipboard-to-agent E2E. The test APK was removed.
- macOS Godot development build, Android ARM64 extension check,
  iOS ARM64 extension check and Android Java compilation passed. The localized
  paste failure has all 11 language entries.

Physical desktop/mobile clipboard selection, external IME permission grants,
physical iOS paste consent and actual Codex/other-agent image recognition remain
unverified. No production app installation or server restart was performed.
Reuse the IN-09 entry points; do not convert the simulated assertions, native
adapter check or cross-compiles into a physical-device E2E claim.


## Status Line stays in a top/bottom dock (UI-09)

2026-11-14, working tree based on `70912e8`, macOS ARM64:
`status_line_smoke.gd` passed its assertions with desktop mouse injection and
with `--android` touch injection in a rendered 390-pixel-wide fixture. The
background-window guard passed for both runs. Both screenshots were inspected:
status content and feature buttons are visible in the resized strip, with no
title row or close button. Checks include actual inner-edge resizing beyond
100 pixels, double-click/invalid-drop retention, top/bottom movement with
height preserved, menu toggle persistence, showing content from a saved folded
placement and refusing a saved floating placement. The default remains 32 pixels.

Four Rust mod-configuration tests passed, including bar host/placement
validation. Godot parser checks, the shared list-docking smoke, the ordinary
panel-band docking smoke, and mod-configuration smoke also passed their
assertions. Mod fixture processes still report three RefCounted objects at
shutdown; this is recorded rather than treating the logs as warning-free.
No physical Android/iOS or installed-application run was performed. These are
source/build, rendered fixture and injected-input checks, not device E2E.

## E2E recovery and device regression checks (2026-11-17)

Working tree based on `70912e8`, macOS ARM64 host, release session owner;
Samsung SM-T733 / Android 14 with Gboard and Samsung SM-G780F / Android 13
with SwiftKey Polyglot. Tests use disposable servers and a separate test APK.
Device connections and private artifacts remain outside the repository. The
production desktop application and its session server were not restarted.

The 219-entry Godot catalog was exercised. Its first complete sweep recorded
101 PASS, 105 BLOCKED, 7 NOT_APPLICABLE and 6 FAIL. Separate reruns passed all
six failures: Codex daemon interaction, connected graph surfaces, graph
rerouting after disconnect, graph smoke, native Chromium input/menu handling,
and the single-tab window drag fixture. This does not turn missing manual,
provider or platform evidence into passes. Android entries blocked by the
catalog's desktop adapter are evaluated separately in the APK harness.

Additional passing rendered fixtures cover session-based world destinations,
interrupted world transitions, camera continuity, terminal render-target
reuse and rendering on demand. The isolated foreground idle-rendering run
recorded zero redraws in each sampled idle interval, including after navigation,
typing effects and closing animated Chromium. Tabs remain at their session's
world location. A three-server simulated run passed reconnect, restored images,
Unicode history, later grid updates, graph authority and Chromium continuity.

On the tablet, automated native checks passed Gboard settings/resume, message
selection/copy and the production entry flow. A subsequent lifecycle run passed
background output, held-input release, force-stop/relaunch and replacement APK
installation without clearing data. Chromium host restart, renderer reload and
stuck-page recovery also passed in the exported APK. On the phone, native
message selection/copy passed. These are ADB/UI Automator and injected-touch
checks on physical hardware, not human physical-touch or audio acceptance.

Six-pane title-stream tests passed with release owners and direct authenticated
network routes: tablet P95 48.117 ms and phone P95 44.237 ms. Steady hardware
browser video remained below its 30-presented-FPS acceptance gate on both
devices; the phone's later six-pane terminal-throughput run also exceeded its
50 ms P95 gate. Retain these failures. Recording was disabled for performance
runs, with screenshots, device logs and counters retained instead.

The phone's configured Korean SwiftKey layout cannot establish Gboard-only
entry/shortcut/settings procedures or the English-key-grid native-input
precondition. Retain those as blocked instead of changing the user's keyboard
or reporting a pass. Windows-only paths, quota-blocked provider interactions
and procedures without an automated adapter still require their own evidence.

The shared desktop touch harness also accepts `GRAFFITTY_E2E_VIEWPORT=360x723`
for narrow-layout diagnosis. This remains simulated evidence; an Android APK
run on the target device is required for device acceptance.

The recovery reruns passed 702 Godot unit tests and seven Android-runner Python
tests. Native tablet keyboard tests also verified exact PTY bytes for one-shot
and locked Ctrl/Alt/Shift, Escape and Tab. Tablet dock-camera checks wait for
the owner cursor update before measuring, and pass all dock configurations.
A phone-width desktop run passed dock-camera and pane-resize scenarios.
The camera appearance replay had an intermittent 0.0209 RGB-difference failure
against its 0.02 limit; a repeat passed without loosening the limit. Retain both
results when assessing stability.

A follow-up device pass on 2026-11-17 fixed the remaining functional Android
failures. Multi-server detach no longer raises "Viewport Texture must be set":
transition copies of a Chromium pane now snapshot the Android NV12 page view,
which detach frees (unit regression included). The server column floor is now
two, so a phone pane between two docks gets a fitting grid (8 columns in the
multi-server run) instead of a clipped 20-column one. A tiled divider in a
cramped phone area now moves, keeping each side at least a quarter of the span.
Pane-resize fixtures place the neighbor below the pane and navigate to the
grabbed edge, because floating panes keep their header reachable and a phone
cannot show the whole pane. Multi-server text checks ignore soft wraps.

With the rebuilt APK and release server, the phone passed dock-camera,
pane-resize, touch UI, usability (reconnect keeps the shell PID and its
variable) and multi-server; the tablet passed dock-camera, pane-resize and
multi-server. 705 Godot unit tests, 186 server tests and 128 workspace-core
tests pass. The pinch-cancellation step in pane-resize failed once on each
device: an incidental layout commit published the resize preview mid-drag, and
cancellation restored it only locally. Edge-resize previews are no longer
published and cancellation republishes the restored rectangle; afterwards
pane-resize passed three consecutive runs on each device.

Performance gates still fail. Hardware browser video: the phone presented
21.2 fps with its main loop at 22.9 fps (about 40 ms GPU per frame across
root composite, HDR world view and HDR workspace canvas); the tablet's main
loop ran at 41 fps but its route crossed the internet that day (ICMP RTT
110-190 ms, standing acknowledgement delay up to 1.4 s), so it received only
193 of 600 source frames. Phone six-pane terminal throughput measured P95
53.5 ms against the 50 ms gate; the frame profile accounts for 8.1 ms of a
56.7 ms average process time. The edited Windows font-metrics replay needs a
Windows server build and was not run.

`android-chromium-multi-stream` (new, 2026-11-17) opens three browsers drawing
full-frame noise on one connection; `tests/chromium/chromium_video_datagram_e2e.py` now
runs the same load through an emulated 10 Mbps and 4 Mbps tunnel. Fixed: a
frame lost beyond datagram repair froze its stream for good (the client now
acknowledges abandoned frames; the owner restarts a stream with no progress for
5 s); VideoToolbox frames dropped by rate control blocked low-delay encoding
forever, freezing every stream of that browser and the owner's shutdown
(`videotoolbox-dropped-frames.patch`); each viewer's bitrate tier now follows
loss and queueing, applied to the live encoder without a keyframe
(`videotoolbox-live-bitrate.patch`; NVENC natively; AMF/QSV/VA-API keep their
opening rate); any authenticated datagram feedback keeps the path alive. A
first attempt that reopened encoders per bitrate change and paced by a
loss-driven rate made the emulated tunnels collapse to 0 fps and was removed.

Passed: the emulated tunnels, three streams at 36-45 fps (10 Mbps) and about
23 fps (4 Mbps) with no keyframes, no frame lost beyond repair and no gap over
201 ms; unit tests for each fix. On devices over the day's Tailscale route the
case still fails its 20 fps floor: phone 13 fps per stream at about 270 kbps,
longest main-loop interval 75 ms, no fallback or restart; tablet runs varied
from 2 to 11 fps and its route blacked out for over 3 s three times. Per-stream
rate there is bounded by the four-frame window over 100-500 ms acknowledgement
delays. The 4 Mbps tunnel also showed uneven shares (one stream about 116 kbps,
the others about 430).

Later on 2026-11-17, pausing unreadable browser panes was reviewed. The owner
side was sound (no frames, no bitrate share, capture stops, keyframe on
resume). The client judged only projected height in physical pixels, so a
186-pixel-wide tiled sliver on a 3x phone streamed at the 1440 tier, and it
measured panes hidden within the active tab. It now pauses on the page's
smaller side in density-independent pixels and treats hidden panes as
off-screen (unit tests). A pane fully covered by another still streams.

Acknowledgements now carry how long the client held each frame
(`chromium_ack.held_ms`, optional, zero for clients that acknowledge on
receipt); the owner subtracts it, so a render loop's wait no longer reads as a
filling link (unit test). Rejected after measurement and removed: tolerating
delay up to the client's acknowledgement interval (overfilled the emulated
tunnel), acknowledging at decoder hand-off (broke the slow-decoder throttle),
a VideoToolbox data-rate cap (ignored: 234 KB delta frames under a 75 KB cap),
pacing by stream bitrate (keyframes outlived the receiver's 600 ms limit), and
progress-based frame abandonment (head-of-line stalls of 5-9 s).

Open: one frame larger than a link can carry within 600 ms. Full-page noise
at about 960x530 makes every frame 200-360 KB; with readable stacked panes
both devices fell to about 0.1 fps per stream over the day's Tailscale route
(abandon, keyframe request, abandon). The emulated tunnel reproduces it with a
25 fps client behind 50 ms of latency (`GRAFFITTY_E2E_PACED_TUNNEL=1`, opt-in,
failing). The default tunnel modes still pass (34 fps at 10 Mbps, 22 fps at
4 Mbps, measured on a heavily loaded host). The likely remedy is smaller
frames at the source: a lower resolution tier when the bitrate tier is low.

Final device pass that evening (rebuilt APK): phone pane-resize and
dock-camera passed; multi-server passed on the tablet and, after a visible
pane was allowed its first frame before size-pausing (the new rule had left a
small new browser blank), on the phone. Multi-stream still failed its 20 fps
floor without freezing: phone 12 fps and tablet 16 fps per stream, longest
main-loop interval 78 ms. The phone's single-stream case was not measured in
that pass: its APK export timed out on the loaded host.

Keyframe flush (2026-11-17, after Jump Desktop's documented behaviour): a
keyframe drops its pane's older queued and resend datagrams and starts a new
chain, the receiver gives up older incomplete frames when a chain starts, and
a client's keyframe request clears that stream's window. The phone-paced
tunnel mode, which froze streams for 2.5-9 s before, then passed twice (every
stream 20-30 fps, longest gap 320 ms) and is now part of the default
`tests/chromium/chromium_video_datagram_e2e.py`. `android-chromium-multi-stream` passed
for the first time on each device, once out of two runs: phone 17-18 presented
fps per stream (its floor follows the 26 fps main loop), tablet 22-23 fps. The
other tablet run reached 12-16 fps; the other phone run stayed near 0 fps with
megabit-sized frames and no fallback or stuck restart, cause not yet traced.

## Terminal rubber band (GE-10)

Not run on a device (2026-11-18): GE-10 has no physical-phone, tablet or
emulator pass yet. Supporting checks that passed on a Mac build only:
`cargo test -p graffitty-scene-core scroll::` (Chromium's pull, release and
bounce curves; terminals use the Apple curve on every platform), `cargo test -p graffitty-scene-core touch` (a drag
reports began, changed, momentum and one end, including when a brake, second
finger or cancel stops it), `tests/run.gd` (711), `touch_scroll_smoke.gd`,
`workspace_pointer_smoke.gd`, and the desktop replay
`mac-trackpad/rubber-band`, which also pulls a screen with no scrollback both
ways.

## Fling model and finger-exact terminal drags (GE-09, GE-10)

Not run on a device (2026-11-19). The shared fling (`scene-core::fling`) uses
Chromium's touch handling (LSQ2 release velocity, 50–8000 dips/s, 40/80 ms
stop rules, fling booster) and UIScrollView's deceleration. Supporting checks
that passed on a Mac build only: `cargo test -p graffitty-scene-core` (87:
glide distance about half a second of release speed, frame-rate independence,
LSQ2 catches an accelerating release, limits and pauses, boosting and its
resets, recognizer flicks), `tests/run.gd` touch filters (40),
`touch_scroll_smoke.gd` (80 px of finger travel scrolls 4 rows of 20 px; repeated
flicks build momentum), `touch_menu_smoke.gd -- --touch-controls` (39) and
`selectable_text_smoke.gd`.

## Lists, menus, panels and dialog text rubber band (GE-12)

Not run on a device (2026-11-19): GE-12 has no physical-phone, tablet, foldable
or Mac-trackpad pass yet. Supporting checks that passed on a Mac build only:
`cargo test -p graffitty-scene-core scroll::` (the shared pixel scroller pulls
past an edge, lets go when scrolled back, springs back, and a wheel never
stretches), `cargo test -p graffitty-mods` (mod lists pull and release, keep
requesting frames until rest, a wheel never stretches, a fitting list pulls
only under a gesture, momentum bounces; `pane_header` fails identically at the
prior HEAD), `tests/selectable_text_smoke.gd` (a 120 px finger drag scrolls
108 px past the 12 px slop, flicks glide and rest, rows are never pressed, a
pull at the top displaces the rows and springs back; trackpad pans move dialog
text by their travel and stretch it at the top), `tests/touch_menu_smoke.gd --
--touch-controls` (39), `touch_scroll_smoke.gd`, `connection_page_smoke.gd`,
`notifications_smoke.gd` and `tests/run.gd` (727).

On 2026-11-21, `cargo test -p graffitty-mods` passed the sideways wheel,
both-edge pull and release, pinned fling, nested axis ownership, scrollbar
and JavaScript offset tests. Headless Godot passed `tab_overflow_smoke.gd`
(phased pan on a tab close button), `chromium_tab_overflow_smoke.gd`,
`selectable_text_smoke.gd`, and `touch_keybar_repeat_smoke.gd -- --touch-controls`
(phased pan over a key plus finger drag and flick). In `mobile_menu_smoke.gd`,
all four sideways pan, drag and release checks passed. Its three existing
menu-open checks still failed. Physical trackpad and mobile gesture feel
still need device checks.

## Dialog text selection and copy (GE-13)

Not run on a device (2026-11-19). Supporting checks that passed:
`cargo test -p graffitty-terminal-core text_words` (Ghostty word runs,
configured boundaries, Unicode columns, trimmed lines, word-wise extension) and
`tests/selectable_text_smoke.gd` (double click takes `~/project/godot-ghostty`,
dragging extends and shrinks a word at a time, a triple click takes a trimmed
line and extends by lines). Clipboard copy and the Android native toolbar are
unverified.

## Slow tap on a terminal (GE-11)

Not run on a device (2026-11-18). Supporting check that passed:
`cargo test -p graffitty-scene-core touch` (a still contact lifted just before
the long press clicks once; one held into the long press does not).

