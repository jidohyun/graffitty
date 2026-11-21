# Feature audit — 2026-10-04

This audit runs the complete existing scripted replay inventory, Python integration
checks, Godot units, native CLI/server tests, standalone backend/SSH/chromium tests,
Android simulation and Android APK tests. It also runs the additional GPU smoke
scripts and real provider integrations. Evidence is under `build/feature-audit/`.
A passing automated case certifies its assertions, not every possible interaction.

## Final results

After fixes and focused reruns:

- **67 scripted desktop replays passed**, including 25 Android simulations.
- **33 Android APK cases passed** on API 36 ARM64 Mobile/Vulkan.
- **30 additional GPU smoke tests passed**. Initial failures and final reruns are
  retained separately in `smokes/results.json` and `smokes/verified-results.json`.
- **133 Godot unit tests passed**, with clean fixture teardown.
- **96 Rust tests passed**: CLI 65, session server 20, authentication 11.
- **78 Python tests passed; 9 Windows-only tests skipped** (87 discovered).
- Real Claude, Codex daemon, local Codex and cross-provider routing all passed.
- Standalone PTY, SSH deployment, Chromium, permanent-password and native Mac
  trackpad integrations passed.

The machine-readable final manifest is `build/feature-audit/verified-results.json`.
The original desktop run was 65/66; repairing the Shift-drag replay and adding
visual preferences produced the final 67 passing cases. The affected desktop
recordings and all 33 APK recordings are in the replay gallery and DVC cache.

## Corrections

Changes made during the audit:

- Fixed a real macOS SIGPIPE crash when the movie encoder exits early, using
  per-descriptor signal suppression. The failure-path test now rejects signal
  termination and verifies that no partial video is published.
- Guarded UI-focus shortcut handling when a host is not attached to the tree.
- Isolated Python/unit fixtures from personal configuration and agent routing;
  cleaned up unparented unit fixture controls and renderer fixture cameras.
- Repaired the Shift-drag replay signature and added remote font/cursor-style
  coverage on both the Mac wrapper and actual APK.
- Updated stale fixtures: current node commands, overflowing scroll content,
  deterministic session restore, premultiplied shader input, native desktop DPI,
  floating/stashed split behavior and actual drag events for physics anchors.
- Added an early provider-runner check for overlong Codex control-socket paths.
  Successful provider reruns used short private directories; their sanitized
  evidence is retained under `build/feature-audit/live-providers/`.

## Coverage by feature

| Feature family | Executed coverage / evidence |
|---|---|
| Terminal | Unicode/Hangul rendering, ANSI, input isolation, control keys, bracketed paste, selection/copy, mouse reporting, history/search, font sizes; desktop replays, shared Android scenarios and standalone PTY tests |
| Panes | Create/split/close, nearest-pane focus, drag/resize, independent fonts, fit/restore, title double-click, stashes, main area, physics, tiling and per-tab defaults; desktop and Android scenarios |
| Tabs/windows | Create, close, reorder, title/cwd, move/merge, detach, multiple native windows, prefix navigation; desktop replays and Android adaptations |
| Camera/worlds | Flat/2D, Bistro, tab flight, pinch/zoom, cursor visibility, typing zoom, rendering effects; replay suite and additional GPU smokes |
| Cursor effects | New shared `visual-preferences`: Smear/Blaze/Lightning/Off, exactly one checked menu item, continued terminal output; menu dispatcher rather than native menu hit testing |
| Graph | Connect/disconnect/reroutes, port drag, manifests, payloads, receipts/queue lifecycle, link animation; deterministic graph suite, Python node integrations and shared Android cases |
| Nodes | Filter editing/selection/cursor positioning, dropdowns, Parallel, payload inspector, prompt nodes, chat preview/configuration; Python and Rust tests use local/offline fixtures |
| Chromium | Real Chromium start, Unicode DOM, automation, preview, address navigation, persistence and close; standalone chromium E2E, shared chromium scenario and GPU smokes |
| Remote sessions | Headless PTYs, multiple workspaces/servers, shared grids, independent camera/tab views, input isolation, reconnect and lifecycle; backend and client E2E |
| Remote images | Native image state/cache tests plus standalone-server snapshot/reconnect/deletion cases in Android; does not certify image transfer from the GUI-hosted backend |
| Authentication | Disabled-by-default/startup opt-in, runtime toggle, invalid credentials, permanent password across restart, Android credential persistence; replay/password/Keystore cases |
| SSH | Actual isolated localhost sshd: upload, server startup, authenticated encrypted forwarding, cleanup, detached shell survival |
| Messages | Copy shortcut, modal focus, Dismiss touch target, IME-safe layout; desktop and Android, with unexpected diagnostics treated as failures |
| Touch controls | Centered mouse, exact pinch anchor/pan, double-tap/hold/drag, three-finger scroll, keyboard button, portrait rotation, native taps, Gboard and Android Back |
| Android lifecycle | Home/resume, held-contact cancellation, background output, process restart, APK update, Korean IME resume after settings |
| Persistence/config | Layout/session restore, fonts, preferences, config contracts and integration setup; unit/Python/replay checks |
| Agent providers | Real isolated Claude/Codex sessions and cross-provider graph routing; provider report records failures/blockers independently |
| Replay recording | Actual MovieWriter/FFmpeg integration, capture gating, encoder failure and AV1 gallery contracts |

## Coverage limits

Not certified by this machine/run:

- Windows and Linux native notification activation, credential stores, OS shortcuts,
  battery events and graphics drivers.
- A physical Android phone's GPU, memory pressure, OEM IME, sustained performance,
  split-screen/cutout combinations, or Tailscale/VPN interruption.
- Complete Android cross-app clipboard, external-intent, lock/unlock and broad
  composition/emoji procedures. These remain separate manual cases.
- Real Telegram/Slack/Discord delivery and Telegram 2FA. No real chat messages
  are sent by the audit; local/offline contracts do not prove service delivery.
- Every custom user script, world asset, shader appearance, terminal application,
  or shell configuration. Chromium panes also remain unsupported by session-save
  restoration; this is an existing explicit limitation.

## Reproduce

Run Python tests in isolation:

```sh
mise exec -- uv run tests/run.py
```

The wrapper supplies dependencies, removes inherited agent routing, and uses
private XDG directories. Godot unit fixtures likewise use private app settings.
Do not run tests against a user's active remote server or classify inherited
configuration failures as product regressions.
