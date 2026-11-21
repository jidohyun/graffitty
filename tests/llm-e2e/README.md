# LLM end-to-end cases

The [native Windows supplement](suites/shared/windows/README.md) keeps separate
PowerShell 5.1 and 7 acceptance cases, ConPTY checks, and physical Korean IME,
150% DPI and native window review. It supplements the shared functional suites;
other platforms report these Windows-only cases as not applicable.

The suite lives in repository-root `tests/llm-e2e`. Runners pass the replay's
absolute script path to Godot; shared replay scripts use relative paths. There
is no source copy or compatibility symlink inside the Godot project.

Behavioral requirements live in `suites/shared/`; Godot replay implementations
and configuration fixtures live in `suites/godot/`. The
[shared suite contract](suites/shared/README.md) defines adapter bindings and
honest coverage gaps. Run `python3 tests/llm-e2e/shared_e2e.py --validate` for
schema/path validation or omit `--validate` to inspect required coverage.
Missing bindings remain BLOCKED. Shared Godot replay support lives in `replay/`.

The [mandatory media transport suite](suites/shared/media-transport/README.md) defines
strict requirements across all frontends: verified shared GPU chromium delivery
locally, decode-once Kitty images through SHM/IPC, and capability negotiation that
cannot mistake SSH forwarding for shared resources. These requirements survive
frontend replacements and refactors. Python diagnostics are supporting evidence;
they cannot replace the LLM cases or certify their visual/import/lifetime checks.

This collection uses paired TOML/Markdown test specifications. The flat-world cases
cover camera zoom continuity during tab switching, animation handoff alignment,
and one camera moving the world and every floating window together.
`camera-zoom-tab-switch` also renders every frame of zoomed, tilted and defocused
Scatter/Scatter flights. It checks initial capture pixels, the
following two frames, lens continuity, and the final live handoff, retaining PNG
sequences and lens telemetry for visual review.
Its Godot replay renders Push/Pull, Godot's tab transition, in both directions, including
the curved typing surface's depth, tint, and live-to-capture handoffs.
`flat-world/tab-transition` checks Push/Pull: whole panes on one shared clock,
both dolly directions, a camera landing at the same deadline on the destination’s
saved view in both Flat and Flat 2D, including interrupted switches.
`agent-graph/connected-surfaces` starts real Neovim and chromium processes and
drags the mixed component from each child and parent: direct chromium, filetree,
opened editor, preview chromium, and owner. It checks every connection endpoint,
preview wire, relative rectangle, process identity, reuse and cancellation.

`agent-graph/tab-boundary` checks server rejection of cross-tab connections and
pointer-driven group transfers, preview wires, pre-drag geometry, paused links,
new-tab drops, cancellation, and shell continuity. Its Godot replay is executable.
The standalone
server/smoke tests are supporting diagnostics, not substitutes for this case.

The tabs-and-panes cases cover dragging tabs and windows: reordering, detaching
into desktop windows, holding over a tab to open it, merging tabs, moving a
window into another tab or onto the tab bar, keeping headers reachable, and a
reordered tab keeping its session's place in a 3D world.
`single-tab-window-drag` checks that dragging a window's only tab moves the same
native window without detaching, while preserving merges into another window,
preview cancellation, and normal multi-tab detachment into new numbered server
sessions. Its Godot adapter checks native windows and live shells with background
rendering; physical drag review and explicit CLI reattachment remain coverage gaps.
They label terminals with OSC titles and compare `echo $$` before and after, so
a moved shell is provably the same process. The `bistro-world/pinch-zoom-tab-flight` case covers camera
motion in a 3D world, including session travel after a pinch zoom.
`bistro-world/night-lighting-tab-flight` checks all nine baked night destinations,
local fixture illumination, continuous session flights, interrupted flights, and a
return to saved pinch framing. It saves rendered views and camera telemetry;
lighting and motion still require LLM review of the continuous recording.
`tiling-cli` types real AeroSpace-style commands into the terminal and checks
layout, focus, grouping, view controls, scope, and shell continuity.
`main-area-tiling` covers nested i3-style splits, resizing and toggling tiling.
`title-double-click` covers click-only tiling preservation, animated Main View
for full-width/full-height panes, individual fit for smaller panes, exact restore,
and gesture interruption at compact, normal, and enlarged scales. `fit-to-pane`
checks the shared title/keyboard toggle (Command+Enter on macOS, Ctrl+Shift+Enter
elsewhere), including a 30% camera fallback when already fitted without history.
`per-tab-tiling` covers independent tab toggles and an explicit default that
affects only future tabs, preserving existing layouts and live shells.
`pane-font-size` checks pane-local font shortcuts, a persistent recent-size
preference for new panes/tabs/windows, focus changes that do not alter it, local
reset, and restoring individually saved sizes without changing the preference.
`shift-drag-selection` checks terminal selection over application mouse capture,
Unicode clipboard contents, modifier release order, custom bindings, pane routing,
and node forms. It is a visual/manual specification without a deterministic replay.
`per-tab-camera-view` covers remembered zoom and pan per tab, flights landing
at those views, interrupted switches, and a tab-local Main Area reset.
`pane-edge-resize` covers the expanded first tile, header icons, resizing from
the right pane’s left border, diagonal tiled/floating corners, and Escape rollback.
`stash-navigation` covers right-button dragging, pointer-anchored pinch,
close-up rendering and typing in stashes across Flat and Bistro.
`stash-outside-main-area` covers the main-area border, dragging panes outside it,
retrieving them, cancellation, and keeping their shells across Bistro and Flat. Its windowed replay checks that off-main pixels reach the final
rendered frame, in addition to checking layout membership.

