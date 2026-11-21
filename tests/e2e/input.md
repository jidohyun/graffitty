# Keyboard, IME, and modifier acceptance

See [README](README.md) for scope and evidence rules.

## IN-01 — SwiftKey toolbar and normal editor contract

1. Select SwiftKey Polyglot as the Android IME. Compare a normal text field with
   the active remote stream; open the keyboard from the floating button.
2. Repeat in Programming Mode, after hiding/reopening the keyboard, and reconnecting.
3. Check the keyboard's upper toolbar/menu and suggestions where enabled by its settings.

Expected: the keyboard does not lose its normal toolbar just because the remote
stream is focused. The connection exposes valid editor selection and extracted-text
information rather than raw-key-only/unknown-editor behavior. Returning a valid local
IME snapshot must not claim to expose the entire remote application's document.

Regression: text input enabled alone did not restore the toolbar. A null
`getExtractedText()` response suppressed it in the tested keyboard. Keep a test for
that contract as well as a device-visible toolbar assertion.

## IN-02 — Unfinished composition is live and deletable

Type an unfinished word slowly, one key at a time. Without committing it, backspace
once, then erase it entirely. Repeat with several words, spaces, punctuation,
composition replacement/autocorrection, and hide/reopen mid-word. Test both keyboard
modes; include non-ASCII composing input and supplementary characters.

Expected: each composing update appears promptly at the host. Deletion takes effect
immediately, not after deleting an invisible local word. No duplicate recommit,
extra characters, stale word, or corruption of earlier remote text.

Korean: with a keyboard that keeps the whole word composing (SwiftKey, Gboard
with suggestions), type a multi-syllable word such as `안녕하세요` without a space.
Each syllable reaches the host as soon as the next one starts; only the syllable
still being built is a local preview. Backspace into a syllable already sent
(`안녕` → `안녀`) erases it at the host and reopens it as the preview. Japanese and
Chinese conversion still stay local until committed.

Regression: writing N letters must never require N ignored Backspaces. Test
`setComposingText`, `commitText`, `deleteSurroundingText`, and code-point deletion,
not just injected physical Delete events. Test pending-text/deletion ordering.

## IN-03 — Enter and control keys are keys, not plain text

Use a raw PTY event/byte logger and a scratch editor on the Mac:

- Soft-keyboard Enter, IME action Enter, and physical Enter send Return semantics.
- Enter must never produce `a`, a duplicated character, or an unexecuted text newline.
- Tab, Escape, Backspace, Delete, all arrows, Home/End, and Page Up/Down work.
- Test arrows and Enter immediately after rapid composing/committed text; they cannot
  overtake queued text.
- Test repeat/hold and release for navigation keys, including cancellation.
- Compare SwiftKey Programming Mode Ctrl+Enter (one-shot and locked Ctrl) with
  Graffitty's accessory Ctrl + Enter in the same scratch terminal with CSI-u enabled.
  Both must deliver Ctrl+Enter, followed by plain Enter after releasing Ctrl.
  Repeat with pending composition. Record the terminal bytes, not just native events.

Record actual host bytes/events and resulting text/caret position. A correct Android
keycode or client callback alone is insufficient evidence.

## IN-04 — No unintended repeats during lag

Run a baseline, then controlled delay/jitter and a temporary stall. Record the actual
network conditions rather than describing the connection as merely "laggy".

1. Tap distinct letters and navigation keys, then stop touching the keyboard.
2. Delay a release, interrupt a chord/drag, and disconnect/reconnect.
3. Compare soft-keyboard taps with physical key holds and intentional repeat.

Expected: taps do not become repeated characters because releases arrive late; no
stuck modifiers/keys after interruption. Input remains ordered without lost intended
presses or repeated replay after recovery.

Current mitigation to verify: Lumen `key_repeat_delay = 0` disables its host repeat
timer. This also disables that normal hold-to-repeat mechanism; it is not proof of
complete stuck-key or latency safety. Report the tradeoff explicitly.

## IN-05 — Compact sticky modifiers in both applications

For Graffitty Android, test Ctrl, Alt and Shift individually and combined; no
on-screen Cmd key is offered. For Artemis, additionally test Cmd for Mac desktop
control. Physical-keyboard modifiers remain input capabilities, not virtual keys:

- Tap once: arm for the next complete action.
- Tap again: lock for repeated actions.
- Tap again: release; armed/locked/off are visually distinguishable.
- Keyboard down/repeat/up retain one consistent chord.
- Mouse down, drag/motion, and mouse up retain one consistent chord.
- One-shot state clears after the action, not before its release.
- Locked state survives repeated clicks until explicitly cleared.
- Toolbar/keyboard/monitor/mode-button taps do not consume a pending pointer chord.
- Cancellation, focus loss, disconnect, and switching targets release remote held
  state. Check interaction with physically held left/right modifiers as well.

