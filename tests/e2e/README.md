# Android office-control acceptance tests

This directory records the requirements and regressions from the Android remote-office
work session. It is an **acceptance specification**, not a new test runner or a claim
that every scenario passes. Keep it current when implementing related changes.

## Scope and priorities

The office workflow uses an Android client (Artemis fork), a macOS streaming host
(Lumen ported onto current Sunshine), and SwiftKey Polyglot. Related modifier-bar
behavior must also work in Graffitty. RustDesk is a behavioral reference, not a
promise that these applications share its protocol or implementations.

1. No unintended repeated keys during lag; reliable terminal/editor input.
2. Direct pinch zoom and pan, without a navigation-mode button.
3. Natural trackpad control, usable under latency, with immediate local feedback.
4. Correct keyboard/toolbars, compact modifiers, stable floating controls.
5. Real display selection, a truthful selected-display badge, natural PiP.

## Specifications

| File | Coverage |
| --- | --- |
| [input.md](input.md) | IME composition, SwiftKey toolbar, Enter, deletion, keys, modifier-click, lag |
| [gestures.md](gestures.md) | Trackpad default, scroll/pinch ownership, free pan, local pointer |
| [controls.md](controls.md) | Compact key strip, floating placement, keyboard cycles, drag, popups |
| [displays.md](displays.md) | Real monitor discovery/switching, PiP crop, image quality |
| [installation.md](installation.md) | Upstream integration, Mac app identity/permissions, Android deployment |
| [coverage.md](coverage.md) | Existing test entry points, evidence requirements, outstanding validation |
| [desktop-client.md](desktop-client.md) | Moonlight Qt floating session controls, windowed default, encoder capability caching |
| [windows-client-mac-host.md](windows-client-mac-host.md) | Windows client → Mac host acceptance matrix, pairing blocker, current evidence |

Each scenario has a stable ID. Record results against those IDs with the tested
commit/build, device/OS, host, keyboard, and relevant settings. Do not equate a
unit test, screenshot, successful build, or install with an E2E pass.

## Final decisions (replace earlier proposals)

- Pinch changes the **view of the stream**, not the Mac display resolution.
- No separate zoom-mode button; two-finger intent distinguishes scroll from zoom.
- Manual navigation is free: do not force the picture to remain inside its original
  letterbox or clamp it to cover the viewport.
- PiP preserves the **currently viewed desktop region without letterbox bars**.
  Resetting zoom to fit the entire monitor is superseded.
- Virtual displays are **off for the current baseline**. Stream an existing monitor.
- Natural trackpad is the default for unset preferences. Preserve explicit choices;
  when changing an existing test device, verify its saved mode rather than assuming
  a changed default takes effect.
- Display options come from actual host capture outputs, never a fixed slot count.
- The installed streaming host is named **Lumen**, not Sunshine or Lumen Local Test.
- Graffitty Android uses Ctrl/Alt/Shift, with no on-screen Cmd key or default
  Cmd shortcuts, regardless of server OS. Artemis retains Cmd for controlling
  a Mac desktop. Keyboard and pointer actions must receive the supported
  modifiers; UI-only toggle state is insufficient.

## Test fixtures and privacy

Use a dedicated editable document, scratch terminal/PTY event logger, and browser
DOM-event fixture. Never test destructive shortcuts against the user's live work.
Include a phone and a second device with different display geometry (tablet/foldable
where available); one phone passing does not establish layout correctness elsewhere.
Test SwiftKey Polyglot in both normal and Programming Mode.

Configure device addresses, pairing credentials, and evidence paths through local
environment/configuration, not committed files. Never commit passwords, pairing
PINs, device/host names, IPs, MagicDNS names, private paths, screenshots of personal
work, or permission databases. Use disposable latency/fault-injection fixtures and
restore network settings afterward.

RustDesk password troubleshooting and keeping a development phone awake while
charging were operational requests, not new authentication or lockscreen-bypass
features. Do not remove a device PIN or bypass macOS permission consent.