Each TOML file identifies the goal, verification criterion, and ordered stages.
Its sibling Markdown file supplies instructions under matching stage headings.
Fixtures live beside the case so setup is reproducible without changing personal
settings or the application's default preset.

`sessions/last-session-shutdown` requires tmux-style local ownership: closing
the last pane removes its live session, and closing the last session stops a
private server automatically. It covers pane/tab controls, shell exit, explicit session
closure, detached survivors, and a clean subsequent launch. Process exit must
be observed before fixture cleanup; frontend adapters remain missing coverage.

The original visual suites are specifications, not an installed Artemis runner.
The reference runner is Electron/EMR-specific; `verify` names the required check,
such as `visual_continuity` for animation or `tab_order` and `pane_move` for drag
outcomes. Executable frontend adapters are declared in each shared TOML and run
through `tests/llm-e2e/shared_e2e.py --run`. Empty stage `tools` lists do not configure
an LLM provider; unimplemented adapters and outstanding physical-input or visual
review requirements remain explicit coverage gaps. The five real-agent graph
cases below have Python adapters in the shared catalog, so a complete shared
run includes them. Four invoke authenticated providers and consume model usage;
the free visual-test dashboard does not run those four cases.

To exercise a case manually or with an LLM controlling the application, follow
its Markdown steps (in `suites/shared/<suite>/`) from the repository root. Report PASS, FAIL, or BLOCKED with evidence. For animation cases,
record the continuous motion; an idle screenshot alone cannot establish that the
animation was smooth. Drag cases need screenshots taken mid-drag as well as after.

An unexpected error/message dialog is a test failure, even if the scenario's
other assertions pass or the dialog is dismissed immediately. Record its text
and source in the failure evidence. The shared replay and client harnesses
observe Graffitty message-panel presentations and retain failures after dismissal.
Tests intentionally exercising the messages panel must register the exact
fixture with `diagnostic_guard.allow(message, file, line)` before showing it.
This allows only that fixture; unrelated diagnostics and engine errors still fail.

## Replays

Android coverage is split into `android-simulated` (production Godot client on
Mac with touch input) and `android-runtime` (actual APK on an emulator/device).
See [Android E2E tests](ANDROID.md) for commands and the coverage boundary.

The cases are the truth. A case may also have a replay,
`suites/godot/<suite>/replays/<case>.gd`: a script that performs the same steps on the
real application and checks the same outcomes. Replays can fall behind their
cases, so they prove nothing on their own, but they are a quick way to repeat a
case and a starting point for the next run. An LLM running a case writes its
replay, or fixes the existing one, from what it did and what the case expects.

A replay extends `replay/replay.gd` and moves at a person's pace. The pointer,
presses, clicks, pinches and keys are drawn on screen. Each step is captioned
in the case's own words, and every check shows as it is made, so a recording
reads like a screen capture:

```gdscript
extends "../../../../replay/replay.gd"

func play() -> void:
	await say("Click the second tab and watch the flight")
	await click(on(tab_button(1)))
	check(host.world.active == 1, "The second wall is shown")
```

A replay feeds its pointer and keys straight into the application. A replay-only input
guard filters native mouse events, and button edges refresh the scripted hover,
so using the desktop mouse cannot steal a recorded click or release. It never
needs the desktop's keyboard focus. Logic tests use Godot's dummy-renderer
`--headless` mode. Visual tests and recordings use background GPU rendering on
macOS by default: a test-only AppKit guard suppresses window display and app
activation from startup, while an explicit render loop produces real pixels.
The runner checks native visibility/activation samples and fails if the guard
is missing or reports a visible or active test process. Each test keeps its
log and native reports in the printed temporary evidence directory.
The loaded guard removes its own injection from the process environment so
shell and Chromium helpers launch normally. Replays starting another Godot
process must use `Background.create_godot_process()` to guard that child too.

