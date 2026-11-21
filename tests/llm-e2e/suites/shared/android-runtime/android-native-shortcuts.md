# Native Android Ctrl shortcuts

Run on an ARM64 emulator or phone with Gboard English selected. This case taps
the actual installed keyboard and Graffitty's accessory Ctrl button, and sends
Android key chords through ADB. It does not inject Godot input events.

1. Connect the disposable APK to an isolated server and focus its terminal.
2. Tap accessory Ctrl and Gboard's equals, plus, minus, and zero keys. Verify
   font changes and one-shot modifier release, including after typing a word
   and switching to the symbol keyboard.
3. Verify Android Ctrl+=, Ctrl+Shift+=, Ctrl++, Ctrl+-, and Ctrl+0.
4. Read three raw PTY bytes from accessory Ctrl+U, plain u, and Android Ctrl+U.
   Require exactly `15 75 15`; a visual pressed state alone is insufficient.
5. Tap Esc and Tab, arm Ctrl/Alt/Shift together for one input, then tap each
   modifier twice to lock it. Type repeatedly, tap each again to release, and
   type plain text. Require the exact PTY bytes and retain screenshots of the
   normal, one-shot, locked, and released key row.
6. Retain native event traces, screenshots, video, and assertions. Fail on any
   unexpected diagnostic and preserve the fixture server's original PTY.

Use `android-text-size` for floating-button targeting and Chrome zoom coverage.
This native case complements those shared scenarios, which synthesize Godot
events and cannot independently verify the Android input bridge.
