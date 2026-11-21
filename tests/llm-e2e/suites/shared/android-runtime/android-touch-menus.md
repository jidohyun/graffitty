# Android compact touch menus — UI-05

Use the existing Android runtime harness with a disposable app/server fixture.
Open the floating menu and View using touchscreen events. The menu must stay
at most 320×360 logical pixels, clamped further to the available keyboard-safe
viewport, rather than filling the screen. Scroll across rows repeatedly: content
must move, all pressed highlights must clear, and release must neither execute
a command nor dismiss the menu. Reach the final item, dismiss via the shared
Android Back policy, reopen, toggle the opener, and enter/leave a real submenu.
A flick keeps the rows gliding after the finger
lifts; touching the gliding menu stops it without running a command (GE-09).
The original server terminal must survive and no workspace contacts may remain.

Unchecked options must show a legible empty outline on the dark menu, including
before touch or keyboard focus. Radio choices use circles, checkbox options use
squares, and checked/disabled states remain distinct. Toggle an option in a menu
that stays open: its indicator must update without shifting the label or replacing
the command icon. Ordinary commands must not gain checkbox indicators.

The automated case injects touch events through Godot's real input routing,
including emulated mouse copies. It runs both in desktop simulation and in an APK.
It does not claim human finger smoothness, physical Back-gesture delivery, real
IME cycles, or phone/foldable rotation coverage. Supplement on both geometries
with physical scrolling, cancellation, long translated labels, keyboard open/close,
context menus and selecting the final command. `tests/touch_menu_smoke.gd` covers
1.5× scaling, cancellation, extra fingers, command identity, keyboard insets and
checked/unchecked/radio/disabled indicators in menus that stay open.