Background rendering requires macOS, clang with the macOS SDK, and a Godot
executable that permits DYLD injection with Metal support. There is no automatic
fallback to a visible window. Use `--headful` to opt in to visible tests on any
supported desktop, or `--headless` for logic-only tests without GPU requirements.
`--windows` remains accepted for compatibility; rendered tests are included by
default. The `render-on-demand` case checks native focus and idle frame counts,
so it is explicitly skipped unless `--headful` is selected. A named invocation
of that case without `--headful` reports the requirement.

Rendered replays use a fixed logical render size; explicit resize cases change
that logical size. Background mode exercises injected application input and
rendered pixels, not physical input or native focus behavior.

```sh
uv run tests/godot/test_dashboard.py test              # logic + background GPU replays
uv run tests/godot/test_dashboard.py test --headless   # only logic replays, several at once
uv run tests/godot/test_dashboard.py test --headful    # opt in to visible windows
uv run tests/godot/test_dashboard.py test zoomed-text-stays-sharp --headful
godot --headless --path frontends/godot/project --script "$PWD/tests/llm-e2e/suites/godot/bistro-world/replays/pinch-zoom-tab-flight.gd" -- --shell=/bin/sh
uv run tests/godot/test_dashboard.py record && uv run tests/godot/test_dashboard.py build
uv run tests/godot/test_dashboard.py record zoomed-text-stays-sharp --headful
```

`record` runs each replay at a person's pace (`--record`) under Movie Maker,
in the background by default. Use the dashboard runner to install the native
guard; launching a rendered GDScript directly with `godot` remains headful.
The native writer pipes frames directly to FFmpeg/SVT-AV1 and produces silent
AV1 MP4s (CRF 24, preset 8). FFprobe verifies the codec and nonempty video;
encoder failures fail the recording. FFmpeg must include `libsvtav1`.

`pane-add-controls` checks tiled split buttons versus a floating plus, nearby
creation, physics separation, and creation beside an outside stash.
`main-view-magnet` checks snapping during pinch/pan, continued movement through
the magnet, no delayed correction, and unchanged panes and shells.
`main-view-pane-close` checks creating a pane above and closing it without
leaving Main View, repeated typing zoom and return to idle, and closing during
typing zoom with multiple surviving panes in Flat and Flat 2D.

`tiling-drag-preview` checks the proposed split while the mouse is held, Escape
cancellation, exact preview-to-commit rectangles, stashing, and merges of a pane or a whole tab.

`docs/developers/internals/tests/` shows every case with its recorded replay, next to the fast
rules in `frontends/godot/project/tests/unit/`. First build the isolated Rust graph
fixture with `cargo build -p graffitty-workspace-core --example graph_fixture`,
then run (`godot --headless --path frontends/godot/project --script tests/run.gd`).

Each test-site card embeds the full rendered Markdown specification and its raw
source in an expandable **LLM suite specification** section, including cases
without a recorded replay. The page works offline without fetching Markdown.

`bistro-world/overview-pane-resources` checks 85% backdrop alpha in rendered
canvas pixels, compact PID/CPU/RAM captions for three panes, a real CPU workload
in an unfocused shell, and returning to full controls. Captions reuse the
existing samplers; they do not start a process scan on each animation frame.


## Real Codex / Claude graph suites

```sh
python3 tests/agents/test_agent_e2e.py --case all
python3 tests/agents/test_agent_e2e.py --case cross
python3 -m unittest discover -s tests/agents -p test_agent_e2e_runner.py
```

`--server-binary /path/to/frozen/gft` selects the owner/CLI;
`GRAFFITTY_TEST_SERVER` supplies it when the option is omitted. `--case all`
also runs the deterministic graph fixtures; allow `--case-timeout 1200` for
that complete graph group. The replay's own temporary
provider homes and panes are cleaned up without touching open coding sessions.

On Windows, pass `--godot C:/path/to/Godot.exe`. The live runner also accepts
the matching `_console.exe` wrapper and selects the engine directly so detached
provider processes cannot keep the wrapper alive. Native PowerShell is
the default shell (`pwsh.exe`, falling back to `powershell.exe`); `--shell`
overrides it for the live runner and `GRAFFITTY_TEST_SHELL` for the dashboard.
The replay shell fixtures use native PowerShell commands on Windows. Test
directories receive a current-user-only ACL before credentials are copied,
and timeout cleanup terminates only the test's process tree.