Use the real terminal PTY mouse-reporting path and a browser event fixture that
records `ctrlKey`, `altKey`, `shiftKey`, `metaKey` on both click edges. Also test
modified wheel/scroll and selection drags; do not infer their correctness from clicks.

On macOS Graffitty and in Artemis controlling a Mac, test Cmd-click selection,
Shift-click range selection, and Ctrl-click context menus in a disposable fixture. Artemis's protocol needs real modifier key
state around mouse actions; Graffitty must attach modifier state to pane input, not
only keyboard events. Do not consume modifiers by decorating control-bar input.

Graffitty touch selection: with one-finger terminal scrolling (the default), arm
Shift on the key strip and drag one finger across a terminal. The drag must be a
Shift+drag that selects text, not a scroll, also inside a full-screen application
that reports the mouse (vim with mouse on, tmux, an agent TUI); the strip's Copy
key then copies that selection and Paste inserts it. One-shot Shift is spent by
that one drag and the next drag scrolls again; locked Shift keeps selecting.
Chromium pages keep scrolling with Shift armed. Without Shift nothing changes.

## IN-06 — Chromium and terminal shortcut routing

Test platform-appropriate shortcuts in Graffitty's embedded Chromium, not just a
standalone browser. macOS clients use native Cmd shortcuts; Graffitty Android
uses its Android bindings regardless of the server OS and offers no Cmd button.
Ctrl remains meaningful for terminal control sequences.

Verify copy/select-all and closing a **disposable** browser tab with the intended
platform chord. Confirm shortcut routing does not close the entire workspace, leak
the shortcut letter into the page/terminal, or omit key-up. Record any unsupported
browser shortcut separately from DOM modifier-delivery coverage.

When the browser's server runs on the same computer as the viewer, Copy, Cut
and Paste in a focused page run Chromium's native `copy`/`cut`/`paste`
commands, so Chromium uses the shared OS clipboard itself (the address bar
keeps its own editing). Verify them for a selection inside an iframe and in a
code editor such as CodeMirror or Monaco, and paste an image into a page that
accepts one. A server on another computer keeps the viewer clipboard bridge
(plain text, selection read and `insertText`, 64 KiB limit), because Chromium's
native clipboard there is the server's, not the viewer's. The
`android-chromium-clipboard` scenario checks an iframe copy and a paste on the
native path when its server is local, then forces the bridge for the rest.

Typing in the address bar lists the profile's history below it, ranked by
Chrome's omnibox (`history-query`). Verify on Android, with SwiftKey composing
and with an external keyboard, that suggestions follow the visible text
including an unfinished composition, that tapping a suggestion opens it
without first dismissing the keyboard, and that the keyboard's Enter opens the
typed text unless a suggestion was chosen with the arrow keys. Escape (or Back)
closes the list before it leaves the bar. Tapping the list must not move the
keyboard focus to the page. `tests/chromium/chromium_history_e2e.py` covers only the
real history query on macOS, not this Android input. No device run is recorded
yet.

On macOS, CDP key events skip AppKit's text bindings. Blink applies the Option
word chords (⌥←/→, ⌥⌫, ⌥⌦) itself; the client sends the remaining ones as edit
commands: ⌘←/→/↑/↓ (with ⇧ to extend), ⌘⌫/⌘⌦, and ⌃A/E/B/F/P/N/D/H/K/T.
`tests/chromium/headless_chromium_e2e.py` checks them in a real input field.

Graffitty's shortcuts come only from `client.toml` `[bindings]` and the shared
action registry; menus, `Prefix+…` sequences and the command line show the same
resolved keys. Touch controls resolve the `android` platform: `CmdOrCtrl` is
Ctrl, application defaults use Ctrl+Shift, and the default prefix is Ctrl+A. With
an external keyboard and with the on-screen Ctrl modifier, verify the default
prefix, one per-OS override (for example `key = { android = "Ctrl+B" }`), and that
a focused terminal still receives terminal actions (Copy, Paste, Search) after its
copy-mode/search keys. A desktop run with touch controls or a unit test does not
establish this on a device.

## IN-07 — Agent messages wait for human typing

