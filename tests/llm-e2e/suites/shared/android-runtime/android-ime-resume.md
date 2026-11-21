# Korean IME settings return

VM prerequisite: Gboard with English and Korean 두벌식 enabled. The runner uses native Android key taps, not Unicode injection.

1. Open the terminal keyboard; compose 한글, erase/retype its last consonant, then Space.
   Toggle it closed with the floating keyboard button: the workspace must fill
   the available height and the accessory key row must disappear. Open it again.
2. Open Gboard settings and return to Graffitty. The previous keyboard must be dismissed.
   A zero-height callback while settings owns focus must not cancel pending
   dismissal of Graffitty's native editor on return.
3. Reopen the keyboard and compose 한글 again. Require composed syllables, not separate jamo.
4. Commit the shell fixture and verify `<한글 한글 >` in authoritative terminal output.
5. Restore English, retain the video, and fail on any unexpected diagnostic.

Repeat with Home/app switching and screen lock/unlock while the keyboard is
visible, including an unfinished composing word. Run at least five cycles with
the phone's installed keyboard. On return, require the stale keyboard and its
reserved space to disappear: no black panel, stuck accessory modifiers, or
unreachable keyboard toggle. Tap the keyboard button once, type a unique word,
and verify it reaches the terminal exactly once. Android Back must dismiss the
new keyboard. Retain a screen recording of the transitions; synthesized Godot
pause/resume events alone do not certify native IME recovery.

Reconnect with the keyboard visible and verify that only one accessory row
remains. Its controls must follow the current keyboard boundary, with no old
row stranded elsewhere on the screen.

This regression does not replace the broader manual `android-ime` procedure for portrait, emoji, or other IMEs.

## Immediate terminal typing and native composition

Repeat with Gboard, Samsung Keyboard, and SwiftKey using their native keys.

- Type `hello` without Space: each Latin letter must reach the server immediately,
  with no duplicate local preedit. Space/Enter must not replay the word.
- Type `dd` in Neovim normal mode: it must execute without Space.
- Press Backspace during a Latin word: delete one transmitted character. Retype
  it and commit; require no duplicate or missing letters.
- Select a longer suggestion: only the extra suffix is sent. A replacement
  suggestion must not inject remote Backspaces to rewrite already executed input.
  This intentionally does not provide reliable retroactive autocorrection.
- Compose 한글, edit the final consonant, and commit: only the unfinished
  syllable remains local; each finished syllable is sent when the next one
  starts, and every syllable arrives exactly once. Also test Shift + ㅆ.
- In a raw-byte fixture, use the accessory Ctrl with on-screen c, u, d, then
  type x and Space. Require exactly `03 15 04 78 20`, without queued letters.