The runner uses installed **real interactive CLIs and real model responses**.
Its source node runs directly through the current Python graph SDK, with a Send
output and the normal lifecycle/heartbeat contract.
It does not use `tests/agents/codex_hooks_e2e.py`'s mock provider. Defaults are
`gpt-6-luna` with `model_reasoning_effort="low"` and pinned
`claude-haiku-4-5-20251001`. Models are explicit and overridable through
`--codex-model` / `--claude-model`; no expensive fallback is configured.
The local model catalog lists Luna; current [OpenAI model guidance](https://learn.chatgpt.com/docs/models)
identifies it as the efficient model and notes Codex Mini's retirement for
ChatGPT sign-in. [Claude model configuration](https://code.claude.com/docs/en/model-config)
documents model selection and fallback behavior.

Each case runs in its own isolated `CODEX_HOME`; only `auth.json` and the model
catalog are copied in. Codex installs a private daemon package there from the CLI
under test (local, no download), and the runner deletes that ~300 MB copy when the
case ends. Nothing is linked from a real account's `packages`: an isolated Codex's
updater rewrites `packages/app-server-daemon/current` as an absolute path under its
own home even when no update is due, which would leave the real account pointing
at a deleted temp directory (`daemon executable not found`).

Cases:

| Case | Checks |
|---|---|
| `graph` | Editing, geometry, animation, graph read/permission contracts |
| `codex-daemon` | PID/listener discovery, native queue, draft preservation, mute/disconnect/reconnect |
| `claude` | Registry discovery, authenticated native delivery, draft preservation, mute/disconnect/reconnect |
| `cross` | Both providers above, bidirectional replies, real Codex stop → Claude response, read reference |
| `codex-local` | Real `--no-daemon` lifecycle, explicit unavailable queue result, real stop → Claude response |

Paired Markdown/TOML specifications live in `suites/shared/agent-graph/`. The
`disconnect-reroutes` visual case has a deterministic replay in the real app:
single/shared route cleanup, exact undo/redo restoration, external disconnect,
and immediate reconnect without orphan dots. Run
`uv run tests/godot/test_dashboard.py test disconnect-reroutes`; a headless pass covers
topology assertions, with windowed recording/manual review for rendered evidence.

The shared
`replays/live-agents.gd` requires the runner's manifest and is deliberately not
automatically run by the free visual-test dashboard. `graph` uses deterministic
fixtures; only the four live cases claim real model coverage.

All live cases use new empty working directories and private provider homes.
A real local adapter process advertises the source Send port; provider responses
still come exclusively from the installed Codex and Claude CLIs.
Installed Codex packages are reused; no wrapper, personal settings, source sessions,
or existing daemon is replaced. Existing auth is copied privately (or read from
Claude's existing keychain into the child environment); copied credentials are
removed after the run. Only the isolated daemon is stopped during cleanup.
Use existing environment credentials or sign in normally before running. The runner
does not automate login. No API-key purchase or new account is needed.

Prompts ask for short exact replies and no tool use. There are bounded per-turn
and per-case timeouts, and no automatic retries or model upgrades. These limit
runtime but are **not a hard dollar cap**. Expect up to 26 short model responses
across all live cases. Run one case first if checking provider access.

`report.json` records PASS / FAIL / BLOCKED, with exit codes 0 / 1 / 2 respectively.
Each completed live replay records provider/session identity, observed model names,
receipts, failures and a short terminal tail on failure. Assertions inspect assistant
JSONL records, so echoed prompts cannot satisfy a response check. Acceptance by the
native transport alone is not a passed response. A missing final evidence file fails.
Process inspection or socket denials block live runs before credentials or model
calls. A Claude session-limit message is reported as BLOCKED only when there are
no other failed assertions. Provider authentication/model failures may surface as replay failures requiring
inspection; do not classify these as successful runs.

A headless graph assertion does not establish visual smoothness. Use the Markdown
case and a separate windowed recording for human/LLM visual review.

## Mac trackpad intent

The `mac-trackpad` suite separates zoom-only intent from zoom-plus-pan. Its
rendered replays check the real application input route in Flat and Flat 2D,
including Retina metadata conversion. `zoom-and-pan` retains a moving imaginary
zoom anchor across pan-only and resumed-magnification phases. The AppKit test
`python3 -m unittest tests/platform/macos/test_macos_trackpad.py` covers asymmetric finger drift,
shared translation, and native gesture lifecycle. Follow the Markdown cases for
physical trackpad validation; synthetic replays cannot establish human intent.

The shared `filetree/title-toggle` case checks real Fyler root titles and the
blue filetree header toggle. Its Godot adapter needs `FYLER_TEST_PLUGIN` pointing
to a pinned Fyler copy, such as `dist/filetree/packages-data/site/pack/core/opt/fyler.nvim` on Windows, and
runs it through a custom `[filetree] command` in `server_config`. Server-dependent replay fixtures can declare
`server_config` in their Godot adapter; the runner writes that isolated TOML
before starting the owner. `{{port}}` allocates a private loopback port.