In a disposable Graffitty agent pane, type with the IME and a physical keyboard
while another node sends a message. Repeat with a second viewer attached to the
same pane. New agent work must wait until three seconds after the latest human
terminal input, not three seconds after the first character. The draft remains
unchanged. Removing/muting the connection during the wait must prevent delivery;
terminal-generated replies and automated agent input must not prolong the wait.
Already-admitted native work and its acknowledgements are not cancelled just
because typing resumes. Input in a different pane must not delay this pane.

The server and provider-adapter tests cover the gate and permission recheck.
They are not an Android/SwiftKey physical-device pass for this scenario.

## IN-08 — Shared SwiftKey and Graffitty terminal modifiers

Use matching updated Graffitty Android and SwiftKey Polyglot builds, with
Programming Mode enabled and a disposable terminal/PTY logger focused. The
terminal editor advertises the shared modifier channel; ordinary editors and
normal keyboard mode continue using standard IME input.

- Arm, lock and clear Ctrl, Alt and Shift from each UI. Confirm the other UI
  reflects each state, including rapid taps and combined modifiers. Shared locked
  Shift modifies navigation; native Caps Lock outside this channel retains its
  existing meaning. Check Latin casing and Korean Shift alternatives.
- Select one-shot Shift in Graffitty and hold a SwiftKey arrow through at least
  50 repeats. Verify modified press/repeat/release at the terminal, then an
  unmodified next gesture. Repeat with Ctrl+Shift, locked modifiers, and selecting
  the modifier in SwiftKey before using Graffitty's arrow.
- Check shifted punctuation, Shift+Enter, Ctrl+Enter and ordinary text after the
  shortcut. Pending composition must finish once before navigation or a shortcut.
  Repeat keyboard shortcuts with Graffitty's accessory bar hidden.
- Cancel a hold, hide/reopen the keyboard, leave Programming Mode, change pane,
  restart the editor connection, and switch keyboards. No repeat or old state
  callback may reach the replacement target. Repeat a connected/disconnected
  cycle with the optional translation/correction input focused inside SwiftKey.
- Verify RustDesk and an ordinary Android text field still receive their standard
  key events; the private channel is capability-negotiated, not package-guessed.

Adapter instrumentation and Godot state tests cover command ordering, mirrored
state, stale-peer rejection and complete gestures. Actual keyboard touches,
native Shift rendering, terminal bytes and both device geometries require their
own recorded E2E evidence.

## IN-09 — Image paste to local and remote agents

Use a disposable agent pane on a Graffitty server, then repeat on another
computer's server. Paste a screenshot with the desktop Paste shortcut, the
Android/iOS touch Paste action, Android's native selection menu, and an Android
keyboard that supplies an image through `InputConnection.commitContent`.

- The complete image must exist on the terminal's server before one quoted
  path is pasted. No Enter or Ctrl+V is synthesized. Text paste keeps Unicode,
  newlines and bracketed-paste behavior. Typing/Enter immediately after an image
  waits behind its upload.
- In Codex and each supported agent, verify the image becomes an attachment
  and ask the agent to describe a distinctive feature. A path or PTY receipt
  alone does not establish agent image recognition.
- Exercise PNG/JPEG, a clipboard bitmap, a content URI and a file copied on
  macOS. Try an image larger than one transport packet. Verify exact bytes for
  preserved formats and dimensions/content for normalized bitmaps.
- Disconnect, switch servers, replace/close the pane and revoke URI access
  during transfer. Never paste an incomplete path into another pane or replay
  after reconnect. Oversized (over 32 MiB), unreadable or corrupt images show a
  localized failure. Android temporary URI grants must be released and stale
  editor callbacks ignored. iOS must respect its native paste permission.

Reuse `tests/android/test_android_runtime.py android-bracketed-paste` for shared
transport/PTY checks, `tests/android/test_android_ime.py` for native Android content
callbacks, and `tests/godot/test_remote_controller.py` for CLI/remote transfer.
Record physical clipboard, keyboard and agent acceptance separately; simulated
touch, compilation and adapter instrumentation do not establish those passes.

## IN-10 — Prefix split characters follow the keyboard layout

1. Attach a hardware keyboard and choose US, German, and a layout using AltGr
   or Option for punctuation.
2. Press Ctrl+A, release it, and type `|`, `_`, `\`, and `-` using each layout.
3. Verify left, up, right, and down splits respectively, once per input.
4. Type a different character from the US backslash key's position; it must not
   create a left pane merely because Shift was held.

Expected: produced punctuation selects the split direction. Shift, Option, and
AltGr used to produce the character do not change that direction. Explicit
user-defined modifier shortcuts retain priority. Physical-device acceptance is
pending; shared Rust and Godot key-event tests are supporting checks.
