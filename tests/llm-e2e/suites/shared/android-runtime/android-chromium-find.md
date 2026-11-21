Run the `chromium-find` workspace scenario against a disposable server and
browser. Focus the actual browser surface and press the platform find chord
(Cmd+F on macOS, Ctrl+F elsewhere). The find box must open with keyboard focus
in the page's top-right corner, where Chrome shows its find bar, not in the
browser toolbar. Type the query through key events: it must reach the box, not
the page, and the box must show Chromium's `1/3` for three case-insensitive
matches. Enter steps to `2/3`; Shift+Cmd/Ctrl+G returns to `1/3`. Escape closes
the box, returns the keyboard to the page and leaves the active match selected.
Retain the runtime checks, logs and the `find.png` screenshot. This checks the
Godot UI and Chromium's find engine; it does not establish a physical keyboard,
Android IME composition, or Chrome's native find bar in a native window.
