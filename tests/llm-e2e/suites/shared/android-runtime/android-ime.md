# Ime

Runtime: Android. Emulator or physical device.

Report PASS, FAIL, or BLOCKED with evidence. This procedure needs recorded LLM/manual execution. The automated APK cases cover shared client logic, English Gboard input, and native Korean composition/editing across Gboard settings return (`android-ime-resume`). They do not establish the broader portrait, emoji and OEM coverage below as passing.

1. Use a disposable Android client and isolated server. Enable an English and Korean IME on the emulator/device; record Android and IME versions.
2. Tap the normal keyboard icon. Verify the system keyboard appears, with no keyboard chooser or unsupported-IME errors.
3. Compose Korean syllables, edit composition with Backspace, commit with Space/Enter, and type English and emoji. Verify the server receives the committed text exactly once, never intermediate composition as duplicate input.
4. Open a client connection form and repeat composition in its text fields. Return to the terminal and verify input reaches the focused pane.
5. Show/hide the keyboard in portrait and landscape. Verify pane headers and Dismiss remain reachable and the active fitting client reflows terminal rows into the usable main area above the IME and accessory bar, staying in Main View if it started there.
6. Press Android Back while the keyboard is open: it hides the keyboard without closing the workspace. Repeat keyboard show/hide and check logs.

Also leave the open keyboard for Gboard's language settings, add/switch a
language, and return to the client. Leaving the app now dismisses its keyboard
so it cannot retain a stale composing editor. Reopen the keyboard and repeat
composition; compare with a fresh launch. Retain evidence for each path.

Typing Unicode through a Godot key event or ADB text injection is not evidence that IME composition works. Exercise the actual installed IME. Check additional OEM keyboards on a phone.
